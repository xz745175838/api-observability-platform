# Architecture

## Services

| Service | Role | Stack |
|---------|------|--------|
| `cmd/collector` | Ingest raw API log JSON, backpressure, publish to Kafka | gin, kafka-go Writer |
| `cmd/processor` | Consume Kafka, transform to `MetricPoint`, batch write TSDB | kafka-go Reader, Influx (or noop) |
| `cmd/query-api` | Query façade for Grafana (stub repository) | gin |

## Core contracts

Defined under `internal/contract/`. Application code depends on interfaces only; implementations live in `internal/infra/`.

- **Collector** (`Ingest`, `IngestBatch`) — implemented by `internal/app/collector`.
- **Publisher** (`Publish`, `Close`) — `internal/infra/kafka.Publisher`.
- **Processor** — `internal/app/processor.Default`.
- **Storage** (`WritePoints`, `Health`, `Close`) — InfluxDB or `noop`.
- **Repository** — `internal/app/query` stub for reads.

## High concurrency (5k+ events/s)

### sync.Pool

- `internal/app/collector/pool.go` pools `*bytes.Buffer` for body copy and (via `copyPayload`) reduces steady-state allocations.
- Buffers larger than **1 MiB** are not returned to the pool to avoid retaining huge capacities.

### Internal channel & drop policy

- Config: `BackpressureConfig` in `internal/app/collector/config.go`.
- Default capacity **10000** ≈ `5000 rps × 2s` absorb window.
- **drop_newest** (default): non-blocking send; on overflow return `503` and increment `collector_drop_total{reason="channel_full"}`.
- **drop_oldest**: try to discard one queued item then enqueue the new event (configurable via `DROP_POLICY`).

### Prometheus

- Collector metrics: `internal/infra/metrics/collector.go` (`collector_ingest_total`, `collector_published_total`, `collector_drop_total`, histograms, channel utilization).
- Processor metrics: `internal/infra/metrics/processor.go` (`storage_write_latency_seconds`, `processor_batch_size`, errors).
- Drop ratio (PromQL): `sum(rate(collector_drop_total[5m])) / sum(rate(collector_ingest_total[5m]))`.

## Graceful shutdown (gin + kafka-go)

Recommended order (implemented in `cmd/collector/main.go`):

1. **SIGTERM/SIGINT** → cancel root context.
2. **`http.Server.Shutdown`** with timeout — stop accepting new HTTP requests; drain in-flight handlers.
3. **`collector.Service.Shutdown`** — wait for internal buffer to drain (bounded by context), then **close** the worker channel and `Wait()` workers.
4. **`kafka.Writer.Close`** — flush producer batch buffers to brokers.

Processor (`cmd/processor/main.go`):

1. Cancel context → `Runner.Run` returns after optional final flush.
2. Shutdown metrics HTTP server.
3. **`Storage.Close`** then **`kafka.Reader.Close`** (stops fetches; commits follow at-least-once batching rules in `processor.Runner`).

Shared helpers: `internal/infra/runtime/shutdown.go`.

## Configuration

See `configs/config.example.yaml` and environment variables in `README.md`.

## Kubernetes (minikube)

One-command deploy: `./scripts/minikube-up.sh`. Manifests live under `deploy/k8s/`.

```
collector ──► Kafka ──► processor ──► InfluxDB ◄── Grafana (API dashboards)
    │                                      ▲
    └── /metrics ◄── Prometheus ──────────┘ (service metrics dashboards)
                              │
                         query-api (stub)
```

| Component | K8s kind | Notes |
|-----------|----------|-------|
| Kafka | Deployment | KRaft single broker, Service `kafka:9092` |
| InfluxDB | StatefulSet | 5Gi PVC via `volumeClaimTemplates`; one ClusterIP Service `influxdb:8086` serves both StatefulSet `serviceName` and client access (processor, Grafana). No headless Service — single-replica dev does not need per-pod DNS. |
| Prometheus | Deployment | Scrapes `vsan-collector:8080/metrics` and `vsan-processor:8081/metrics`; loads alert rules from `deploy/prometheus/rules.yaml` |
| collector / processor / query-api | Deployment | Built from `deploy/docker/Dockerfile`; collector has HPA (`10-collector-hpa.yaml`, CPU 50%, 1–5 replicas) |
| Grafana | Deployment | InfluxDB datasource + **vSAN API Observability**; Prometheus datasource + **vSAN Service Metrics** |

InfluxDB first-boot init uses official image env vars (`DOCKER_INFLUXDB_INIT_*`) in `03-influxdb.yaml`; credentials are in `01-secrets.yaml`. Data persists across pod restarts via PVC; deleting the namespace removes the PVC.

## Capacity baseline & load testing

Full procedure: [docs/load-testing.md](load-testing.md). One-command run: `./scripts/run-loadtest.sh`.

### BackpressureConfig rationale

Default `channel_capacity = 10_000` targets `peak_rps × absorb_window` (5000 rps × 2s). The channel is **not** extra throughput — it absorbs short bursts while workers publish to Kafka. Saturation appears as `collector_channel_utilization → 1` and HTTP **503** (`drop_newest`).

### Minikube (4 CPU / 6 GiB) — how to establish limits

Run k6 `ramp` then `spike` profiles; reports are written to `docs/reports/`. Use this table to record **your** measured numbers:

| Metric | How to measure | Role |
|--------|----------------|------|
| Sustained throughput | k6 `http_reqs` rate while accept rate > 99% | Cluster service ceiling |
| Knee / drop onset | First load step where 503 > 0 or drop ratio > 1% | Practical max |
| Drain rate | `sum(rate(collector_published_total[1m]))` at saturation | Worker + Kafka capacity |
| Channel fill time | `10000 / (ingest_rate - publish_rate)` during spike | Validates 2s window assumption |

### Bottleneck identification (collector serialization vs Kafka I/O)

| Observation | Likely bottleneck |
|-------------|-------------------|
| High channel util, ingest ≫ publish, 503s | Backpressure engaged; root cause is **slow drain** |
| Moderate util, publish rate flat, **collector CPU** high (`kubectl top`) | **Collector workers** — JSON parse + sync `kafka.Writer.WriteMessages` |
| Low util, ingest ≈ publish, **Kafka pod** CPU/IO high | **Kafka broker** I/O (single KRaft broker on shared node) |
| Collector healthy, `processor_errors_total` or Influx lag | **Processor / Influx** downstream |

On typical minikube dev clusters, the knee is often **below 5000 rps** because the node runs Kafka, Influx, Grafana, and Prometheus alongside one collector replica. Whether the dominant limit is collector CPU or Kafka depends on which pod peaks in `kubectl top` while `collector_channel_utilization` and ingest/publish gap tell you if the channel is masking drain limits.

### Channel 10_000 verdict (fill after load test)

- **Justified** if bursts cause util > 0.8 briefly before 503 and fill time matches `capacity / (ingress - drain)`.
- **Do not raise capacity first** if drain is low — fix worker count, Kafka resources, or replicas before enlarging the buffer.

### Profile matrix

| Profile | Shape | Proves |
|---------|-------|--------|
| `ramp` | VUs → 1200 | Saturation knee |
| `spike` | 50 → 2000 → 10 RPS (90s) | Drop spike, publish cap, HPA scale, recovery |
| `soak` | 250 RPS × 30m+ | sync.Pool sawtooth memory, no GC latency drift |
