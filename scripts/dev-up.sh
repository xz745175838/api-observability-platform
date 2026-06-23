#!/usr/bin/env bash
set -euo pipefail
export KAFKA_BROKERS="${KAFKA_BROKERS:-localhost:9092}"
export KAFKA_TOPIC="${KAFKA_TOPIC:-vsan-api-logs}"

echo "Start collector on :8080 and processor on :8081 (metrics) in separate terminals:"
echo "  go run ./cmd/collector"
echo "  go run ./cmd/processor"
