# Load testing guide

Replace ad-hoc `curl` ingest with **k6** to measure throughput, backpressure, memory, and end-to-end behavior on the minikube stack (4 CPU / 6 GiB).

## Prerequisites

```bash
brew install k6 jq
./scripts/minikube-up.sh
minikube addons enable metrics-server   # required for soak memory watch
```

## Quick run

```bash
chmod +x scripts/run-loadtest.sh scripts/loadtest/*.sh

# Saturation knee (~5m)
./scripts/run-loadtest.sh --profile ramp

# Backpressure pulse test (~90s)
./scripts/run-loadtest.sh --profile spike

# sync.Pool / memory soak (30m default)
./scripts/run-loadtest.sh --profile soak

# 1-hour soak
SOAK_DURATION=1h ./scripts/run-loadtest.sh --profile soak
```

Reports → `docs/reports/load-test-<profile>-<timestamp>.md`.  
k6 threshold failures on ramp/spike **do not abort** the script — Prometheus snapshot and report are always generated.

Keep **Grafana** (vSAN Service Metrics) and **Prometheus** open during spike/soak with time range covering the run.

```bash
kubectl port-forward svc/grafana 3000:3000 -n vsan-observability
kubectl port-forward svc/prometheus 9090:9090 -n vsan-observability
kubectl port-forward svc/vsan-collector 8080:8080 -n vsan-observability
```

---

## Profiles

| Profile | Shape | Duration | Thresholds |
|---------|-------|----------|------------|
| `ramp` | VUs 50 → 1200 | ~5m | SLO (95% accept) |
| `spike` | **50 RPS × 30s → 2000 RPS × 30s → 10 RPS × 30s** | ~90s | None (HPA + backpressure demo) |
| `soak` | **250 RPS** constant | 30m (or `SOAK_DURATION=1h`) | Soft p99 on 202 latency |

Tune via env: `SPIKE_BASELINE_RPS`, `SPIKE_BURST_RPS`, `SPIKE_RECOVERY_RPS`, `SOAK_RPS`, `SOAK_DURATION`.

k6 metrics split by status:

| Metric | Use |
|--------|-----|
| `vsan_latency_503_ms` p99 | Fast-fail proof (expect ms-level) |
| `vsan_latency_202_ms` p99/p99.9 | Core path isolation / GC drift |

---

## Spike test — 90s HPA + backpressure demo

### Traffic shape

```text
0:00–0:30   50 RPS   safe baseline
0:30–1:00   2000 RPS burst (minikube-friendly; raise with SPIKE_BURST_RPS)
1:00–1:30   10 RPS   cliff recovery (self-heal window)
```

Run:

```bash
./scripts/run-loadtest.sh --profile spike --no-port-forward
# use script-managed port-forward instead: omit --no-port-forward, do NOT manual forward 8080
```

Observation guide: [docs/sre-step1-hpa.md](sre-step1-hpa.md).

### SRE observables

| # | Hypothesis | Where to look | Pass criteria |
|---|------------|---------------|---------------|
| 1 | **Fast-fail 503** | k6 `vsan_latency_503_ms` p99 | **ms 级**，非数百 ms 排队 |
| 2 | **Publish cap** | Grafana publish rate @ 0:30–1:00 | **平台 ~200–300/s**，不跟 2000 齐飞 |
| 3 | **HPA scale-out** | `kubectl get hpa -w` | 洪峰段 **1 → 2–5** |
| 4 | **Graceful recovery** | Grafana drop + channel @ 1:00+ | drop **→ 0**；util **回落**；~60s 后 HPA **→ 1** |

PromQL during burst (Grafana, 5s refresh):

```promql
sum(rate(collector_ingest_total[5s]))
sum(rate(collector_published_total[5s]))
sum(rate(collector_drop_total{reason="channel_full"}[5s]))
collector_channel_utilization
histogram_quantile(0.99, sum(rate(collector_end_to_end_latency_seconds_bucket[5s])) by (le))
```

---

## Soak test — sync.Pool “照妖镜”

### Traffic shape

**250 RPS** for **30m** (or `SOAK_DURATION=1h`) — near Kafka drain ceiling on minikube but below drop threshold.

### SRE observables

| # | Hypothesis | Where to look | Pass criteria |
|---|------------|---------------|---------------|
| 1 | **Memory leak** | `watch-collector-mem.sh` TSV + Grafana/kubectl top | **Sawtooth** 40–60Mi (GC dips); **not** staircase → OOM |
| 2 | **GC pause drift** | k6/Grafana `vsan_latency_202_ms` at T+5m, T+20m, T+50m | p99 stable (~10ms class); **not** 10ms → 200ms drift |
| 3 | **No silent drops** | `vsan_ingest_accept_rate` ~100%; `collector_drop_total` flat | 250 RPS sustained without 503 |

Memory watch (auto-started for soak, or manual):

```bash
./scripts/loadtest/watch-collector-mem.sh docs/reports/collector-mem-manual.tsv
```

sync.Pool defense (`internal/app/collector/pool.go`): buffers **> 1 MiB** are not returned to the pool — soak validates this does not cause unbounded heap growth.

---

## General metrics reference

### k6 (client)

| Metric | Meaning |
|--------|---------|
| `http_reqs` / rate | Offered load |
| `vsan_ingest_accept_rate` | 202 fraction |
| `vsan_ingest_rejected_503` | Backpressure count |
| `vsan_latency_503_ms` | 503-only latency |
| `vsan_latency_202_ms` | 202-only latency |

### Collector Prometheus

| Metric | PromQL |
|--------|--------|
| Ingest | `sum(rate(collector_ingest_total[1m]))` |
| Publish | `sum(rate(collector_published_total[1m]))` |
| Drops | `sum(rate(collector_drop_total[1m])) by (reason, stage)` |
| Channel | `collector_channel_utilization` |
| E2E (202 path) | `histogram_quantile(0.95, sum(rate(collector_end_to_end_latency_seconds_bucket[5m])) by (le))` |

### Pod resources

```bash
kubectl top pod -n vsan-observability -l 'app in (vsan-collector,kafka,vsan-processor)'
```

---

## Capacity baseline (minikube 4 CPU / 6 GiB)

Design: `channel_capacity = 10_000 ≈ 5000 rps × 2s` (`BackpressureConfig`).  
Measured on dev cluster (ramp): **~270/s drain**, knee **well below 5000 rps offered**.

| Test | What it proves |
|------|----------------|
| **ramp** | Absolute knee and drop onset |
| **spike** | Channel absorbs burst; fast 503; published RPS capped at drain |
| **soak** | No leak; no GC latency drift at safe RPS |

Fill measured numbers in `docs/reports/load-test-*.md` after each run.

---

## Files

| Path | Role |
|------|------|
| `scripts/loadtest/ingest.js` | k6 ramp / spike / soak scenarios |
| `scripts/loadtest/watch-collector-mem.sh` | Collector memory TSV sampler |
| `scripts/loadtest/snapshot-prometheus.sh` | Post-run PromQL snapshot |
| `scripts/run-loadtest.sh` | Orchestration + markdown report |
| `docs/reports/` | Generated artifacts |
