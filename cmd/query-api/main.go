package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vsan/observability/internal/app/query"
	httpx "github.com/vsan/observability/internal/infra/http"
	runtimekit "github.com/vsan/observability/internal/infra/runtime"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	addr := getenv("HTTP_ADDR", ":8082")
	_ = query.NewMemoryRepository() // wire to handler when implementing real TSDB reads

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())

	qh := func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"series":[],"note":"wire Influx/TSDB repository implementation"}`))
	}
	httpx.MountQueryAPI(r, httpx.QueryDeps{
		Handler: qh,
		Reg:     nil,
	})

	srv := &http.Server{Addr: addr, Handler: r, ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second}
	ctx, stop := runtimekit.NotifyContext(context.Background())
	defer stop()

	go func() {
		log.Info("query-api listening", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("server error", "err", err)
		}
	}()

	<-ctx.Done()
	shCtx, cancel := context.WithTimeout(context.Background(), runtimekit.DefaultShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shCtx); err != nil {
		log.Error("http shutdown", "err", err)
	}
	log.Info("query-api stopped")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
