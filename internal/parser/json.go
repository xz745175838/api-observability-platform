package parser

import (
	"encoding/json"
	"time"

	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// JSON implements contract.Parser for single JSON objects.
type JSON struct{}

var _ contract.Parser = (*JSON)(nil)

func NewJSON() *JSON { return &JSON{} }

func (JSON) Parse(raw []byte) (domain.LogEvent, error) {
	var ev domain.LogEvent
	if err := json.Unmarshal(raw, &ev); err != nil {
		return domain.LogEvent{}, err
	}
	if ev.Timestamp.IsZero() {
		ev.Timestamp = time.Now().UTC()
	}
	return ev, nil
}
