package contract

import "github.com/vsan/observability/internal/domain"

// Parser turns raw bytes (JSON/NDJSON line) into LogEvent.
type Parser interface {
	Parse(raw []byte) (domain.LogEvent, error)
}
