package kafka

import (
	"context"
	"encoding/json"
	"time"

	"github.com/segmentio/kafka-go"
	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// Publisher implements contract.Publisher using kafka-go Writer.
type Publisher struct {
	w *kafka.Writer
}

var _ contract.Publisher = (*Publisher)(nil)

// NewPublisher builds a Writer with production-oriented defaults.
func NewPublisher(cfg ProducerConfig) *Publisher {
	batchTimeout := 50 * time.Millisecond
	if cfg.BatchTimeout != "" {
		if d, err := time.ParseDuration(cfg.BatchTimeout); err == nil {
			batchTimeout = d
		}
	}
	batchBytes := cfg.BatchBytes
	if batchBytes <= 0 {
		batchBytes = 1 << 20
	}
	batchMsgs := cfg.BatchMessages
	if batchMsgs <= 0 {
		batchMsgs = 100
	}
	w := &kafka.Writer{
		Addr:         kafka.TCP(cfg.Brokers...),
		Topic:        cfg.Topic,
		Balancer:     &kafka.LeastBytes{},
		BatchBytes:   int64(batchBytes),
		BatchSize:    batchMsgs,
		BatchTimeout: batchTimeout,
		Async:        cfg.Async,
		RequiredAcks: kafka.RequireAll,
	}
	return &Publisher{w: w}
}

// Publish marshals events to JSON lines and writes Kafka messages.
func (p *Publisher) Publish(ctx context.Context, events []domain.LogEvent) error {
	msgs := make([]kafka.Message, 0, len(events))
	for _, e := range events {
		b, err := json.Marshal(e)
		if err != nil {
			return err
		}
		msgs = append(msgs, kafka.Message{Value: b})
	}
	return p.w.WriteMessages(ctx, msgs...)
}

// Close flushes in-flight batches; call during graceful shutdown after stopping ingress.
func (p *Publisher) Close() error {
	return p.w.Close()
}
