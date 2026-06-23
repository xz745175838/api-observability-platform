package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/vsan/observability/internal/app/collector"
	"github.com/vsan/observability/internal/parser"
	httpx "github.com/vsan/observability/internal/infra/http"
	kafkainfra "github.com/vsan/observability/internal/infra/kafka"
	"github.com/vsan/observability/internal/infra/metrics"
	runtimekit "github.com/vsan/observability/internal/infra/runtime"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	addr := getenv("HTTP_ADDR", ":8080")
	brokers := strings.Split(getenv("KAFKA_BROKERS", "localhost:9092"), ",")
	topic := getenv("KAFKA_TOPIC", "vsan-api-logs")
	asyncProducer := getenv("KAFKA_ASYNC", "false") == "true"

	chCap, _ := strconv.Atoi(getenv("CHANNEL_CAP", "10000"))
	drop := collector.DropPolicy(getenv("DROP_POLICY", string(collector.DropNewest)))

	reg := prometheus.DefaultRegisterer
	collectorMetrics := metrics.NewCollector(reg)

	pub := kafkainfra.NewPublisher(kafkainfra.ProducerConfig{
		Brokers:       brokers,
		Topic:         topic,
		Async:         asyncProducer,
		BatchTimeout:  getenv("KAFKA_BATCH_TIMEOUT", "50ms"),
		BatchBytes:    1 << 20,
		BatchMessages: 100,
	})

	svc := collector.NewService(parser.NewJSON(), pub, collectorMetrics, collector.BackpressureConfig{
		ChannelCapacity: chCap,
		DropPolicy:      drop,
	})

	httpMetrics := metrics.NewHTTP(reg)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(httpMetrics.Middleware())
	httpx.MountCollector(r, httpx.CollectorDeps{Collector: svc, Registry: nil})

	srv := &http.Server{
		Addr:         addr,
		Handler:      r,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
	}

	ctx, stop := runtimekit.NotifyContext(context.Background())
	defer stop()

	shutdownTimeout := runtimekit.DefaultShutdownTimeout
	if env := os.Getenv("SHUTDOWN_TIMEOUT"); env != "" {
		if d, err := time.ParseDuration(env); err == nil {
			shutdownTimeout = d
		}
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("collector listening", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		log.Error("server error", "err", err)
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	shCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shCtx); err != nil {
		log.Error("http shutdown", "err", err)
	}

	drainCtx, drainCancel := context.WithTimeout(context.Background(), shutdownTimeout/2)
	defer drainCancel()
	svc.Shutdown(drainCtx)

	if err := pub.Close(); err != nil {
		log.Error("kafka writer close", "err", err)
	}
	log.Info("collector stopped")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
