# SRE Step 1 — Collector HPA（监控-告警-自愈闭环）

## Minikube 前置组件

```bash
minikube addons enable metrics-server
kubectl top pod -n vsan-observability   # 必须能出 CPU/MEM
kubectl apply -f deploy/k8s/05-collector.yaml -f deploy/k8s/10-collector-hpa.yaml
```

## Spike 压测形状（~90 秒）

```text
0:00–0:30   50 RPS   安全基线
0:30–1:00   2000 RPS 脉冲洪峰（CPU / 503 / HPA）
1:00–1:30   10 RPS   断崖回落（观察自愈）
```

```bash
# 只保留一条 port-forward（不要和脚本重复绑 8080）
kubectl port-forward svc/prometheus 9090:9090 -n vsan-observability &
kubectl port-forward svc/grafana 3000:3000 -n vsan-observability &

./scripts/run-loadtest.sh --profile spike --no-port-forward
# 若需脚本自动 forward collector，不要手动再 kubectl port-forward 8080
```

更强/更弱：`SPIKE_BURST_RPS=3000` 或 `1500`。

---

## 终端观察命令（开 3 个窗口）

**窗口 A — HPA + Pod（主视角）**

```bash
watch -n1 'date -u +%H:%M:%S; kubectl get hpa vsan-collector -n vsan-observability; echo; kubectl get pods -n vsan-observability -l app=vsan-collector -o wide'
```

或：

```bash
kubectl get hpa vsan-collector -n vsan-observability -w
```

**窗口 B — CPU 用量（验证 HPA 数据源）**

```bash
watch -n2 'kubectl top pod -n vsan-observability -l app=vsan-collector 2>&1'
```

**窗口 C — 事件（扩容/重启/OOM）**

```bash
kubectl get events -n vsan-observability --watch --field-selector involvedObject.kind=Pod
```

压测前确认：

```bash
kubectl describe hpa vsan-collector -n vsan-observability | tail -20
```

---

## Grafana「完美自愈曲线」（vSAN Service Metrics）

Dashboard：**vSAN Observability → vSAN Service Metrics**  
时间范围：**Last 5 minutes**，Refresh：**5s**

### 0:00–0:30 基线（50 RPS）

| 面板 | 期望形态 |
|------|----------|
| Collector ingest rate | ~50/s 平稳 |
| Collector publish rate | ≈ ingest |
| Collector drop rate | **≈ 0** |
| Channel utilization | **0.1–0.3** 低位 |
| Collector e2e latency p95 | 低且稳定 |

### 0:30–1:00 洪峰（2000 RPS）

| 面板 | 期望形态 |
|------|----------|
| Ingest rate | 尖峰（能进队的远小于 2000） |
| **Drop rate** | **垂直拉升**（503 风暴） |
| Channel utilization | **→ 1.0 顶格** |
| Publish rate | **平台化 ~200–300/s**（drain 上限，不跟 2000 齐飞） |
| e2e latency p95 | 202 路径略升；503 在 k6 侧应 ms 级 |

同时 **kubectl**：`REPLICAS` 从 1 → 2–5（若 metrics-server 正常）。

### 1:00–1:30 回落（10 RPS）

| 面板 | 期望形态 |
|------|----------|
| Drop rate | **断崖跌至 0** |
| Channel utilization | **快速回落** |
| Ingest / publish | ~10/s |
| e2e latency p95 | 回到基线 |

**1:30–2:30**（压测结束后）：HPA `REPLICAS` 在 stabilization 后 **缩回 1**。

---

## 曲线示意（面试白板）

```text
drop rate     |          ████
              |         █    █
              |________█______█___________
              0:30     1:00  1:30   time

channel util  |          ████████████
              |__________█            █___
              0:30     1:00  1:30

HPA replicas  |        1  2 3 4
              |__________█  █ █ █___1___
              0:30     1:00     1:30+60s
```

---

## 若 HPA 不扩容

1. `kubectl top` 报 `metrics.k8s.io` → metrics-server 挂了，先 `minikube addons enable metrics-server`
2. 双重 port-forward 8080 → connection refused，用 `--no-port-forward` 或只保留一条
3. `SPIKE_BURST_RPS` 过高（10k）打爆整节点 → 降到 2000
4. `kubectl describe hpa` 看 Events

## 下一步

Step 2：见 [docs/sre-step2-alerting.md](sre-step2-alerting.md) — Prometheus SLO 告警规则。
