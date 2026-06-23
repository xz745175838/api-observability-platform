#!/usr/bin/env bash
# Run k6 ingest load test against minikube collector and emit a markdown report.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-vsan-observability}"
PROFILE="${LOAD_PROFILE:-ramp}"
COLLECTOR_URL="${COLLECTOR_URL:-http://localhost:8080}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
MANAGE_PORT_FORWARD="${MANAGE_PORT_FORWARD:-true}"
SOAK_DURATION="${SOAK_DURATION:-30m}"
WATCH_MEM="${WATCH_MEM:-false}"

REPORT_DIR="${ROOT}/docs/reports"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
REPORT="${REPORT_DIR}/load-test-${PROFILE}-${STAMP}.md"
K6_JSON="${REPORT_DIR}/k6-summary-${PROFILE}-${STAMP}.json"
MEM_LOG="${REPORT_DIR}/collector-mem-${PROFILE}-${STAMP}.tsv"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Run k6 ingest load test and write a report under docs/reports/.

Profiles:
  ramp   Step VUs to find saturation knee (~5m)
  spike  50 RPS × 30s → 2000 RPS × 30s → 10 RPS × 30s (~90s HPA demo)
  soak   250 RPS sustained (default 30m; set SOAK_DURATION=1h for 1 hour)

Options:
  --profile ramp|spike|soak   Load shape (default: ramp)
  --collector-url URL         Collector base URL (default: http://localhost:8080)
  --no-port-forward           Do not start kubectl port-forward helpers
  --watch-mem                 Start collector memory sampler (recommended for soak)
  -h, --help

Prerequisites:
  brew install k6 jq
  Cluster running: ./scripts/minikube-up.sh
  metrics-server enabled for --watch-mem (minikube addons enable metrics-server)

Environment:
  LOAD_PROFILE, COLLECTOR_URL, PROM_URL, NAMESPACE, SOAK_DURATION, SOAK_RPS
  SPIKE_BASELINE_RPS, SPIKE_BURST_RPS, SPIKE_BURST_DURATION, SPIKE_RECOVERY_DURATION
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --collector-url) COLLECTOR_URL="$2"; shift 2 ;;
    --no-port-forward) MANAGE_PORT_FORWARD=false; shift ;;
    --watch-mem) WATCH_MEM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing: $1" >&2
    exit 1
  }
}

need k6
need jq
need kubectl

mkdir -p "${REPORT_DIR}"

PF_PIDS=()
MEM_PID=""
cleanup() {
  [[ -n "${MEM_PID}" ]] && kill "${MEM_PID}" 2>/dev/null || true
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

if $MANAGE_PORT_FORWARD; then
  echo "==> starting port-forward (collector 8080, prometheus 9090)"
  kubectl port-forward svc/vsan-collector 8080:8080 -n "$NS" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  kubectl port-forward svc/prometheus 9090:9090 -n "$NS" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  sleep 2
fi

if [[ "${PROFILE}" == "soak" ]] || $WATCH_MEM; then
  echo "==> starting collector memory watch → ${MEM_LOG}"
  bash "${ROOT}/scripts/loadtest/watch-collector-mem.sh" "${MEM_LOG}" &
  MEM_PID=$!
fi

echo "==> health check ${COLLECTOR_URL}/healthz"
curl -sf "${COLLECTOR_URL}/healthz" >/dev/null || {
  echo "collector unreachable at ${COLLECTOR_URL}" >&2
  echo "hint: kubectl port-forward svc/vsan-collector 8080:8080 -n ${NS}" >&2
  exit 1
}

echo "==> running k6 profile=${PROFILE}"
cd "${ROOT}"
K6_EXIT=0
LOAD_PROFILE="${PROFILE}" COLLECTOR_URL="${COLLECTOR_URL}" SOAK_DURATION="${SOAK_DURATION}" \
  k6 run --summary-export "${K6_JSON}" "${ROOT}/scripts/loadtest/ingest.js" || K6_EXIT=$?

if [[ "${K6_EXIT}" -ne 0 ]]; then
  echo "==> k6 exited with code ${K6_EXIT} (threshold miss is expected for ramp/spike capacity tests)"
fi

PROM_SNAP="${REPORT_DIR}/prometheus-snapshot-${STAMP}.md"
if curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
  echo "==> snapshotting prometheus metrics"
  bash "${ROOT}/scripts/loadtest/snapshot-prometheus.sh" "${PROM_SNAP}"
else
  echo "==> prometheus not reachable at ${PROM_URL}; skipping snapshot"
  PROM_SNAP=""
fi

HTTP_REQS="$(jq -r '.metrics.http_reqs.count // .metrics.http_reqs.values.count // 0' "${K6_JSON}")"
HTTP_RATE="$(jq -r '.metrics.http_reqs.rate // .metrics.http_reqs.values.rate // 0' "${K6_JSON}")"
ACCEPT_RATE="$(jq -r '.metrics.vsan_ingest_accept_rate.value // .metrics.vsan_ingest_accept_rate.values.rate // 0' "${K6_JSON}")"
REJ503="$(jq -r '.metrics.vsan_ingest_rejected_503.count // .metrics.vsan_ingest_rejected_503.values.count // 0' "${K6_JSON}")"
P95_503="$(jq -r '.metrics.vsan_latency_503_ms["p(99)"] // .metrics.vsan_latency_503_ms.values["p(99)"] // "n/a"' "${K6_JSON}" 2>/dev/null)"
P99_202="$(jq -r '.metrics.vsan_latency_202_ms["p(99)"] // .metrics.vsan_latency_202_ms.values["p(99)"] // "n/a"' "${K6_JSON}" 2>/dev/null)"

PROFILE_NOTES=""
case "${PROFILE}" in
  spike)
    PROFILE_NOTES="### Spike SRE checklist (90s pulse)
- **Shape:** 50 RPS × 30s → 2000 RPS × 30s → 10 RPS × 30s
- **Fast-fail 503 p99:** ${P95_503} ms (expect single-digit to low tens of ms)
- **Core 202 p99:** ${P99_202} ms (should not be dragged by burst)
- **HPA:** replicas should rise during 30–60s burst if metrics-server healthy
- **Recovery:** after 60s, drop rate → 0; channel util falls; HPA scales down ~60s later"
    ;;
  soak)
    PROFILE_NOTES="### Soak SRE checklist
- **Memory:** ${MEM_LOG} — expect sawtooth 40–60Mi; staircase = leak/OOM risk
- **202 p99 drift:** end-of-run ${P99_202} ms — compare Grafana at T+5m / T+20m / T+50m
- **Accept rate:** $(awk "BEGIN {printf \"%.2f%%\", ${ACCEPT_RATE}*100}") at ${SOAK_RPS} RPS (should stay ~100%)"
    ;;
esac

cat > "${REPORT}" <<EOF
# Load test report — ${PROFILE}

- **Date (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Environment:** minikube (4 CPU / 6 GiB per \`minikube-up.sh\`)
- **Target:** \`${COLLECTOR_URL}/v1/ingest\`
- **Profile:** \`${PROFILE}\`
- **k6 JSON:** \`${K6_JSON}\`
- **k6 exit code:** ${K6_EXIT} (non-zero = threshold miss; report still generated)

## k6 client-side results

| Metric | Value |
|--------|-------|
| Total HTTP requests | ${HTTP_REQS} |
| Request rate (avg) | ${HTTP_RATE} req/s |
| 202 accept rate | $(awk "BEGIN {printf \"%.2f%%\", ${ACCEPT_RATE}*100}") |
| 503 rejections | ${REJ503} |
| 503 p99 latency | ${P95_503} ms |
| 202 p99 latency | ${P99_202} ms |

${PROFILE_NOTES}

## Prometheus snapshot (post-run)

$(if [[ -n "${PROM_SNAP}" && -f "${PROM_SNAP}" ]]; then cat "${PROM_SNAP}"; else echo "_Skipped — port-forward prometheus:9090_"; fi)

## Memory log

$(if [[ -f "${MEM_LOG}" ]]; then echo "Collector memory TSV: \`${MEM_LOG}\`"; else echo "_No memory log (use --watch-mem or soak profile)_"; fi)

## Conclusion (edit after review)

- **Primary bottleneck:** _TODO_
- **Channel 10000 verdict:** _TODO_

EOF

echo ""
echo "Report written: ${REPORT}"
echo "k6 JSON:        ${K6_JSON}"
[[ -f "${MEM_LOG}" ]] && echo "Memory log:     ${MEM_LOG}"
[[ -n "${PROM_SNAP}" && -f "${PROM_SNAP}" ]] && echo "Prometheus:     ${PROM_SNAP}"

exit 0
