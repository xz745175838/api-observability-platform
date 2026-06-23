#!/usr/bin/env bash
# Snapshot key PromQL counters/gauges at a point in time (end of load test).
set -euo pipefail

NS="${NAMESPACE:-vsan-observability}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
OUT="${1:-}"

query() {
  local q="$1"
  curl -sG "${PROM_URL}/api/v1/query" --data-urlencode "query=${q}" \
    | jq -r '.data.result[]? | "\(.metric | tostring) \(.value[1])"' 2>/dev/null || true
}

snap() {
  local title="$1"
  local q="$2"
  echo "### ${title}"
  echo '```'
  query "$q" || echo "(no data or prometheus unreachable)"
  echo '```'
  echo
}

{
  echo "# Prometheus snapshot"
  echo "time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "prometheus: ${PROM_URL}"
  echo

  snap "Ingest rate (1m)" 'sum(rate(collector_ingest_total[1m]))'
  snap "Publish rate (1m)" 'sum(rate(collector_published_total[1m]))'
  snap "Drop rate (1m)" 'sum(rate(collector_drop_total[1m]))'
  snap "Drop ratio (5m)" 'sum(rate(collector_drop_total[5m])) / clamp_min(sum(rate(collector_ingest_total[5m])), 1)'
  snap "Channel utilization" 'collector_channel_utilization'
  snap "Collector e2e latency p95 (5m)" 'histogram_quantile(0.95, sum(rate(collector_end_to_end_latency_seconds_bucket[5m])) by (le))'
  snap "Processor write latency p95 (5m)" 'histogram_quantile(0.95, sum(rate(storage_write_latency_seconds_bucket[5m])) by (le, backend))'
  snap "Processor errors (1m)" 'sum(rate(processor_errors_total[1m])) by (stage, backend)'
} > "${OUT:-/dev/stdout}"
