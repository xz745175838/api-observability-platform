package contract

import "context"

// Collector is the ingestion façade (HTTP/gRPC adapters call into this).
type Collector interface {
	Ingest(ctx context.Context, raw []byte) error
	IngestBatch(ctx context.Context, raws [][]byte) error
}
