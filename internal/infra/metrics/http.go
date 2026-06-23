package metrics

import (
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// HTTP exposes server-side request latency for Prometheus alerting.
type HTTP struct {
	RequestDuration *prometheus.HistogramVec
}

func NewHTTP(reg prometheus.Registerer) *HTTP {
	factory := promauto.With(reg)
	return &HTTP{
		RequestDuration: factory.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "http_request_duration_seconds",
				Help:    "HTTP request latency in seconds (server-side, includes handler time).",
				Buckets: []float64{.005, .01, .025, .05, .075, .1, .25, .5, 1, 2.5, 5, 10},
			},
			[]string{"method", "path", "status"},
		),
	}
}

// Middleware records http_request_duration_seconds after each request.
func (h *HTTP) Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		path := c.FullPath()
		if path == "" {
			path = "unknown"
		}
		h.RequestDuration.WithLabelValues(
			c.Request.Method,
			path,
			strconv.Itoa(c.Writer.Status()),
		).Observe(time.Since(start).Seconds())
	}
}
