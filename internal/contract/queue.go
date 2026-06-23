package contract

import (
	"context"

	"github.com/vsan/observability/internal/domain"
)

// EventHandler is invoked for each consumed event (processor side).
type EventHandler func(ctx context.Context, event domain.LogEvent) error

// Publisher publishes structured events to the bus (Kafka, etc.).
type Publisher interface {
	Publish(ctx context.Context, events []domain.LogEvent) error
	Close() error
}

// Subscriber consumes events (optional abstraction; processor may use kafka.Reader directly with this shape in tests).
type Subscriber interface {
	Subscribe(ctx context.Context, handler EventHandler) error
	Close() error
}
