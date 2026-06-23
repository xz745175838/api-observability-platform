package query

import (
	"context"

	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// MemoryRepository is a stub; wire Influx / Prometheus remote read in production.
type MemoryRepository struct{}

var _ contract.Repository = (*MemoryRepository)(nil)

func NewMemoryRepository() *MemoryRepository {
	return &MemoryRepository{}
}

func (MemoryRepository) QueryRange(ctx context.Context, q domain.Query) (domain.QueryResult, error) {
	_ = ctx
	_ = q
	return domain.QueryResult{Series: nil}, nil
}
