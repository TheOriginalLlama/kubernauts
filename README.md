# Kubernauts

A small, end-to-end Kubernetes delivery pipeline. The cluster is defined in YAML, every change is tested automatically on a throwaway cluster, and a tested commit can be promoted to a production cluster.

## Tech Stack:

- **Kubernetes:** the platform being delivered to. It is the standard container orchestrator and the skill this project is meant to practise.
- **kind (Kubernetes in Docker):** runs real multi-node clusters as Docker containers. It is free, starts in about a minute, needs no cloud account, and builds the same cluster on my PC and in CI.
- **Docker:** the container runtime kind runs on. Docker Desktop on my PC, and the Docker already installed on GitHub's runners.
- **Kustomize (`kubectl apply -k`):** keeps one base set of manifests and layers small per-environment patches on top (for example, 1 replica in staging and 2 in prod). It is built into `kubectl`, so there is no templating language or extra tool to install, and it avoids copy-pasted YAML.
- **kubectl:** applies manifests, shows diffs (`kubectl diff`), and waits for rollouts. It is the one client every Kubernetes cluster understands.
- **podinfo:** a small, well-known sample web app with `/healthz` and `/readyz` endpoints. It gives the pipeline something real to deploy and probe without writing an app first.
- **kubeconform:** validates manifests against the Kubernetes schemas in seconds, catching typos and wrong fields before a cluster is even built.
- **GitHub Actions:** runs the pipeline next to the code, with no separate CI server to maintain. It is free for private repos within a monthly quota.
- **GitHub-hosted Ubuntu runner:** a clean VM per run with Docker preinstalled, used for the `test` job so tests need none of my own hardware.
- **`helm/kind-action`:** a maintained action that builds the kind cluster from `clusters/staging.yaml` in CI, so I do not hand-roll the setup.
- **Self-hosted runner (Windows):** the only way a job can reach the prod cluster, since that cluster lives on my machine. It is documented but not installed in this showcase.
- **Bash scripts (`scripts/`):** small, readable glue for creating clusters and smoke testing. They run the same way locally and in CI.
- **Git and GitHub:** the source of truth. Every change is reviewed and tested as a commit, and the exact commit that passed `test` is the one that gets promoted.

## Repo layout

```
clusters/                        kind cluster definitions (staging, prod)
k8s/base/                        the app (podinfo) as plain manifests
k8s/overlays/{staging,prod}/     per-environment variants (kustomize)
scripts/create-cluster.sh        idempotently create a kind cluster from a definition
scripts/smoke-test.sh            wait for the rollout, then hit /healthz
.github/workflows/pipeline.yaml  the pipeline
```

## The pipeline

```
push / pull request ──> test (GitHub-hosted Ubuntu VM)
manual "Run workflow" ─> test ──> deploy-prod (self-hosted runner)
```

| Job | Trigger | Where it runs | What it does |
|---|---|---|---|
| `test` | every push, pull request, and manual run | GitHub-hosted `ubuntu-latest` VM | validates the manifests with kubeconform, builds a temporary cluster from `clusters/staging.yaml`, applies the staging overlay, runs the smoke test |
| `deploy-prod` | manual only, on `main`, after `test` passes | self-hosted runner | creates `kubernauts-prod` if missing, shows a `kubectl diff`, applies the prod overlay, runs the smoke test |

### Why test clusters are built on GitHub's Ubuntu VM

Every `test` run starts a fresh Ubuntu VM that GitHub provides. It already has Docker, and the `helm/kind-action` step uses that Docker to build a real [kind](https://kind.sigs.k8s.io/) cluster from the same `clusters/staging.yaml` used locally. The manifests are then applied and smoke-tested against that cluster.

- **Real, not simulated:** schema validation alone cannot catch a bad image tag, a failing probe, or a broken Service. Applying to an actual API server and waiting for the rollout can.
- **Clean every time:** the VM and its cluster are destroyed when the job ends, so no leftover state can make a broken change look healthy.
- **No machine of mine required:** tests run whether or not my PC is on, and Docker Desktop does not need to be running.
- **Safe:** the cluster is temporary and isolated, so a bad change breaks nothing that matters.
- **Cheap:** hosted runners are free for private repos within the monthly quota, and the cluster takes about a minute to build.
- **Same definition everywhere:** the cluster is described in YAML, so the CI cluster and a local one are built from the same file.

### What the self-hosted runner is for

A GitHub-hosted runner lives in GitHub's data centre and cannot reach anything on my own machine. The production cluster (`kubernauts-prod`) is a set of Docker containers on my PC, so only a process running on that PC can deploy to it.

A **self-hosted runner** is a small agent installed on that machine. It makes an outbound connection to GitHub, waits for jobs that ask for `runs-on: [self-hosted, windows]`, and runs them locally with access to the local Docker and the prod cluster. That is the only job that uses it.

Because of this, `deploy-prod` needs the runner online and Docker Desktop running. If the runner is not installed, a manual deploy simply waits in the queue. The runner is **not installed in this showcase**, which is why deployment is a manual job. Setting it up (once):

1. Repo Settings > Actions > Runners > New self-hosted runner (Windows), then download, configure, and start it.
2. Optionally create a `production` environment under Settings > Environments. Required reviewers add an approval gate, but on private personal repos that needs GitHub Pro.

If production were a cloud cluster, a hosted runner could deploy to it and no self-hosted runner would be needed.

## Access control

### Follows the principle of least privilege

Every person, token, and job gets only the access it needs to do its work, and nothing more. In this pipeline that means:

- **Read-only workflow token:** the workflow sets `permissions: contents: read`, and the repo's default workflow token is read-only. A run can read the code to test it, but it cannot push commits, create releases, or change repo settings.
- **Nothing runs with more access than its job needs:** `test` only builds a disposable cluster on a GitHub VM, so it touches nothing of mine. Only `deploy-prod` is allowed near production.

### Why the deploy job should be limited

Nobody should be able to push to production except the people who have been approved to do it.

- **Production is real:** a change there affects the live environment, so starting a deploy should be a deliberate act by an approved person, not a side effect of someone else's push or pull request.
- **The self-hosted runner is powerful:** it executes workflow code as my Windows user, with access to my files, my Docker, and my other clusters. Whoever can trigger the deploy job can run commands on that machine. For this reason the deploy job is manual-only, and a self-hosted runner must never be attached to a public repo, where any pull request could change the workflow.
- **Smaller blast radius:** if an account is compromised or a pull request is malicious, the damage is limited to what that account or token is allowed to do.
- **Accountability:** when only approvers can deploy, it is clear who ran what and when.
- **Cost and abuse:** untrusted triggers can burn hosted-runner minutes or run unwanted workloads.

The usual way to enforce this is a `production` [environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment) with **required reviewers**, so the deploy job pauses until a named approver signs off. On private personal repos that feature needs GitHub Pro.

### Giving each person only what they need: GitHub roles

GitHub lets you assign each user a role that matches their job, so you can grant just enough permission. These roles are available on repositories owned by an **organization**:

| Role | Intended for | Can do |
|---|---|---|
| Read | people who only view or discuss the project | view and clone the code, open issues and comments |
| Triage | people who manage issues and pull requests | everything in Read, plus label, assign, and close issues and PRs (no code changes) |
| Write | contributors | everything in Triage, plus push branches and merge pull requests |
| Maintain | people who run the project | everything in Write, plus manage some repo settings (no destructive or sensitive ones) |
| Admin | owners | full control: settings, access, secrets, and deleting the repo |

Organizations can also define **custom roles** for finer control. Personal repositories are simpler: there is just the owner and collaborators, without these granular roles. To use roles, branch protection, and environment approvals together, move the repo into an organization.

Typical setup for a team: most people get **Write** (they can open PRs and see test results), only a few approvers can run or approve the production deploy, and **Admin** stays with one or two owners. Roles are managed under Settings > Collaborators and teams. See [GitHub's repository roles documentation](https://docs.github.com/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization).

## Run locally

```sh
scripts/create-cluster.sh clusters/staging.yaml
kubectl apply -k k8s/overlays/staging
scripts/smoke-test.sh kind-kubernauts-staging
kind delete cluster --name kubernauts-staging
```

Requires Docker, `kind`, and `kubectl`.

## Suggestions

### Rollback on failure (not implemented)

Today `deploy-prod` applies the prod overlay and then smoke tests it. If the smoke test fails, the job goes red but the broken version stays live. A rollback step would close that gap. This is a design idea only and the workflow does not do it yet.

How it would work:

1. **Record the last good state** before changing anything, for example `kubectl rollout history deployment/web` or the current image and revision number.
2. **Apply the new overlay and smoke test it**, as the job does now.
3. **Add a step with `if: failure()`** that runs `kubectl rollout undo deployment/web`, then `kubectl rollout status` to confirm the previous ReplicaSet is healthy again.
4. **Fail the job anyway.** The rollback restores service, but the run must still show red so the bad change is not mistaken for a success.

Why it is worth doing:

- **Shorter outages:** a bad deploy is reverted in seconds, without waiting for someone to notice and fix it by hand.
- **Safer promotion:** it makes "test passed, so deploy" less risky, because staging cannot catch everything (real traffic, real data, prod-only config).
- **Uses what Kubernetes already provides:** Deployments keep revision history, so `rollout undo` needs no extra tooling.

Things to get right:

- Verify the rollback itself with a smoke test, and alert loudly if it also fails.
- Keep `revisionHistoryLimit` high enough that there is a previous revision to return to.
- `rollout undo` only reverts the Deployment. Changes to other resources (a ConfigMap, a Service, a CRD) in the same apply are not undone, and may need to be reverted by re-applying the previous commit instead.
- Never apply a rollback step blindly after a partial failure: check that the failure was in the new version and not in the cluster or runner.

### Other ideas

- **PR preview environments:** give each pull request its own namespace for review.
- **Image build stage:** build and push an app image in CI, then promote the same tag from staging to prod.
- **Policy checks:** fail PRs that run as root or lack resource limits (Kyverno or `kube-linter`).
- **Drift detection:** a scheduled job that runs `kubectl diff` against prod and opens an issue on hand-made changes.
- **Progressive delivery:** canary or blue-green releases with Argo Rollouts.
- **Pin tool versions:** CI currently installs `kubeconform` at a fixed version but relies on the latest `helm/kind-action` major tag. Pinning actions to commit SHAs would harden the supply chain.
