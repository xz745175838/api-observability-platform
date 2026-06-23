package processor

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/segmentio/kafka-go"
	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
	"github.com/vsan/observability/internal/infra/metrics"
)

// Runner consumes Kafka messages, transforms, and batch-writes to storage.
type Runner struct {
	Reader   *kafka.Reader
	Proc     contract.Processor
	Storage  contract.Storage
	Metrics  *metrics.Processor
	BatchMax int
	FlushInt time.Duration
	Backend  string
}

type fetchOutcome struct {
	msg kafka.Message
	err error
}

// Run blocks until ctx cancelled or fatal reader error.
func (r *Runner) Run(ctx context.Context) error {
	if r.BatchMax <= 0 {
		r.BatchMax = 500
	}
	if r.FlushInt <= 0 {
		r.FlushInt = 200 * time.Millisecond
	}
	ticker := time.NewTicker(r.FlushInt)
	defer ticker.Stop()

	type batchItem struct {
		msg kafka.Message
		pt  domain.MetricPoint
	}
	var buf []batchItem

	flush := func() error {
		if len(buf) == 0 {
			return nil
		}
		points := make([]domain.MetricPoint, len(buf))
		msgs := make([]kafka.Message, len(buf))
		for i := range buf {
			points[i] = buf[i].pt
			msgs[i] = buf[i].msg
		}
		start := time.Now()
		_, err := r.Storage.WritePoints(ctx, points)
		r.Metrics.BatchSize.Observe(float64(len(points)))
		r.Metrics.WriteLatencySeconds.WithLabelValues(r.Backend).Observe(time.Since(start).Seconds())
		if err != nil {
			r.Metrics.ProcessErrors.WithLabelValues("write", r.Backend).Inc()
			return err
		}
		if err := r.Reader.CommitMessages(ctx, msgs...); err != nil {
			r.Metrics.ProcessErrors.WithLabelValues("commit", r.Backend).Inc()
			return err
		}
		buf = buf[:0]
		return nil
	}

	outcomes := make(chan fetchOutcome, 8)
	go func() {
		for {
			if ctx.Err() != nil {
				return
			}
			m, err := r.Reader.FetchMessage(ctx)
			select {
			case outcomes <- fetchOutcome{msg: m, err: err}:
			case <-ctx.Done():
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			if err := flush(); err != nil {
				slog.Warn("final flush", "err", err)
			}
			return ctx.Err()
		case <-ticker.C:
			if err := flush(); err != nil {
				slog.Error("flush batch", "err", err)
			}
		case fo := <-outcomes:
			if fo.err != nil {
				if ctx.Err() != nil {
					_ = flush()
					return ctx.Err()
				}
				slog.Warn("kafka fetch", "err", fo.err)
				time.Sleep(500 * time.Millisecond)
				continue
			}
			m := fo.msg
			var ev domain.LogEvent
			if err := json.Unmarshal(m.Value, &ev); err != nil {
				r.Metrics.ProcessErrors.WithLabelValues("unmarshal", r.Backend).Inc()
				if err := r.Reader.CommitMessages(ctx, m); err != nil {
					return err
				}
				continue
			}
			pt, err := r.Proc.Process(ctx, ev)
			if err != nil {
				r.Metrics.ProcessErrors.WithLabelValues("process", r.Backend).Inc()
				continue
			}
			buf = append(buf, batchItem{msg: m, pt: pt})
			if len(buf) >= r.BatchMax {
				if err := flush(); err != nil {
					slog.Error("flush batch", "err", err)
				}
			}
		}
	}
}
