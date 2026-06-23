package collector

import "time"

// DropPolicy selects behavior when the internal buffer is full.
type DropPolicy string

const (
	// DropNewest rejects the incoming item (HTTP may return 503/429).
	DropNewest DropPolicy = "drop_newest"
	// DropOldest frees one slot by discarding the oldest queued item (keeps fresher data).
	DropOldest DropPolicy = "drop_oldest"
)

// BackpressureConfig controls internal buffering (see plan: cap ≈ peak_rps * absorb_window).
type BackpressureConfig struct {
	ChannelCapacity int
	WorkerCount     int
	DropPolicy      DropPolicy
	// ChannelHighWatermark triggers more aggressive sampling / metrics (0..1), e.g. 0.8
	HighWatermark float64
}

// DefaultBackpressure tuned for ~5k rps baseline with ~2s absorb window.
func DefaultBackpressure() BackpressureConfig {
	return BackpressureConfig{
		ChannelCapacity: 10_000,
		WorkerCount:     0, // 0 => NumCPU*2 set at runtime
		DropPolicy:      DropNewest,
		HighWatermark:   0.8,
	}
}

func (c BackpressureConfig) effectiveWorkers() int {
	if c.WorkerCount > 0 {
		return c.WorkerCount
	}
	return 0
}

// HTTPConfig for gin server.
type HTTPConfig struct {
	Addr         string
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
}
