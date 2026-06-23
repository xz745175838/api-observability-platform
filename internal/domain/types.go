package domain

import "time"

// LogEvent is the canonical ingested API log / trace envelope.
type LogEvent struct {
	Timestamp  time.Time         `json:"ts"`
	Source     string            `json:"source"`
	Tenant     string            `json:"tenant"`
	APIName    string            `json:"api_name"`
	LatencyMs  float64           `json:"latency_ms"`
	StatusCode int               `json:"status_code"`
	RawMeta    map[string]string `json:"raw_meta,omitempty"`
}

// MetricPoint is a normalized time-series sample for TSDB backends.
type MetricPoint struct {
	Measurement string
	Tags        map[string]string
	Fields      map[string]interface{}
	Time        time.Time
}

// WriteResult summarizes a storage batch write.
type WriteResult struct {
	Written int
	Errors  []error
}

// Query describes a time-range read (for query-api / Grafana).
type Query struct {
	Measurement string
	Tags        map[string]string
	Start       time.Time
	End         time.Time
	Step        time.Duration
}

// QueryResult is a minimal tabular result for dashboards.
type QueryResult struct {
	Series []QuerySeries `json:"series"`
}

// QuerySeries is one named series over time.
type QuerySeries struct {
	Labels map[string]string   `json:"labels"`
	Points []QueryPoint        `json:"points"`
}

// QueryPoint is one sample.
type QueryPoint struct {
	Time  time.Time `json:"time"`
	Value float64   `json:"value"`
}
