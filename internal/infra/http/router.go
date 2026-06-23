package http

import (
	"errors"
	"io"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/vsan/observability/internal/app/collector"
	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/infra/runtime"
)

// CollectorDeps wires gin routes for the ingestion service.
type CollectorDeps struct {
	Collector *collector.Service
	Registry  *prometheus.Registry
}

// MountCollector registers /healthz, /metrics, /v1/ingest.
func MountCollector(r *gin.Engine, d CollectorDeps) {
	r.GET("/healthz", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/metrics", gin.WrapH(runtime.MetricsHandler(d.Registry)))

	r.POST("/v1/ingest", func(c *gin.Context) {
		raw, err := io.ReadAll(c.Request.Body)
		if err != nil {
			c.Status(http.StatusBadRequest)
			return
		}
		if err := d.Collector.Ingest(c.Request.Context(), raw); err != nil {
			if errors.Is(err, domain.ErrQueueSaturated) {
				c.Status(http.StatusServiceUnavailable)
				return
			}
			slog.Warn("ingest error", "err", err)
			c.Status(http.StatusBadRequest)
			return
		}
		c.Status(http.StatusAccepted)
	})
}

// QueryDeps for query-api service.
type QueryDeps struct {
	Handler http.HandlerFunc
	Reg     *prometheus.Registry
}

func MountQueryAPI(r *gin.Engine, d QueryDeps) {
	r.GET("/healthz", func(c *gin.Context) { c.Status(http.StatusOK) })
	if d.Reg != nil {
		r.GET("/metrics", gin.WrapH(runtime.MetricsHandler(d.Reg)))
	}
	if d.Handler != nil {
		r.GET("/v1/query", gin.WrapH(d.Handler))
	}
}
