// load-test.js — k6 load test simulating CoverLine open enrollment traffic
// Ramps up to 200 virtual users over 2 minutes, holds for 3 minutes, then ramps down.
// Run with: k6 run phase-8-advanced-k8s/load-test.js

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate = new Rate('error_rate');
const claimsLatency = new Trend('claims_latency', true);

export const options = {
  stages: [
    { duration: '1m', target: 50  },  // ramp up: 0 → 50 users in 1 min
    { duration: '1m', target: 200 },  // ramp up: 50 → 200 users in 1 min (open enrollment peak)
    { duration: '3m', target: 200 },  // hold peak load for 3 minutes
    { duration: '1m', target: 0   },  // ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'],  // 95% of requests under 2s
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
  return {
    stdout: `
=== CoverLine Open Enrollment Load Test ===
Duration:        ${data.state.testRunDurationMs / 1000}s
Virtual Users:   200 peak
Total Requests:  ${data.metrics.http_reqs.values.count}
Request Rate:    ${data.metrics.http_reqs.values.rate.toFixed(1)} req/s
Error Rate:      ${(data.metrics.error_rate.values.rate * 100).toFixed(2)}%
p95 Latency:     ${data.metrics.http_req_duration.values['p(95)'].toFixed(0)}ms
p99 Latency:     ${data.metrics.http_req_duration.values['p(99)'].toFixed(0)}ms
==========================================
`,
  };
}
