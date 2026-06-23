package kafka

// ProducerConfig tunes kafka-go Writer for throughput vs latency.
type ProducerConfig struct {
	Brokers       []string
	Topic         string
	BatchBytes    int
	BatchMessages int
	BatchTimeout  string // e.g. "50ms"
	Async         bool   // false = sync Writes wait for ack (simpler backpressure)
}

// ConsumerConfig tunes kafka-go Reader.
type ConsumerConfig struct {
	Brokers  []string
	Topic    string
	GroupID  string
	MinBytes int
	MaxBytes int
}
