# SRE Step 2 — Prometheus SLO 告警规则

Step 1（HPA 自愈）解决 **容量**；Step 2 用 **Prometheus Alerting Rules** 在指标越界时主动通知，形成「监控 → 告警 → 处置」闭环。

---

## 配置结构（三层挂载）

```text
deploy/k8s/09-prometheus.yaml
├── ConfigMap: prometheus-config
│   ├── prometheus.yml          ← 主配置，声明 rule_files
│   └── rules.yaml              ← 告警规则（与 deploy/prometheus/rules.yaml 保持同步）
└── Deployment: prometheus
    └── volumeMount
        ├── /etc/prometheus/prometheus.yml      (subPath: prometheus.yml)
        └── /etc/prometheus/rules/rules.yaml    (subPath: rules.yaml)
```

### 1. `prometheus.yml` — 声明规则文件路径

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s   # 每 15s 评估一次 alert 表达式

rule_files:
  - /etc/prometheus/rules/rules.yaml   # 容器内路径，对应 ConfigMap 挂载

scrape_configs:
  - job_name: vsan-collector
    static_configs:
      - targets: ["vsan-collector:8080"]
    metrics_path: /metrics
```

`evaluation_interval` 应 ≤ 告警窗口（本例 `[1m]`），否则规则反应偏慢。

### 2. `rules.yaml` — 告警规则本体

见 [`deploy/prometheus/rules.yaml`](../deploy/prometheus/rules.yaml)。

### 3. 部署 / 热加载

```bash
# 更新 ConfigMap 后滚动 Prometheus
kubectl apply -f deploy/k8s/09-prometheus.yaml
kubectl rollout restart deployment/prometheus -n vsan-observability

# 或 POST reload（需 --web.enable-lifecycle，已开启）
curl -X POST http://localhost:9090/-/reload
```

验证：

```bash
kubectl port-forward svc/prometheus 9090:9090 -n vsan-observability
open http://localhost:9090/alerts    # 规则是否 Loaded
open http://localhost:9090/rules     # 表达式与状态
```

---

## 两条 SLO 告警

### 1. 丢弃率超标

**场景**：channel 满，背压触发，数据被丢弃（503 / drop_newest）。

```yaml
- alert: CollectorDropRateHigh
  expr: |
    (
      sum(rate(collector_drop_total[1m]))
      /
      clamp_min(sum(rate(collector_ingest_total[1m])), 1)
    ) > 0.05
  for: 1m
  labels:
    severity: critical
```

| 字段 | 含义 |
|------|------|
| `[1m]` | rate 窗口：过去 1 分钟的平均丢弃/摄入速率 |
| `clamp_min(..., 1)` | 避免 ingest=0 时分母为 0 |
| `> 0.05` | 丢弃率超过 **5%** |
| `for: 1m` | 条件连续满足 1 分钟才 **Firing**（Pending → Firing） |

**本地 spike 演示**：洪峰仅 30s 时，`for: 1m` 可能只到 **Pending** 不 Firing。演示可临时改 `for: 30s`：

```bash
# 在 rules.yaml 里把 for: 1m 改为 for: 30s，reload 后再跑 spike
./scripts/run-loadtest.sh --profile spike
```

### 2. 核心延迟劣化

**场景**：HTTP 处理路径变慢（GC、CPU throttle、锁竞争），是丢数据前的早期信号。

Collector 现已暴露标准指标 `http_request_duration_seconds`（见 `internal/infra/metrics/http.go`）。

```yaml
- alert: CollectorHTTPLatencyP99High
  expr: |
    histogram_quantile(0.99,
      sum(rate(http_request_duration_seconds_bucket{job="vsan-collector"}[1m])) by (le)
    ) > 0.1
  for: 2m
  labels:
    severity: warning
```

| 字段 | 含义 |
|------|------|
| `histogram_quantile(0.99, ...)` | 全集群 collector HTTP 请求的 **P99** |
| `> 0.1` | 超过 **100ms**（Prometheus 用秒） |
| `for: 2m` | 持续 2 分钟才告警，过滤毛刺 |

> **说明**：ingest 为 **202 异步** 模型，HTTP 延迟 ≈ 读 body + 入队时间。P99 升高通常意味着 channel 竞争或 CPU 饱和，应早于 drop 率告警被关注。

---

## 金融 SRE：Critical vs Warning

| 规则 | 建议级别 | 通知渠道（生产） | 理由 |
|------|----------|------------------|------|
| **丢弃率 > 5%** | **Critical** | 电话 / 短信 / PagerDuty 值班 | **数据完整性 + 可用性 SLO 已破**。金融场景下 API 日志/审计流水丢失可能触发合规与风控缺口；背压不是「慢」，是「丢」。需立即扩容、限流或降级。 |
| **HTTP P99 > 100ms** | **Warning** | 企业微信 / Slack / 工单 | **性能劣化早期预警**，系统仍在接收数据。给 On-call **15–30 分钟**排查窗口（CPU、HPA、GC、下游 Kafka）。若同时 drop 率上升，Warning 应 **升级** 为 Critical。 |

### 分级原则（面试可讲）

1. **是否丢数据 / 是否 SLO 违约** → 决定 Critical
2. **是否仅变慢、尚有缓冲** → Warning
3. **用户可感知 vs 内部可恢复** → 对外 SLA 用 Critical，内部容量用 Warning
4. **告警风暴**：drop Critical 触发后，latency Warning 可 **inhibit**（Alertmanager 抑制），避免同一根因双通道轰炸

### 生产常见分层（进阶）

```text
Warning:  drop > 1% 持续 5m     → 企业微信
Critical: drop > 5% 持续 1m     → 电话
Critical: drop > 10% 持续 30s   → 电话 + 自动扩容 Runbook
Warning:  HTTP P99 > 100ms 2m   → 企业微信
Critical: HTTP P99 > 500ms 5m   → 电话（若业务定义同步 SLA）
```

---

## 本地验证清单

```bash
# 1. 重建 collector（含 http_request_duration_seconds）
./scripts/minikube-up.sh

# 2. 应用告警规则
kubectl apply -f deploy/k8s/09-prometheus.yaml
kubectl rollout restart deployment/prometheus -n vsan-observability

# 3. 确认指标存在
kubectl port-forward svc/vsan-collector 8080:8080 -n vsan-observability &
curl -s localhost:8080/metrics | grep http_request_duration_seconds

# 4. 跑 spike，观察 Alerts 页
./scripts/run-loadtest.sh --profile spike
# Prometheus → Alerts → CollectorDropRateHigh 应 Pending/Firing
```

Grafana：**Alerting** 或 **Explore** 执行与规则相同的 PromQL，对照 spike 时间轴。

---

## 下一步（Step 3）

- 部署 **Alertmanager**：按 `severity` 路由（critical → 电话，warning → 企业微信）
- **inhibition_rules**：drop Critical 抑制 latency Warning
- 告警关联 **Runbook** 与 HPA / 限流自动化
