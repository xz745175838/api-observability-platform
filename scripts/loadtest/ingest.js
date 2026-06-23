/**
 * k6 load test for POST /v1/ingest
 *
 * Profiles:
 *   ramp  — step VUs to find saturation knee
 *   spike — 50 RPS × 30s → 2000 RPS × 30s → 10 RPS × 30s (HPA + backpressure demo, ~90s)
 *   soak  — 250 RPS × 30m+ (sync.Pool / memory / GC drift)
 *
 * Usage:
 *   COLLECTOR_URL=http://localhost:8080 k6 run scripts/loadtest/ingest.js
 *   LOAD_PROFILE=spike k6 run scripts/loadtest/ingest.js
 *   LOAD_PROFILE=soak SOAK_DURATION=1h k6 run scripts/loadtest/ingest.js
 */
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const accepted = new Counter('vsan_ingest_accepted');
const rejected503 = new Counter('vsan_ingest_rejected_503');
const rejected4xx = new Counter('vsan_ingest_rejected_4xx');
const acceptRate = new Rate('vsan_ingest_accept_rate');
const latencyAll = new Trend('vsan_ingest_latency_ms', true);
const latency202 = new Trend('vsan_latency_202_ms', true);
const latency503 = new Trend('vsan_latency_503_ms', true);

const BASE_URL = __ENV.COLLECTOR_URL || 'http://localhost:8080';
const PROFILE = __ENV.LOAD_PROFILE || 'ramp';

const SPIKE_BASELINE_RPS = intEnv('SPIKE_BASELINE_RPS', 50);
const SPIKE_BURST_RPS = intEnv('SPIKE_BURST_RPS', 2000);
const SPIKE_RECOVERY_RPS = intEnv('SPIKE_RECOVERY_RPS', 10);
const SPIKE_BASELINE_DURATION = __ENV.SPIKE_BASELINE_DURATION || '30s';
const SPIKE_BURST_DURATION = __ENV.SPIKE_BURST_DURATION || '30s';
const SPIKE_RECOVERY_DURATION = __ENV.SPIKE_RECOVERY_DURATION || '30s';
const SOAK_RPS = intEnv('SOAK_RPS', 250);
const SOAK_DURATION = __ENV.SOAK_DURATION || '30m';

function intEnv(key, def) {
  const v = __ENV[key];
  if (v === undefined || v === '') return def;
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? def : n;
}

const rampScenario = {
  executor: 'ramping-vus',
  startVUs: 0,
  stages: [
    { duration: '30s', target: 50 },
    { duration: '1m', target: 200 },
    { duration: '1m', target: 500 },
    { duration: '1m', target: 800 },
    { duration: '1m', target: 1200 },
    { duration: '30s', target: 0 },
  ],
  gracefulRampDown: '15s',
};

// Spike: 90s closed-loop demo for minikube (HPA + backpressure + recovery).
// 0–30s:   50 RPS safe baseline
// 30–60s:  2000 RPS burst (CPU spike / 503 storm)
// 60–90s:  10 RPS cool-down (self-heal observation window)
const spikeScenarios = {
  spike_baseline: {
    executor: 'constant-arrival-rate',
    rate: SPIKE_BASELINE_RPS,
    timeUnit: '1s',
    duration: SPIKE_BASELINE_DURATION,
    preAllocatedVUs: 20,
    maxVUs: 150,
    startTime: '0s',
  },
  spike_burst: {
    executor: 'constant-arrival-rate',
    rate: SPIKE_BURST_RPS,
    timeUnit: '1s',
    duration: SPIKE_BURST_DURATION,
    preAllocatedVUs: 100,
    maxVUs: 800,
    startTime: SPIKE_BASELINE_DURATION,
  },
  spike_recovery: {
    executor: 'constant-arrival-rate',
    rate: SPIKE_RECOVERY_RPS,
    timeUnit: '1s',
    duration: SPIKE_RECOVERY_DURATION,
    preAllocatedVUs: 5,
    maxVUs: 50,
    startTime: '60s',
  },
};

const soakScenario = {
  executor: 'constant-arrival-rate',
  rate: SOAK_RPS,
  timeUnit: '1s',
  duration: SOAK_DURATION,
  preAllocatedVUs: 50,
  maxVUs: 400,
};

const scenarioSets = {
  ramp: { ramp: rampScenario },
  spike: spikeScenarios,
  soak: { soak: soakScenario },
};

function thresholdsFor(profile) {
  if (profile === 'ramp') {
    return {
      vsan_ingest_accept_rate: ['rate>0.95'],
      http_req_failed: ['rate<0.05'],
      vsan_ingest_latency_ms: ['p(95)<500'],
    };
  }
  if (profile === 'soak') {
    return {
      vsan_latency_202_ms: ['p(99)<500'],
    };
  }
  return {};
}

export const options = {
  scenarios: scenarioSets[PROFILE] || scenarioSets.ramp,
  thresholds: thresholdsFor(PROFILE),
};

export function setup() {
  const health = http.get(`${BASE_URL}/healthz`);
  if (health.status !== 200) {
    throw new Error(`collector not reachable at ${BASE_URL} (healthz=${health.status})`);
  }
  return { baseUrl: BASE_URL, profile: PROFILE };
}

export default function () {
  const payload = JSON.stringify({
    ts: new Date().toISOString(),
    source: 'k6',
    tenant: `t${__VU % 10}`,
    api_name: `GET /v1/clusters/${__ITER % 100}`,
    latency_ms: 10 + Math.random() * 90,
    status_code: 200,
  });

  const res = http.post(`${BASE_URL}/v1/ingest`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'ingest' },
    timeout: '10s',
  });

  const dur = res.timings.duration;
  latencyAll.add(dur);

  const is202 = res.status === 202;
  check(res, { 'status is 202': (r) => r.status === 202 });

  if (is202) {
    accepted.add(1);
    latency202.add(dur);
  } else if (res.status === 503) {
    rejected503.add(1);
    latency503.add(dur);
  } else if (res.status >= 400 && res.status < 500) {
    rejected4xx.add(1);
  }
  acceptRate.add(is202);
}

export function handleSummary(data) {
  return { stdout: renderTextSummary(data) };
}

function pct(metric, p) {
  if (!metric || metric.values[p] === undefined) return 'n/a';
  return `${metric.values[p].toFixed(2)} ms`;
}

function renderTextSummary(data) {
  const m = data.metrics;
  const lines = [
    '=== vSAN ingest k6 summary ===',
    `profile: ${PROFILE}`,
    `target: ${BASE_URL}`,
  ];

  if (PROFILE === 'spike') {
    lines.push(
      `spike shape: ${SPIKE_BASELINE_RPS} RPS × ${SPIKE_BASELINE_DURATION} → ${SPIKE_BURST_RPS} RPS × ${SPIKE_BURST_DURATION} → ${SPIKE_RECOVERY_RPS} RPS × ${SPIKE_RECOVERY_DURATION} (~90s)`,
      '',
      '--- Fast-fail (503) ---',
      `503 p95: ${pct(m['vsan_latency_503_ms'], 'p(95)')}`,
      `503 p99: ${pct(m['vsan_latency_503_ms'], 'p(99)')}`,
      '',
      '--- Core path (202) ---',
      `202 p95: ${pct(m['vsan_latency_202_ms'], 'p(95)')}`,
      `202 p99: ${pct(m['vsan_latency_202_ms'], 'p(99)')}`,
    );
  }

  if (PROFILE === 'soak') {
    lines.push(
      `soak: ${SOAK_RPS} RPS × ${SOAK_DURATION}`,
      '',
      '--- 202 latency (end-of-run aggregate) ---',
      `202 p95: ${pct(m['vsan_latency_202_ms'], 'p(95)')}`,
      `202 p99: ${pct(m['vsan_latency_202_ms'], 'p(99)')}`,
      `202 p99.9: ${pct(m['vsan_latency_202_ms'], 'p(99.9)')}`,
      '',
      'For GC drift: compare p99 at T+5m / T+20m / T+50m via Grafana; memory via watch-collector-mem.sh',
    );
  }

  const count = (k) => {
    const metric = m[k];
    if (!metric) return 'n/a';
    if (metric.values?.count !== undefined) return metric.values.count;
    if (metric.count !== undefined) return metric.count;
    return 'n/a';
  };
  const rate = (k) => {
    const metric = m[k];
    if (!metric) return 'n/a';
    const r = metric.values?.rate ?? metric.rate;
    return r !== undefined ? `${Number(r).toFixed(2)}/s` : 'n/a';
  };
  const acceptVal = m.vsan_ingest_accept_rate?.values?.rate ?? m.vsan_ingest_accept_rate?.value;

  lines.push(
    '',
    `http_reqs: ${rate('http_reqs')} (total ${count('http_reqs')})`,
    `202 accepted: ${count('vsan_ingest_accepted')}`,
    `503 rejected: ${count('vsan_ingest_rejected_503')}`,
    `accept rate: ${acceptVal !== undefined ? (Number(acceptVal) * 100).toFixed(2) + '%' : 'n/a'}`,
    '',
  );

  return lines.join('\n');
}
