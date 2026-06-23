# vsan-observability Helm Chart

Deploy the full vSAN observability stack on Kubernetes (minikube-friendly defaults).

## Prerequisites

```bash
brew install helm kubectl
minikube start --cpus=4 --memory=6144
minikube addons enable metrics-server

# Build app images into minikube docker (from repo root)
eval "$(minikube docker-env)"
for svc in collector processor query-api; do
  docker build --build-arg SERVICE=${svc} -f deploy/docker/Dockerfile -t vsan-${svc}:latest .
done
```

## Install

**Minikube (defaults):**

```bash
helm upgrade --install vsan ./deploy/helm/vsan-observability \
  -n vsan-observability \
  --create-namespace \
  --wait \
  --timeout 10m
```

**Production HA / DR** (anti-affinity, PDB, Kafka RF=3 / min ISR=2, resource quotas):

```bash
helm upgrade --install vsan ./deploy/helm/vsan-observability \
  -n vsan-observability \
  --create-namespace \
  -f values.yaml -f values-prod.yaml \
  --wait --atomic --timeout 15m
```

Requires **≥ 3 worker nodes** when `global.podAntiAffinity.type: hard` and `kafka.replicas: 3`.

## Upgrade / override values

```bash
# Stronger backpressure demo
helm upgrade vsan ./deploy/helm/vsan-observability -n vsan-observability \
  --set collector.backpressure.channelCap=5000 \
  --set collector.backpressure.dropPolicy=drop_oldest \
  --set collector.hpa.maxReplicas=8

# Custom Influx token (dev only)
helm upgrade vsan ./deploy/helm/vsan-observability -n vsan-observability \
  --set influxdb.credentials.adminToken=my-token
```

## Uninstall

```bash
helm uninstall vsan -n vsan-observability
# PVC for InfluxDB persists until manually deleted:
kubectl delete pvc -l app=influxdb -n vsan-observability
```

## Values reference

| Key | Default | Description |
|-----|---------|-------------|
| `global.podAntiAffinity.*` | disabled / soft | Spread pods across nodes (`hard` = required) |
| `kafka.replicas` | `1` | Broker count (prod overlay: `3`) |
| `kafka.minInsyncReplicas` | `1` | Broker `min.insync.replicas` (prod: `2`) |
| `kafka.topic.replicationFactor` | `1` | Topic RF (prod: `3`) |
| `kafka.topic.minInsyncReplicas` | `1` | Topic `--config min.insync.replicas` (prod: `2`) |
| `collector.pdb.*` | disabled | PodDisruptionBudget for ingest (prod: `minAvailable: 2`) |
| `*.resources` | requests + limits | All Deployments/StatefulSet pods quota-enforced |
| `collector.backpressure.*` | channelCap, dropPolicy | Ingest backpressure |
| `collector.hpa.*` | min 1 max 5 @ 50% CPU | HorizontalPodAutoscaler |

See [`values-prod.yaml`](values-prod.yaml) for the full production overlay with inline Kafka topology comments.

## Legacy manifests

Flat YAML under `deploy/k8s/` is kept for reference; **Helm is the recommended deploy path** (used by `scripts/minikube-up.sh`).
