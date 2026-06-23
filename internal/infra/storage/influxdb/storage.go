package influxdb

import (
	"context"
	"fmt"

	influx "github.com/influxdata/influxdb-client-go/v2"
	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
)

// Storage writes points to InfluxDB 2.x via line protocol.
type Storage struct {
	client influx.Client
	org    string
	bucket string
}

var _ contract.Storage = (*Storage)(nil)

// New creates a client; url e.g. http://localhost:8086, token from Influx UI.
func New(url, token, org, bucket string) *Storage {
	c := influx.NewClient(url, token)
	return &Storage{client: c, org: org, bucket: bucket}
}

func (s *Storage) WritePoints(ctx context.Context, points []domain.MetricPoint) (domain.WriteResult, error) {
	wapi := s.client.WriteAPIBlocking(s.org, s.bucket)
	result := domain.WriteResult{Written: 0}

	for _, p := range points {
		pt := influx.NewPoint(
			p.Measurement,
			p.Tags,
			p.Fields,
			p.Time,
		)
		if err := wapi.WritePoint(ctx, pt); err != nil {
			result.Errors = append(result.Errors, err)
			continue
		}
		result.Written++
	}
	if len(result.Errors) > 0 && result.Written == 0 {
		return result, fmt.Errorf("influx write: %w", result.Errors[0])
	}
	return result, nil
}

func (s *Storage) Health(ctx context.Context) error {
	ok, err := s.client.Ping(ctx)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("influx ping failed")
	}
	return nil
}

func (s *Storage) Close() error {
	s.client.Close()
	return nil
}
