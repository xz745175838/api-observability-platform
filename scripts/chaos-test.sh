#!/usr/bin/env bash
# Chaos experiment: inject processor/kafka faults under load and observe backpressure + recovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-vsan-observability}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
COLLECTOR_URL="${COLLECTOR_URL:-http://localhost:8080}"
MANAGE_PORT_FORWARD="${MANAGE_PORT_FORWARD:-true}"

MODE="${CHAOS_MODE:-random}"          # random | kill-processor | kill-kafka | network
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"
BASELINE_SEC="${BASELINE_SEC:-15}"
NETWORK_BLOCK_SEC="${NETWORK_BLOCK_SEC:-30}"
RECOVERY_SEC="${RECOVERY_SEC:-90}"
CHAOS_POLICY_NAME="${CHAOS_POLICY_NAME:-chaos-deny-processor-kafka}"

REPORT_DIR="${ROOT}/docs/reports"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
REPORT="${REPORT_DIR}/chaos-test-${STAMP}.md"
METRICS_LOG="${REPORT_DIR}/chaos-metrics-${STAMP}.tsv"
MEM_LOG="${REPORT_DIR}/chaos-collector-mem-${STAMP}.tsv"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Inject faults while upstream load runs (start k6 in another terminal first).

Recommended load (terminal 2):
  kubectl port-forward svc/vsan-collector 8080:8080 -n ${NS} &
  ./scripts/run-loadtest.sh --profile spike --no-port-forward

Or sustained load:
  LOAD_PROFILE=soak SOAK_DURATION=10m k6 run scripts/loadtest/ingest.js

Options:
  --mode random|kill-processor|kill-kafka|network   Fault type (default: random)
  --baseline-sec N        Observe metrics before chaos (default: ${BASELINE_SEC})
  --network-block-sec N   NetworkPolicy block duration (default: ${NETWORK_BLOCK_SEC})
  --recovery-sec N        Observe after heal (default: ${RECOVERY_SEC})
  --monitor-interval N    Prometheus sample interval seconds (default: ${MONITOR_INTERVAL})
  --no-port-forward       Do not start kubectl port-forward to prometheus:9090
  -h, --help

Environment:
  NAMESPACE, PROM_URL, COLLECTOR_URL, CHAOS_MODE, MONITOR_INTERVAL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --baseline-sec) BASELINE_SEC="$2"; shift 2 ;;
    --network-block-sec) NETWORK_BLOCK_SEC="$2"; shift 2 ;;
    --recovery-sec) RECOVERY_SEC="$2"; shift 2 ;;
    --monitor-interval) MONITOR_INTERVAL="$2"; shift 2 ;;
    --no-port-forward) MANAGE_PORT_FORWARD=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need kubectl
need curl
need jq

mkdir -p "${REPORT_DIR}"

PF_PIDS=()
CHAOS_POLICY_APPLIED=false
cleanup() {
  if $CHAOS_POLICY_APPLIED; then
    kubectl delete networkpolicy "${CHAOS_POLICY_NAME}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  fi
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

prom_scalar() {
  local q="$1"
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=${q}" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}

# Fallback: scrape collector /metrics for counter totals when Prometheus is down.
collector_counter() {
  local name="$1"
  curl -sf "${COLLECTOR_URL}/metrics" 2>/dev/null \
    | awk -v n="${name}" '$1 ~ "^"n"{total|"_total"}" && $1 !~ /created/ {sum+=$2} END {printf "%.0f", sum+0}' || echo "n/a"
}

sample_metrics() {
  local phase="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local ingest_rate drop_rate publish_rate drop_ratio channel_util
  local ingest_total drop_total

  if curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
    ingest_rate="$(prom_scalar 'sum(rate(collector_ingest_total[1m]))')"
    drop_rate="$(prom_scalar 'sum(rate(collector_drop_total[1m]))')"
    publish_rate="$(prom_scalar 'sum(rate(collector_published_total[1m]))')"
    drop_ratio="$(prom_scalar 'sum(rate(collector_drop_total[1m])) / clamp_min(sum(rate(collector_ingest_total[1m])), 1)')"
    channel_util="$(prom_scalar 'max(collector_channel_utilization)')"
    ingest_total="$(prom_scalar 'sum(collector_ingest_total)')"
    drop_total="$(prom_scalar 'sum(collector_drop_total)')"
  else
    ingest_rate="n/a"
    drop_rate="n/a"
    publish_rate="n/a"
    drop_ratio="n/a"
    channel_util="n/a"
    ingest_total="$(collector_counter collector_ingest_total)"
    drop_total="$(collector_counter collector_drop_total)"
  fi

  echo -e "${ts}\t${phase}\t${ingest_rate}\t${drop_rate}\t${publish_rate}\t${drop_ratio}\t${channel_util}\t${ingest_total}\t${drop_total}" >> "${METRICS_LOG}"

  printf '%-10s ingest/s=%-8s drop/s=%-8s publish/s=%-8s drop_ratio=%-8s channel=%-6s ingest_total=%s drop_total=%s\n' \
    "${phase}" "${ingest_rate:-n/a}" "${drop_rate:-n/a}" "${publish_rate:-n/a}" "${drop_ratio:-n/a}" "${channel_util:-n/a}" "${ingest_total:-n/a}" "${drop_total:-n/a}"
}

sample_collector_memory() {
  local phase="$1"
  local ts line cpu mem
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while read -r line; do
    [[ -z "${line}" ]] && continue
    cpu="$(echo "${line}" | awk '{print $2}')"
    mem="$(echo "${line}" | awk '{print $3}')"
    echo -e "${ts}\t${phase}\t${line}" >> "${MEM_LOG}"
    echo "  mem  ${line}"
  done < <(kubectl top pod -n "${NS}" -l app=vsan-collector --no-headers 2>/dev/null || true)
}

monitor_loop() {
  local phase="$1"
  local duration="$2"
  local end=$((SECONDS + duration))
  while [[ "${SECONDS}" -lt "${end}" ]]; do
    sample_metrics "${phase}"
    sleep "${MONITOR_INTERVAL}"
  done
}

pick_random_mode() {
  local modes=(kill-processor kill-kafka network)
  echo "${modes[RANDOM % ${#modes[@]}]}"
}

random_pod() {
  local label="$1"
  local -a pods=()
  local name
  while IFS= read -r name; do
    [[ -n "${name}" ]] && pods+=("${name}")
  done < <(kubectl get pods -n "${NS}" -l "app=${label}" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  ((${#pods[@]} == 0)) && return 0
  echo "${pods[RANDOM % ${#pods[@]}]}"
}

wait_deployment_ready() {
  local deploy="$1"
  local timeout="${2:-180}"
  kubectl rollout status "deployment/${deploy}" -n "${NS}" --timeout="${timeout}s" >/dev/null 2>&1
}

apply_network_chaos() {
  log "Applying NetworkPolicy ${CHAOS_POLICY_NAME} (block processor → kafka egress)"
  kubectl apply -n "${NS}" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${CHAOS_POLICY_NAME}
  labels:
    app.kubernetes.io/component: chaos
spec:
  podSelector:
    matchLabels:
      app: vsan-processor
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - to:
        - podSelector:
            matchLabels:
              app: influxdb
      ports:
        - protocol: TCP
          port: 8086
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
EOF
  CHAOS_POLICY_APPLIED=true
}

remove_network_chaos() {
  if $CHAOS_POLICY_APPLIED; then
    log "Removing NetworkPolicy ${CHAOS_POLICY_NAME}"
    kubectl delete networkpolicy "${CHAOS_POLICY_NAME}" -n "${NS}" --ignore-not-found
    CHAOS_POLICY_APPLIED=false
  fi
}

inject_kill_processor() {
  local pod
  pod="$(random_pod vsan-processor)"
  if [[ -z "${pod}" ]]; then
    log "ERROR: no running vsan-processor pod found"
    return 1
  fi
  log "CHAOS: deleting processor pod ${pod}"
  kubectl delete pod "${pod}" -n "${NS}" --wait=false
}

inject_kill_kafka() {
  local pod
  pod="$(random_pod kafka)"
  if [[ -z "${pod}" ]]; then
    log "ERROR: no running kafka pod found"
    return 1
  fi
  log "CHAOS: deleting kafka pod ${pod}"
  kubectl delete pod "${pod}" -n "${NS}" --wait=false
}

inject_fault() {
  local m="$1"
  case "${m}" in
    kill-processor) inject_kill_processor ;;
    kill-kafka) inject_kill_kafka ;;
    network)
      apply_network_chaos || {
        log "WARN: NetworkPolicy failed (CNI may not support it). Falling back to kill-kafka."
        inject_kill_kafka
        m="kill-kafka-fallback"
      }
      ;;
    *)
      log "unknown mode: ${m}"
      return 1
      ;;
  esac
  echo "${m}"
}

verify_recovery() {
  local ok=true
  log "=== Recovery verification ==="

  if ! wait_deployment_ready vsan-collector 120; then
    log "FAIL: vsan-collector deployment not ready"
    ok=false
  else
    log "OK: vsan-collector deployment ready"
  fi

  if ! wait_deployment_ready vsan-processor 180; then
    log "FAIL: vsan-processor deployment not ready"
    ok=false
  else
    log "OK: vsan-processor deployment ready"
  fi

  local crash
  crash="$(kubectl get pods -n "${NS}" --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${crash}" -gt 0 ]]; then
    log "WARN: ${crash} pods not Running/Succeeded:"
    kubectl get pods -n "${NS}" | grep -Ev 'Running|Completed|Succeeded' || true
    ok=false
  fi

  local pub drop_r
  pub="$(prom_scalar 'sum(rate(collector_published_total[1m]))' || true)"
  drop_r="$(prom_scalar 'sum(rate(collector_drop_total[1m]))' || true)"
  log "Post-recovery publish/s=${pub:-n/a}  drop/s=${drop_r:-n/a}"

  if [[ -n "${pub}" && "${pub}" != "n/a" ]]; then
    if awk -v p="${pub}" 'BEGIN { exit (p > 0.1) ? 0 : 1 }'; then
      log "OK: publish rate recovered (> 0.1/s)"
    else
      log "WARN: publish rate still low — check processor logs / kafka"
      ok=false
    fi
  fi

  if [[ -n "${drop_r}" && "${drop_r}" != "n/a" ]]; then
    if awk -v d="${drop_r}" 'BEGIN { exit (d < 1) ? 0 : 1 }'; then
      log "OK: drop rate near zero (< 1/s)"
    else
      log "WARN: elevated drop rate — backpressure may still be active"
    fi
  fi

  log "Collector restarts (should be low after recovery):"
  kubectl get pods -n "${NS}" -l app=vsan-collector -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount

  sample_collector_memory "recovery"

  $ok && return 0 || return 1
}

# --- main ---

echo "================================================================================"
echo " vSAN Chaos Test — backpressure & self-healing"
echo " Report: ${REPORT}"
echo "================================================================================"
echo ""
echo ">>> Start load in another terminal BEFORE chaos begins (if not already running):"
echo ""
echo "  kubectl port-forward svc/vsan-collector 8080:8080 -n ${NS} &"
echo "  kubectl port-forward svc/prometheus 9090:9090 -n ${NS} &"
echo "  ./scripts/run-loadtest.sh --profile spike --no-port-forward"
echo ""
echo "  # or sustained:"
echo "  LOAD_PROFILE=soak SOAK_DURATION=15m k6 run scripts/loadtest/ingest.js"
echo ""
read -r -p "Press Enter when load is running (or Ctrl+C to abort)... " _

if $MANAGE_PORT_FORWARD; then
  if ! curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
    log "Starting port-forward prometheus 9090"
    kubectl port-forward svc/prometheus 9090:9090 -n "${NS}" >/dev/null 2>&1 &
    PF_PIDS+=($!)
    sleep 2
  fi
  if ! curl -sf "${COLLECTOR_URL}/healthz" >/dev/null 2>&1; then
    log "Starting port-forward collector 8080"
    kubectl port-forward svc/vsan-collector 8080:8080 -n "${NS}" >/dev/null 2>&1 &
    PF_PIDS+=($!)
    sleep 2
  fi
fi

if ! curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then
  log "WARN: Prometheus not reachable at ${PROM_URL}; using collector /metrics fallback for counters"
fi

echo -e "timestamp_utc\tphase\tingest_rate\tdrop_rate\tpublish_rate\tdrop_ratio\tchannel_util\tingest_total\tdrop_total" > "${METRICS_LOG}"
echo -e "timestamp_utc\tphase\tpod\tcpu\tmemory" > "${MEM_LOG}"

SELECTED_MODE="${MODE}"
if [[ "${MODE}" == "random" ]]; then
  SELECTED_MODE="$(pick_random_mode)"
  log "Random mode selected: ${SELECTED_MODE}"
fi

log "Phase 1/4: baseline (${BASELINE_SEC}s) — establish ingest/drop trend"
sample_collector_memory "baseline-start"
monitor_loop "baseline" "${BASELINE_SEC}"

log "Phase 2/4: inject chaos (mode=${SELECTED_MODE})"
FAULT_APPLIED="$(inject_fault "${SELECTED_MODE}")"

log "Phase 3/4: observe under fault (${NETWORK_BLOCK_SEC}s for network; ${MONITOR_INTERVAL}s interval)"
FAULT_DURATION="${NETWORK_BLOCK_SEC}"
if [[ "${FAULT_APPLIED}" == kill-* ]]; then
  FAULT_DURATION="${NETWORK_BLOCK_SEC}"  # same observation window
fi
monitor_loop "chaos" "${FAULT_DURATION}"

if [[ "${FAULT_APPLIED}" == "network" ]] || [[ "${FAULT_APPLIED}" == *network* ]]; then
  remove_network_chaos
fi

log "Phase 4/4: recovery observation (${RECOVERY_SEC}s)"
monitor_loop "recovery" "${RECOVERY_SEC}"

RECOVERY_OK=true
verify_recovery || RECOVERY_OK=false

# Recent processor errors (graceful shutdown / panic signals)
PROC_LOG_SNIPPET=""
PROC_POD="$(kubectl get pods -n "${NS}" -l app=vsan-processor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${PROC_POD}" ]]; then
  PROC_LOG_SNIPPET="$(kubectl logs "${PROC_POD}" -n "${NS}" --tail=30 2>/dev/null | tail -15 || true)"
fi

cat > "${REPORT}" <<EOF
# Chaos test report

- **Date (UTC):** $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Namespace:** \`${NS}\`
- **Fault mode:** \`${FAULT_APPLIED}\`
- **Baseline / chaos / recovery:** ${BASELINE_SEC}s / ${FAULT_DURATION}s / ${RECOVERY_SEC}s
- **Recovery check:** $(if $RECOVERY_OK; then echo "PASS"; else echo "FAIL (see log)"; fi)

## Hypothesis

| Scenario | Expected backpressure signal | Expected recovery |
|----------|------------------------------|-------------------|
| kill-processor | publish rate ↓; channel util may ↑; drop may ↑ if load high | new processor pod; publish rate returns |
| kill-kafka | publish stalls; channel fills; **drop rate ↑** | kafka pod restarted; consume resumes |
| network (processor↛kafka) | same as kafka partial outage | policy removed; lag drains |

## Metrics time series

TSV: \`${METRICS_LOG}\`

\`\`\`tsv
$(tail -n 40 "${METRICS_LOG}" 2>/dev/null || echo "(empty)")
\`\`\`

## Collector memory samples

\`${MEM_LOG}\`

## Processor log tail (post-run)

\`\`\`
${PROC_LOG_SNIPPET:-"(no logs)"}
\`\`\`

## Manual follow-up

- Grafana: vSAN Service Metrics — drop rate spike during chaos, recovery after
- \`kubectl get pods -n ${NS} -o wide\` — anti-affinity spread after restarts
- Compare first vs last \`ingest_total\` / \`drop_total\` in TSV for monotonic counters

EOF

log "Report written: ${REPORT}"
log "Metrics TSV:    ${METRICS_LOG}"
if $RECOVERY_OK; then
  log "Recovery verification: PASS"
  exit 0
else
  log "Recovery verification: FAIL (see report)"
  exit 1
fi
