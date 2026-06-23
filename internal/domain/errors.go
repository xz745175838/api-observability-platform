package domain

import "errors"

var (
	// ErrRetryable indicates the operation may succeed on retry (Kafka/Influx transient).
	ErrRetryable = errors.New("retryable")
	// ErrNonRetryable indicates bad input or policy; do not retry blindly.
	ErrNonRetryable = errors.New("non_retryable")
	// ErrQueueSaturated indicates internal backpressure / channel full.
	ErrQueueSaturated = errors.New("queue_saturated")
	// ErrDropped indicates data was explicitly dropped by policy.
	ErrDropped = errors.New("dropped")
)
