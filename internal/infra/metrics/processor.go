package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Processor exposes consumer / writer metrics.
type Processor struct {
	WriteLatencySeconds *prometheus.HistogramVec
	BatchSize           prometheus.Histogram
	ProcessErrors       *prometheus.CounterVec
}

func NewProcessor(reg prometheus.Registerer) *Processor {
	factory := promauto.With(reg)
	return &Processor{
		WriteLatencySeconds: factory.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "storage_write_latency_seconds",
				Help:    "TSDB batch write latency.",
				Buckets: prometheus.ExponentialBuckets(0.001, 2, 16),
			},
			[]string{"backend"},
		),
		BatchSize: factory.NewHistogram(
			prometheus.HistogramOpts{
				Name:    "processor_batch_size",
				Help:    "Number of metric points per write batch.",
				Buckets: prometheus.ExponentialBuckets(1, 2, 14),
			},
		),
		ProcessErrors: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "processor_errors_total",
				Help: "Processing or write errors.",
			},
			[]string{"stage", "backend"},
		),
	}
}
