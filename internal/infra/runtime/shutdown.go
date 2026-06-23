package runtime

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/sync/errgroup"
)

// DefaultShutdownTimeout is the max time to drain HTTP + close I/O after SIGTERM.
const DefaultShutdownTimeout = 45 * time.Second

// NotifyContext returns a context cancelled on SIGINT/SIGTERM.
func NotifyContext(parent context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, syscall.SIGINT, syscall.SIGTERM)
}

// HTTPServer starts an HTTP server and shuts it down when ctx is done.
func HTTPServer(ctx context.Context, srv *http.Server, shutdownTimeout time.Duration) error {
	g, ctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	})

	g.Go(func() error {
		<-ctx.Done()
		slog.Info("http: shutdown started", "timeout", shutdownTimeout)
		shCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return srv.Shutdown(shCtx)
	})

	return g.Wait()
}

// MetricsHandler serves Prometheus metrics; pass nil for default registry.
func MetricsHandler(reg *prometheus.Registry) http.Handler {
	if reg == nil {
		return promhttp.Handler()
	}
	return promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg})
}

// WaitGroupClose runs closers in LIFO order after shutdown (Kafka, storage, …).
type WaitGroupClose struct {
	mu     sync.Mutex
	closes []func() error
}

func (w *WaitGroupClose) Add(fn func() error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closes = append(w.closes, fn)
}

func (w *WaitGroupClose) CloseAll() {
	w.mu.Lock()
	defer w.mu.Unlock()
	for i := len(w.closes) - 1; i >= 0; i-- {
		if err := w.closes[i](); err != nil {
			slog.Warn("close error", "err", err)
		}
	}
}

// SleepInterruptible sleeps or returns early if ctx cancelled.
func SleepInterruptible(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// MustHostname returns OS hostname or "unknown".
func MustHostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "unknown"
	}
	return h
}
