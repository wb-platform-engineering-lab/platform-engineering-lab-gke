// load-test.js — k6 load test simulating CoverLine open enrollment traffic
// Ramps up to 100 virtual users over 2 minutes, holds for 3 minutes, then ramps down.
// Run with: k6 run phase-8-advanced-k8s/load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('error_rate');
const claimsLatency = new Trend('claims_latency', true);

export const options = {
  stages: [
    { duration: '1m', target: 50  },  // ramp up: 0 → 50 users in 1 min
    { duration: '1m', target: 100 },  // ramp up: 50 → 100 users in 1 min (open enrollment peak)
    { duration: '3m', target: 100 },  // hold peak load for 3 minutes
    { duration: '1m', target: 0   },  // ramp down
  ],
  thresholds: {
    // p(95) threshold is intentionally loose — traffic runs through kubectl port-forward,
    // which is a single-threaded proxy with limited throughput. In production, traffic
    // would go through a LoadBalancer or Ingress and latency would be far lower.
    // The goal here is to trigger HPA and Cluster Autoscaler, not benchmark raw throughput.
    http_req_duration: ['p(95)<30000'], // 95% of requests under 30s (port-forward ceiling)
    error_rate:        ['rate<0.05'],   // error rate under 5%
  },
};

const BASE_URL = 'http://localhost:5000';

export default function () {
  // Simulate member viewing claims list
  const listRes = http.get(`${BASE_URL}/claims`);
  check(listRes, {
    'GET /claims status 200': (r) => r.status === 200,
  });
  errorRate.add(listRes.status !== 200);
  claimsLatency.add(listRes.timings.duration);

  sleep(1);

  // Simulate member submitting a claim
  const submitRes = http.post(
    `${BASE_URL}/claims`,
    JSON.stringify({
      member_id: `member_${Math.floor(Math.random() * 10000)}`,
      amount: Math.floor(Math.random() * 500) + 50,
      description: 'General practitioner consultation',
    }),
    { headers: { 'Content-Type': 'application/json' } }
  );
  check(submitRes, {
    'POST /claims status 201': (r) => r.status === 201 || r.status === 200,
  });
  errorRate.add(submitRes.status >= 400);

  sleep(Math.random() * 2);
}

export function handleSummary(data) {
  const fmt = (v) => (v != null ? v.toFixed(0) : 'N/A');
  const dur = data.metrics.http_req_duration?.values;
  return {
    stdout: `
=== CoverLine Open Enrollment Load Test ===
Duration:        ${(data.state.testRunDurationMs / 1000).toFixed(0)}s
Virtual Users:   100 peak
Total Requests:  ${data.metrics.http_reqs.values.count}
Request Rate:    ${data.metrics.http_reqs.values.rate.toFixed(1)} req/s
Error Rate:      ${(data.metrics.error_rate.values.rate * 100).toFixed(2)}%
p95 Latency:     ${fmt(dur?.['p(95)'])} ms
p99 Latency:     ${fmt(dur?.['p(99)'])} ms
==========================================
`,
  };
}
