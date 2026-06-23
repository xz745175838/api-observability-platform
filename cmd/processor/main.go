package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vsan/observability/internal/app/processor"
	"github.com/vsan/observability/internal/contract"
	kafkainfra "github.com/vsan/observability/internal/infra/kafka"
	"github.com/vsan/observability/internal/infra/metrics"
	influxstore "github.com/vsan/observability/internal/infra/storage/influxdb"
	"github.com/vsan/observability/internal/infra/storage/noop"
	runtimekit "github.com/vsan/observability/internal/infra/runtime"
	"github.com/prometheus/client_golang/prometheus"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	brokers := strings.Split(getenv("KAFKA_BROKERS", "localhost:9092"), ",")
	topic := getenv("KAFKA_TOPIC", "vsan-api-logs")
	group := getenv("KAFKA_GROUP", "vsan-processor")
	metricsAddr := getenv("METRICS_ADDR", ":8081")

	reg := prometheus.DefaultRegisterer
	pm := metrics.NewProcessor(reg)

	backend := "noop"
	var st contract.Storage = noop.New()
	if influxURL := os.Getenv("INFLUX_URL"); influxURL != "" {
		st = influxstore.New(influxURL, getenv("INFLUX_TOKEN", ""), getenv("INFLUX_ORG", ""), getenv("INFLUX_BUCKET", "vsan"))
		backend = "influxdb"
	}

	rdr := kafkainfra.NewReader(kafkainfra.ConsumerConfig{
		Brokers: brokers,
		Topic:   topic,
		GroupID: group,
	})

	run := &processor.Runner{
		Reader:   rdr,
		Proc:     processor.NewDefault(),
		Storage:  st,
		Metrics:  pm,
		BatchMax: 500,
		FlushInt: 200 * time.Millisecond,
		Backend:  backend,
	}

	ctx, stop := runtimekit.NotifyContext(context.Background())
	defer stop()

	gin.SetMode(gin.ReleaseMode)
	mr := gin.New()
	mr.Use(gin.Recovery())
	mr.GET("/healthz", func(c *gin.Context) { c.Status(http.StatusOK) })
	mr.GET("/metrics", gin.WrapH(runtimekit.MetricsHandler(nil)))

	srv := &http.Server{Addr: metricsAddr, Handler: mr}
	go func() {
		log.Info("processor metrics", "addr", metricsAddr)
		_ = srv.ListenAndServe()
	}()

	go func() {
		<-ctx.Done()
		shCtx, cancel := context.WithTimeout(context.Background(), runtimekit.DefaultShutdownTimeout)
		defer cancel()
		_ = srv.Shutdown(shCtx)
	}()

	log.Info("processor consuming", "topic", topic, "group", group, "backend", backend)
	if err := run.Run(ctx); err != nil && err != context.Canceled {
		log.Error("processor stopped", "err", err)
	}

	_ = st.Close()
	_ = rdr.Close()
	log.Info("processor exited")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
