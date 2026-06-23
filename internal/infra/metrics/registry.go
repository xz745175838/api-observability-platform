package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
)

// NewRegistry creates a dedicated registry (optional; default prom registry works too).
func NewRegistry() *prometheus.Registry {
	return prometheus.NewRegistry()
}
