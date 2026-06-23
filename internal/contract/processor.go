package contract

import (
	"context"

	"github.com/vsan/observability/internal/domain"
)

// Processor transforms LogEvent -> MetricPoint (cleaning / enrichment).
type Processor interface {
	Process(ctx context.Context, event domain.LogEvent) (domain.MetricPoint, error)
	ProcessBatch(ctx context.Context, events []domain.LogEvent) ([]domain.MetricPoint, error)
}
