package metrics

import (
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Collector exposes ingestion-side metrics (drop rate, latency).
type Collector struct {
	IngestTotal           *prometheus.CounterVec // events accepted into internal queue (enqueue success)
	PublishedTotal        *prometheus.CounterVec // successfully published to Kafka
	DropTotal             *prometheus.CounterVec
	ProcessLatencySeconds prometheus.Histogram
	ChannelUtilization    *prometheus.GaugeVec
	EndToEndLatency       prometheus.Histogram // optional: set when write ACK known
}

func NewCollector(reg prometheus.Registerer) *Collector {
	factory := promauto.With(reg)
	return &Collector{
		IngestTotal: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "collector_ingest_total",
				Help: "Events accepted into the internal buffer (enqueue success).",
			},
			[]string{"source", "tenant"},
		),
		PublishedTotal: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "collector_published_total",
				Help: "Events successfully published to Kafka.",
			},
			[]string{"source", "tenant"},
		),
		DropTotal: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "collector_drop_total",
				Help: "Dropped or rejected events by reason and stage.",
			},
			[]string{"reason", "stage", "tenant"},
		),
		ProcessLatencySeconds: factory.NewHistogram(
			prometheus.HistogramOpts{
				Name:    "collector_process_latency_seconds",
				Help:    "Time to parse, validate, and enqueue a single event.",
				Buckets: prometheus.ExponentialBuckets(0.0001, 2, 18), // ~100µs .. 13s
			},
		),
		ChannelUtilization: factory.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "collector_channel_utilization",
				Help: "Current depth / capacity of internal channels (0..1).",
			},
			[]string{"channel"},
		),
		EndToEndLatency: factory.NewHistogram(
			prometheus.HistogramOpts{
				Name:    "collector_end_to_end_latency_seconds",
				Help:    "Wall time from ingest acceptance to Kafka publish ack (best effort).",
				Buckets: prometheus.ExponentialBuckets(0.001, 2, 16),
			},
		),
	}
}

func ObserveChannelDepth(g *prometheus.GaugeVec, channel string, depth, cap int) {
	if cap <= 0 {
		return
	}
	g.WithLabelValues(channel).Set(float64(depth) / float64(cap))
}

// Ratio query example (for Grafana / Prometheus alerts):
// sum(rate(collector_drop_total[5m])) / sum(rate(collector_ingest_total[5m]))

// SafeTenant returns a low-cardinality tenant label or "unknown".
func SafeTenant(t string) string {
	if t == "" {
		return "unknown"
	}
	return t
}

// Reason label constants.
const (
	ReasonChannelFull = "channel_full"
	ReasonParseError  = "parse_error"
	ReasonRateLimit   = "rate_limit"
	ReasonShutdown    = "shutdown"
)

// Stage labels.
const (
	StageIngest = "ingest"
	StageWorker = "worker"
)

// BoolLabel for optional dimensions without exploding cardinality.
func BoolLabel(v bool) string {
	return strconv.FormatBool(v)
}
