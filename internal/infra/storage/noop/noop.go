package noop

import (
	"context"

	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// Storage is a no-op backend for tests / dry-run.
type Storage struct{}

var _ contract.Storage = (*Storage)(nil)

func New() *Storage { return &Storage{} }

func (s *Storage) WritePoints(ctx context.Context, points []domain.MetricPoint) (domain.WriteResult, error) {
	_ = ctx
	return domain.WriteResult{Written: len(points)}, nil
}

func (s *Storage) Health(ctx context.Context) error {
	_ = ctx
	return nil
}

func (s *Storage) Close() error { return nil }
