#!/usr/bin/env bash
# Sample collector pod memory during soak test (for sync.Pool / leak analysis).
set -euo pipefail

NS="${NAMESPACE:-vsan-observability}"
INTERVAL="${MEM_WATCH_INTERVAL:-30}"
OUT="${1:-docs/reports/collector-mem-$(date -u +%Y%m%d-%H%M%S).tsv}"

mkdir -p "$(dirname "${OUT}")"
echo -e "timestamp_utc\tcpu_millicores\tmemory_mi" > "${OUT}"

echo "==> watching vsan-collector memory every ${INTERVAL}s → ${OUT}"
echo "    stop with Ctrl+C"

while true; do
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(kubectl top pod -n "${NS}" -l app=vsan-collector --no-headers 2>/dev/null | head -1 || true)"
  if [[ -n "${line}" ]]; then
    cpu="$(echo "${line}" | awk '{print $2}' | tr -d 'm')"
    mem="$(echo "${line}" | awk '{print $3}' | tr -d 'Mi')"
    echo -e "${ts}\t${cpu}\t${mem}" >> "${OUT}"
    echo "${ts}  CPU=${cpu}m  MEM=${mem}Mi"
  else
    echo "${ts}  (metrics-server unavailable or pod not found)" >&2
  fi
  sleep "${INTERVAL}"
done
