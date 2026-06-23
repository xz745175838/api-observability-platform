#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-vsan-observability}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-}"
MINIKUBE_ARGS=()
[[ -n "${MINIKUBE_PROFILE}" ]] && MINIKUBE_ARGS=(-p "${MINIKUBE_PROFILE}")

echo "==> uninstalling helm release vsan (if present)..."
if helm status vsan -n "${NS}" >/dev/null 2>&1; then
  helm uninstall vsan -n "${NS}" --wait --timeout 5m || true
fi

echo "==> deleting namespace ${NS}..."
kubectl delete namespace "$NS" --ignore-not-found --wait=true

if minikube status "${MINIKUBE_ARGS[@]}" >/dev/null 2>&1; then
  multinode=false
  if minikube node list "${MINIKUBE_ARGS[@]}" 2>/dev/null | grep -qE 'm0[2-9]'; then
    multinode=true
  fi

  echo "==> removing local application images..."
  if $multinode; then
    # Multi-node: images were loaded via `minikube image load`; docker-env is unsupported.
    for img in vsan-collector vsan-processor vsan-query-api; do
      minikube image rm "${img}:latest" "${MINIKUBE_ARGS[@]}" 2>/dev/null || true
      docker rmi "${img}:latest" 2>/dev/null || true
    done
  else
    eval "$(minikube docker-env "${MINIKUBE_ARGS[@]}")"
    for img in vsan-collector vsan-processor vsan-query-api; do
      docker rmi "${img}:latest" 2>/dev/null || true
    done
  fi
fi

echo "Done. Run ${ROOT}/scripts/minikube-up.sh to redeploy."
