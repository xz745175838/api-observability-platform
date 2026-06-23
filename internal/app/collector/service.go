package collector

import (
	"context"
	"io"
	"log/slog"
	"runtime"
	"sync"
	"time"

	"github.com/vsan/observability/internal/domain"
	"github.com/vsan/observability/internal/contract"
	"github.com/vsan/observability/internal/infra/metrics"
)

type ingestJob struct {
	payload   []byte
	acceptAt  time.Time
	sourceTag string
}

// Service implements contract.Collector with internal channel, worker pool, and buffer pooling.
type Service struct {
	parser    contract.Parser
	publisher contract.Publisher
	m         *metrics.Collector
	cfg       BackpressureConfig
	bp        *bufferPool

	ch chan ingestJob

	dropPolicy DropPolicy

	wg sync.WaitGroup
}

var _ contract.Collector = (*Service)(nil)

func NewService(p contract.Parser, pub contract.Publisher, m *metrics.Collector, cfg BackpressureConfig) *Service {
	if cfg.ChannelCapacity <= 0 {
		cfg = DefaultBackpressure()
	}
	workers := cfg.effectiveWorkers()
	if workers <= 0 {
		workers = runtime.NumCPU() * 2
	}
	cfg.WorkerCount = workers
	if cfg.HighWatermark <= 0 {
		cfg.HighWatermark = 0.8
	}
	if cfg.DropPolicy == "" {
		cfg.DropPolicy = DropNewest
	}
	s := &Service{
		parser:     p,
		publisher:  pub,
		m:          m,
		cfg:        cfg,
		bp:         newBufferPool(),
		ch:         make(chan ingestJob, cfg.ChannelCapacity),
		dropPolicy: cfg.DropPolicy,
	}
	for i := 0; i < workers; i++ {
		s.wg.Add(1)
		go s.workerLoop()
	}
	return s
}

// Ingest accepts one raw payload (copy uses buffer pool to reduce allocator pressure).
func (s *Service) Ingest(ctx context.Context, raw []byte) error {
	return s.ingestWithSource(ctx, raw, "http")
}

func (s *Service) ingestWithSource(ctx context.Context, raw []byte, source string) error {
	start := time.Now()
	_ = ctx
	if len(raw) == 0 {
		s.m.DropTotal.WithLabelValues("empty", metrics.StageIngest, metrics.SafeTenant("")).Inc()
		return domain.ErrNonRetryable
	}

	j := ingestJob{
		payload:   s.copyPayload(raw),
		acceptAt:  start,
		sourceTag: source,
	}

	if err := s.enqueue(j); err != nil {
		s.observeDepth()
		return err
	}
	s.m.IngestTotal.WithLabelValues(source, "unknown").Inc()
	s.observeDepth()
	s.m.ProcessLatencySeconds.Observe(time.Since(start).Seconds())
	return nil
}

func (s *Service) copyPayload(raw []byte) []byte {
	buf := s.bp.Get()
	buf.Reset()
	buf.Write(raw)
	out := make([]byte, buf.Len())
	copy(out, buf.Bytes())
	s.bp.Put(buf)
	return out
}

func (s *Service) enqueue(j ingestJob) error {
	switch s.dropPolicy {
	case DropOldest:
		// 1) 快路径：队列未满，直接入队
		select {
		case s.ch <- j:
			return nil
		default:
			// 2) 队列已满：尝试先丢掉一个“最旧任务”（channel FIFO，读出来的是最早入队的）
			select {
			case old := <-s.ch:
				s.m.DropTotal.WithLabelValues(metrics.ReasonChannelFull, metrics.StageIngest, metrics.SafeTenant("")).Inc()
				_ = old // 显式丢弃旧任务；这里只做背压控制，不做补偿处理
			default:
			}
			// 3) 再次尝试写入当前新任务
			select {
			case s.ch <- j:
				return nil
			default:
				// 仍失败：并发竞争下可能再次被占满，返回队列饱和错误
				s.m.DropTotal.WithLabelValues(metrics.ReasonChannelFull, metrics.StageIngest, "").Inc()
				return domain.ErrQueueSaturated
			}
		// 面试加分点：为什么会有两个 select？
		// 因为在高并发下，即便你刚弹出一个，可能瞬间又被别的并发任务填满了。
		// 这种双重 check 体现了代码的健壮性。
		}
	default: // DropNewest
	    // DropNewest 策略是当 channel 满时，丢弃最新的数据，并返回 ErrQueueSaturated 错误。
		select {
		case s.ch <- j:
			return nil
		default:
			s.m.DropTotal.WithLabelValues(metrics.ReasonChannelFull, metrics.StageIngest, "").Inc()
			return domain.ErrQueueSaturated
		}
	}
}

func (s *Service) observeDepth() {
	d := len(s.ch)
	capv := cap(s.ch)
	metrics.ObserveChannelDepth(s.m.ChannelUtilization, "ingest", d, capv)
	if capv > 0 && float64(d)/float64(capv) >= s.cfg.HighWatermark {
		slog.Debug("collector channel high watermark", "depth", d, "cap", capv)
	}
}

// IngestBatch enqueues multiple raw events.
func (s *Service) IngestBatch(ctx context.Context, raws [][]byte) error {
	for _, r := range raws {
		if err := s.Ingest(ctx, r); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) workerLoop() {
	defer s.wg.Done()
	for job := range s.ch {
		s.handleJob(job)
	}
}

func (s *Service) handleJob(job ingestJob) {
	start := time.Now()
	ev, err := s.parser.Parse(job.payload)
	if err != nil {
		s.m.DropTotal.WithLabelValues(metrics.ReasonParseError, metrics.StageWorker, metrics.SafeTenant("")).Inc()
		return
	}
	tenant := metrics.SafeTenant(ev.Tenant)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := s.publisher.Publish(ctx, []domain.LogEvent{ev}); err != nil {
		s.m.DropTotal.WithLabelValues("publish_error", metrics.StageWorker, tenant).Inc()
		slog.Warn("kafka publish failed", "err", err)
		return
	}
	s.m.PublishedTotal.WithLabelValues(job.sourceTag, tenant).Inc()
	s.m.EndToEndLatency.Observe(time.Since(job.acceptAt).Seconds())
	s.m.ProcessLatencySeconds.Observe(time.Since(start).Seconds())
}

// Shutdown drains or times out, then closes the channel and waits for workers.
func (s *Service) Shutdown(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			close(s.ch)
			s.wg.Wait()
			return
		case <-ticker.C:
			if len(s.ch) == 0 {
				close(s.ch)
				s.wg.Wait()
				return
			}
		}
	}
}

// ReadBodyIntoPool reads r into a copied byte slice using the service buffer pool pattern.
func ReadBodyIntoPool(bp *bufferPool, r io.Reader) ([]byte, error) {
	buf := bp.Get()
	defer bp.Put(buf)
	if _, err := buf.ReadFrom(r); err != nil {
		return nil, err
	}
	out := make([]byte, buf.Len())
	copy(out, buf.Bytes())
	return out, nil
}
