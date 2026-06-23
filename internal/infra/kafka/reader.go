package kafka

import (
	"github.com/segmentio/kafka-go"
)

// NewReader creates a segmentio consumer for the processor service.
func NewReader(cfg ConsumerConfig) *kafka.Reader {
	minBytes := cfg.MinBytes
	if minBytes <= 0 {
		minBytes = 10e3
	}
	maxBytes := cfg.MaxBytes
	if maxBytes <= 0 {
		maxBytes = 10e6
	}
	return kafka.NewReader(kafka.ReaderConfig{
		Brokers:  cfg.Brokers,
		GroupID:  cfg.GroupID,
		Topic:    cfg.Topic,
		MinBytes: minBytes,
		MaxBytes: maxBytes,
	})
}
