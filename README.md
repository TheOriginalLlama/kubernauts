# Kubernauts

A small, end-to-end Kubernetes delivery pipeline. The cluster is defined in YAML, every change is tested automatically on a throwaway cluster, and a tested commit can be promoted to a production cluster.

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

## Access control: who can run the pipeline

Only the repository owner can run the pipeline. This is enforced in three layers:

1. **Repo access:** the repo is private and I am the only collaborator.
2. **Owner check in the workflow:** both jobs carry `if: github.actor == github.repository_owner`. Anyone else who triggers a run, even if they are added to the repo later, gets skipped jobs.
3. **Least-privilege token:** the workflow sets `permissions: contents: read`, and the repo's default workflow token is read-only, so a run cannot push code or change the repo.

### Why permissions should be limited

- **The self-hosted runner executes whatever the workflow says, as my Windows user.** Anyone who can run or edit a workflow can run commands on my machine, with access to my files, my Docker, and my other clusters. This is the main risk, and it is why the repo is private and the deploy job is owner-only. Never attach a self-hosted runner to a public repo, since any pull request could change the workflow.
- **The deploy job changes production.** Starting it should be a deliberate act by one accountable person, not a side effect of someone else's push.
- **Blast radius:** a compromised account or a malicious pull request can do only what its token allows. A read-only token plus an owner check keeps that small.
- **Cost and abuse:** hosted-runner minutes are limited, and untrusted triggers can burn them or run unwanted workloads.
- **Auditability:** one authorised actor makes it clear who ran what.

If the project grows to include collaborators, relax this on purpose: keep `deploy-prod` owner-only (or behind a required-reviewer `production` environment), and let others run only `test`.

## Run locally

```sh
scripts/create-cluster.sh clusters/staging.yaml
kubectl apply -k k8s/overlays/staging
scripts/smoke-test.sh kind-kubernauts-staging
kind delete cluster --name kubernauts-staging
```

Requires Docker, `kind`, and `kubectl`.
