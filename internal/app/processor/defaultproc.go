package processor

import (
	"context"

	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// Default maps LogEvent to a normalized MetricPoint for api_latency measurement.
type Default struct{}

var _ contract.Processor = (*Default)(nil)

func NewDefault() *Default { return &Default{} }

func (Default) Process(ctx context.Context, event domain.LogEvent) (domain.MetricPoint, error) {
	_ = ctx
	tags := map[string]string{
		"source": event.Source,
		"tenant": event.Tenant,
		"api":    event.APIName,
	}
	fields := map[string]interface{}{
		"latency_ms":  event.LatencyMs,
		"status_code": event.StatusCode,
	}
	return domain.MetricPoint{
		Measurement: "vsan_api",
		Tags:        tags,
		Fields:      fields,
		Time:        event.Timestamp,
	}, nil
}

func (d Default) ProcessBatch(ctx context.Context, events []domain.LogEvent) ([]domain.MetricPoint, error) {
	out := make([]domain.MetricPoint, 0, len(events))
	for _, e := range events {
		p, err := d.Process(ctx, e)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}
