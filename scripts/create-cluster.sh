#!/usr/bin/env bash
# Idempotently create a kind cluster. Usage: create-cluster.sh clusters/prod.yaml
set -euo pipefail
cfg="${1:?cluster config required}"
name="$(awk '/^name:/ {print $2}' "$cfg")"
if kind get clusters 2>/dev/null | grep -qx "$name"; then
  echo "cluster $name already exists"
else
  kind create cluster --config "$cfg"
fi
