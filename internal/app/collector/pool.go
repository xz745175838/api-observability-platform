package collector

import (
	"bytes"
	"sync"
)

const maxPooledBufferCap = 1 << 20 // 1 MiB: do not return larger buffers to pool

// bufferPool wraps sync.Pool for JSON bodies and serialization scratch space.
type bufferPool struct {
	p sync.Pool
}

func newBufferPool() *bufferPool {
	return &bufferPool{p: sync.Pool{
		New: func() any { return new(bytes.Buffer) },
	}}
}

func (bp *bufferPool) Get() *bytes.Buffer {
	return bp.p.Get().(*bytes.Buffer)
}

func (bp *bufferPool) Put(b *bytes.Buffer) {
	if b == nil {
		return
	}
	b.Reset()
	// 在使用 sync.Pool 管理 bytes.Buffer 时，我使用了 Reset() 来实现内存的逻辑复用。
	// 虽然 Reset() 不会物理抹除旧数据，但它能以极低的代价重置写指针。
	// 配合上 1MiB 的熔断机制，既保证了高性能的覆盖写入，又避免了长尾大对象对内存的持续霸占。
	if b.Cap() > maxPooledBufferCap {
		return
	}
	bp.p.Put(b)
}
