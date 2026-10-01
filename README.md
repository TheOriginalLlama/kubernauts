# Kubernauts

A small Kubernetes pipeline: cluster definitions in YAML, a CI job that tests every change, and a deploy job that promotes the tested commit to production.

```
clusters/      kind cluster definitions (staging, prod)
k8s/base/      the app (podinfo) as plain manifests
k8s/overlays/  staging and prod variants (kustomize)
scripts/       create-cluster.sh, smoke-test.sh
.github/workflows/pipeline.yaml
```

## Pipeline

1. **test** (GitHub-hosted, on PRs and `main`): validate manifests with kubeconform, build an ephemeral cluster from `clusters/staging.yaml`, apply the staging overlay, smoke test.
2. **deploy-prod** (self-hosted runner, `main` only, after test passes): create `kubernauts-prod` if missing, show a diff, apply the prod overlay, smoke test.

## Production runner setup (one time)

Prod is a local kind cluster, so deploys need a self-hosted runner on this machine: repo Settings > Actions > Runners > New self-hosted runner (Windows). Use a private repo only, since self-hosted runners execute workflow code.
Create a `production` environment under Settings > Environments. Required reviewers (the manual approval gate) need GitHub Pro on private personal repos.

## Run locally

```sh
scripts/create-cluster.sh clusters/staging.yaml
kubectl apply -k k8s/overlays/staging
scripts/smoke-test.sh kind-kubernauts-staging
```
