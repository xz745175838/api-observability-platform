package contract

import (
	"context"

	"github.com/vsan/observability/internal/domain"
)

// Repository reads aggregated data for dashboards / query-api.
type Repository interface {
	QueryRange(ctx context.Context, q domain.Query) (domain.QueryResult, error)
}
