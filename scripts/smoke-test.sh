#!/usr/bin/env bash
# Usage: smoke-test.sh <kube-context>
set -euo pipefail
ctx="${1:?kube context required}"
k="kubectl --context $ctx -n kubernauts"

$k rollout status deployment/web --timeout=180s

$k port-forward svc/web 18080:80 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT

for _ in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:18080/healthz >/dev/null; then
    echo "smoke test passed on $ctx"
    exit 0
  fi
  sleep 2
done
echo "smoke test FAILED on $ctx" >&2
exit 1
