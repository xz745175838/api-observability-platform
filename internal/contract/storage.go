package contract

import (
	"context"

	"github.com/vsan/observability/internal/domain"
)

// Storage writes metric points to a TSDB backend (InfluxDB, ClickHouse, …).
type Storage interface {
	WritePoints(ctx context.Context, points []domain.MetricPoint) (domain.WriteResult, error)
	Health(ctx context.Context) error
	Close() error
}
