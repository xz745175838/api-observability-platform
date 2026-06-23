# vSAN API Observability Platform

High-throughput Go microservices: **collector** (HTTP → Kafka), **processor** (Kafka → TSDB), **query-api** (dashboard backend stub).

## Layout

Standard Go project layout under this module (`github.com/vsan/observability`):

- `cmd/` — binaries
- `internal/app/` — use-case orchestration
- `internal/contract/` — interfaces (storage, queue, processor, …)
- `internal/domain/` — models
- `internal/infra/` — kafka, influx, gin, prometheus, runtime
- `configs/`, `deploy/`, `docs/`, `api/`, `scripts/`

## Minikube (full stack, one command)

Deploy **Kafka**, **InfluxDB**, **Prometheus**, **collector**, **processor**, **query-api**, and **Grafana** on local minikube:

```bash
# Prerequisites: minikube, kubectl, docker
chmod +x scripts/minikube-up.sh scripts/minikube-down.sh
./scripts/minikube-up.sh
```

The script will:

1. Start minikube (4 CPU / 6 GiB RAM) if it is not already running
2. Build three app images inside the minikube Docker daemon
3. Apply manifests under `deploy/k8s/`
4. Wait until all pods are ready

### Access URLs (NodePort)

After deploy, the script prints URLs using `minikube ip`:

| Service | URL | Notes |
|---------|-----|--------|
| Grafana | `http://<minikube-ip>:30300` | admin / admin |
| Prometheus | `http://<minikube-ip>:30090` | scrape UI, alert rules |
| Collector | `http://<minikube-ip>:30080` | `POST /v1/ingest`, `/metrics` |
| Query API | `http://<minikube-ip>:30082` | stub read API |

On Mac with minikube **docker** driver, NodePort URLs may time out. Use port-forward instead:

```bash
kubectl port-forward svc/grafana 3000:3000 -n vsan-observability      # http://localhost:3000
kubectl port-forward svc/prometheus 9090:9090 -n vsan-observability  # http://localhost:9090
kubectl port-forward svc/vsan-collector 8080:8080 -n vsan-observability
```

Grafana dashboards (folder **vSAN Observability**):

| Dashboard | Datasource | Content |
|-----------|------------|---------|
| **vSAN API Observability** | InfluxDB | API `latency_ms`, `status_code` (measurement `vsan_api`) |
| **vSAN Service Metrics** | Prometheus | ingest/publish/drop rates, channel util, write latency |

On a fresh deploy the Influx panels show *No data* until you ingest events. Prometheus panels populate once scrape targets are UP (check **Status → Targets** in Prometheus UI).

### Send test data

Single-event smoke test:

```bash
kubectl port-forward svc/vsan-collector 8080:8080 -n vsan-observability
curl -X POST "http://localhost:8080/v1/ingest" \
  -H "Content-Type: application/json" \
  -d '{"source":"demo","tenant":"t1","api_name":"GET /v1/clusters","latency_ms":42.5,"status_code":200}'
```

### Load testing (k6)

```bash
brew install k6 jq
minikube addons enable metrics-server

chmod +x scripts/run-loadtest.sh
./scripts/run-loadtest.sh --profile ramp    # saturation knee (~5m)
./scripts/run-loadtest.sh --profile spike   # 50→2000→10 RPS pulse (~90s)
./scripts/run-loadtest.sh --profile soak    # 250 RPS × 30m (memory/GC)
SOAK_DURATION=1h ./scripts/run-loadtest.sh --profile soak
```

See [docs/load-testing.md](docs/load-testing.md) for spike/soak SRE checklists and metrics.

### Tear down

```bash
./scripts/minikube-down.sh
```

### Script options

```bash
./scripts/minikube-up.sh --skip-build           # reuse existing images
./scripts/minikube-up.sh --skip-minikube-start  # cluster already running
```

## Local development (without Kubernetes)

```bash
export KAFKA_BROKERS=localhost:9092
export KAFKA_TOPIC=vsan-api-logs
go run ./cmd/collector
```

```bash
export INFLUX_URL=http://localhost:8086
export INFLUX_TOKEN=...
export INFLUX_ORG=vsan
export INFLUX_BUCKET=vsan

go run ./cmd/processor
```

See [docs/architecture.md](docs/architecture.md) for concurrency, metrics, graceful shutdown, and **capacity baseline**. Load testing: [docs/load-testing.md](docs/load-testing.md).

### SRE: Collector HPA (step 1)

Requires **metrics-server** (`minikube addons enable metrics-server` — done in `minikube-up.sh`).

```bash
kubectl apply -f deploy/k8s/05-collector.yaml -f deploy/k8s/10-collector-hpa.yaml
kubectl get hpa -n vsan-observability -w
```

Guide: [docs/sre-step1-hpa.md](docs/sre-step1-hpa.md). Trigger scale-out with `./scripts/run-loadtest.sh --profile spike`.

### SRE: Prometheus alerting (step 2)

```bash
kubectl apply -f deploy/k8s/09-prometheus.yaml
kubectl rollout restart deployment/prometheus -n vsan-observability
kubectl port-forward svc/prometheus 9090:9090 -n vsan-observability
# → http://localhost:9090/alerts
```

Rules: drop rate > 5% (Critical), HTTP P99 > 100ms (Warning). Guide: [docs/sre-step2-alerting.md](docs/sre-step2-alerting.md).

## Kubernetes manifests

**Recommended:** Helm chart at [`deploy/helm/vsan-observability`](deploy/helm/vsan-observability/README.md)

```bash
helm upgrade --install vsan ./deploy/helm/vsan-observability \
  -n vsan-observability --create-namespace --wait \
  -f deploy/helm/vsan-observability/values.yaml \
  -f deploy/helm/vsan-observability/values-prod.yaml

# Clean reinstall (namespace + data wiped):
./scripts/minikube-down.sh && ./scripts/minikube-up.sh
# Multi-node profile:
MINIKUBE_PROFILE=vsan-ha ./scripts/minikube-down.sh && MINIKUBE_PROFILE=vsan-ha ./scripts/minikube-up.sh
```

Legacy flat YAML (reference): `deploy/k8s/`

| Component | Helm values key |
|-----------|-----------------|
| Kafka | `kafka.*` |
| InfluxDB | `influxdb.*` |
| Collector + HPA | `collector.*` |
| Processor | `processor.*` |
| Query API | `queryApi.*` |
| Prometheus | `prometheus.*` |
| Grafana | `grafana.*` |

Dev credentials live in `deploy/k8s/01-secrets.yaml` (Influx token `vsan-dev-token`, org/bucket `vsan`). Do not reuse in production.

## Metrics

- Collector: `/metrics` on HTTP (default `:8080`)
- Processor: `/metrics` on `METRICS_ADDR` (default `:8081`)
- Prometheus scrapes both every 15s; alert rules in `deploy/prometheus/rules.yaml` (loaded via `09-prometheus.yaml`)

Example PromQL (also in Grafana **vSAN Service Metrics** dashboard):

```promql
sum(rate(collector_ingest_total[5m]))
sum(rate(collector_published_total[5m]))
sum(rate(collector_drop_total[5m])) / sum(rate(collector_ingest_total[5m]))
histogram_quantile(0.95, sum(rate(collector_end_to_end_latency_seconds_bucket[5m])) by (le))
```
