 #!/usr/bin/env bash
# One-click deploy of the full vsan-observability stack on minikube.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-vsan-observability}"
SKIP_BUILD=false
SKIP_MINIKUBE_START=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploy collector, processor, query-api, Kafka, InfluxDB, Prometheus, and Grafana on minikube.

Uses Helm when available (`deploy/helm/vsan-observability`); falls back to `deploy/k8s/` flat YAML.

Options:
  --skip-build           Skip docker image builds (reuse existing local images)
  --skip-minikube-start  Do not run 'minikube start' if cluster is down
  -h, --help             Show this help

Environment:
  NAMESPACE   Kubernetes namespace (default: vsan-observability)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true ;;
    --skip-minikube-start) SKIP_MINIKUBE_START=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

need() {
  # 这里的 command 实际上是一个 Linux 内置的 shell 命令，用于判断某个可执行程序或命令是否存在于当前环境的 PATH 目录中。
  # command -v "$1" 会返回命令的路径，如果找不到则返回非零退出码。
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need minikube
need kubectl
need docker
if command -v helm >/dev/null 2>&1; then
  HAS_HELM=true
else
  HAS_HELM=false
  echo "warning: helm not found — will fall back to kubectl apply deploy/k8s/" >&2
fi

if ! $SKIP_MINIKUBE_START; then
  if ! minikube status >/dev/null 2>&1; then
    echo "==> starting minikube..."
    minikube start --cpus=4 --memory=6144
  else
    echo "==> minikube already running"
  fi
fi

echo "==> enabling metrics-server (required for HPA and kubectl top)"
minikube addons enable metrics-server >/dev/null 2>&1 || true
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || true
fi

echo "==> using minikube docker daemon (single-node) or host docker + image load (multi-node)"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-}"
MINIKUBE_ARGS=()
[[ -n "${MINIKUBE_PROFILE}" ]] && MINIKUBE_ARGS=(-p "${MINIKUBE_PROFILE}")
multinode=false
if minikube node list "${MINIKUBE_ARGS[@]}" 2>/dev/null | grep -qE 'm0[2-9]'; then
  multinode=true
fi

if ! $SKIP_BUILD; then
  echo "==> building application images..."
  if $multinode; then
    for svc in collector processor query-api; do
      docker build \
        --build-arg "SERVICE=${svc}" \
        -f "${ROOT}/deploy/docker/Dockerfile" \
        -t "vsan-${svc}:latest" \
        "${ROOT}"
      minikube image load "vsan-${svc}:latest" "${MINIKUBE_ARGS[@]}"
    done
  else
    eval "$(minikube docker-env "${MINIKUBE_ARGS[@]}")"
    for svc in collector processor query-api; do
      docker build \
        --build-arg "SERVICE=${svc}" \
        -f "${ROOT}/deploy/docker/Dockerfile" \
        -t "vsan-${svc}:latest" \
        "${ROOT}"
    done
  fi
else
  echo "==> skipping image build"
fi

echo "==> deploying stack (values.yaml + values-prod.yaml)..."
CHART="${ROOT}/deploy/helm/vsan-observability"
if $HAS_HELM && [[ -f "${CHART}/Chart.yaml" ]]; then
  # values.yaml + values-prod.yaml: Helm merges overlays (prod overrides base).
  helm upgrade --install vsan "${CHART}" \
    -n "$NS" \
    --create-namespace \
    -f "${CHART}/values.yaml" \
    -f "${CHART}/values-prod.yaml" \
    --wait \
    --timeout 1200s
else
  echo "==> applying kubernetes manifests (legacy)..."
  kubectl apply -f "${ROOT}/deploy/k8s/"
  echo "==> ensuring kafka topic exists..."
  kubectl delete job kafka-init-topic -n "$NS" --ignore-not-found
  kubectl apply -f "${ROOT}/deploy/k8s/04-kafka-topic-job.yaml"
  kubectl wait --for=condition=complete job/kafka-init-topic -n "$NS" --timeout=180s
fi

echo "==> waiting for infrastructure..."
kubectl rollout status deployment/kafka -n "$NS" --timeout=300s
kubectl rollout status statefulset/influxdb -n "$NS" --timeout=300s

echo "==> waiting for application workloads..."
kubectl rollout status deployment/vsan-collector -n "$NS" --timeout=300s
if kubectl get hpa vsan-collector -n "$NS" >/dev/null 2>&1; then
  echo "==> HPA vsan-collector:"
  kubectl get hpa vsan-collector -n "$NS"
fi
kubectl rollout status deployment/vsan-processor -n "$NS" --timeout=300s
kubectl rollout status deployment/vsan-query-api -n "$NS" --timeout=300s
kubectl rollout status deployment/prometheus -n "$NS" --timeout=300s
kubectl rollout status deployment/grafana -n "$NS" --timeout=300s

MINIKUBE_IP="$(minikube ip)"
GRAFANA_URL="http://${MINIKUBE_IP}:30300"
PROMETHEUS_URL="http://${MINIKUBE_IP}:30090"
COLLECTOR_URL="http://${MINIKUBE_IP}:30080"
QUERY_API_URL="http://${MINIKUBE_IP}:30082"

cat <<EOF

================================================================================
vSAN Observability is up in namespace: ${NS}

Grafana:
  URL:       ${GRAFANA_URL}
  User:      admin / admin
  Dashboards:
    - vSAN Observability / vSAN API Observability  (InfluxDB — API latency)
    - vSAN Observability / vSAN Service Metrics    (Prometheus — collector/processor)

Prometheus:
  URL:  ${PROMETHEUS_URL}
  Targets: Status → Targets (vsan-collector, vsan-processor should be UP)

Collector (ingest):
  URL:  ${COLLECTOR_URL}
  POST: ${COLLECTOR_URL}/v1/ingest
  Metrics: ${COLLECTOR_URL}/metrics

Query API:
  URL: ${QUERY_API_URL}

Mac / ClusterIP tip — prod values use ClusterIP; use port-forward:
  kubectl port-forward svc/grafana 3000:3000 -n ${NS}
  kubectl port-forward svc/prometheus 9090:9090 -n ${NS}
  kubectl port-forward svc/vsan-collector 8080:8080 -n ${NS}

Sample ingest (optional):
  curl -s -o /dev/null -w "HTTP %{http_code}\\n" \\
    -X POST "${COLLECTOR_URL}/v1/ingest" \\
    -H "Content-Type: application/json" \\
    -d '{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","source":"demo","tenant":"t1","api_name":"GET /v1/clusters","latency_ms":42.5,"status_code":200}'

Pods:
EOF
kubectl get pods -n "$NS"

cat <<EOF

To tear down: ${ROOT}/scripts/minikube-down.sh
EOF
