import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const api = (__ENV.OW_API || '').replace(/\/+$/, '');
const auth = __ENV.OW_AUTH || '';
const scenario = (__ENV.SCENARIO || 'concurrency').toLowerCase();
const duration = __ENV.DURATION || '60s';
const rate = Number(__ENV.RATE || 8);
if (!api || !auth) throw new Error('Cần OW_API và OW_AUTH');
if (![2, 8, 12].includes(rate)) throw new Error('RATE phải là 2, 8 hoặc 12');

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    [scenario]: scenario === 'smoke'
      ? { executor: 'constant-vus', vus: 1, duration: '30s' }
      : { executor: 'constant-arrival-rate', rate,
          timeUnit: '1s', duration, preAllocatedVUs: 30, maxVUs: 100 },
  },
};

const totalRequests = new Counter('demo_requests_total');
const successfulRequests = new Counter('demo_requests_successful');
const failedRequests = new Counter('demo_requests_failed');
const latency = new Trend('demo_latency_ms', true);

function action() {
  const r = Math.random();
  return r < 0.6 ? 'Group4_Action1' : (r < 0.9 ? 'Group4_Action2' : 'Group4_Action3');
}

export default function () {
  const name = action();
  const response = http.post(
    `${api}/api/v1/namespaces/_/actions/${name}?blocking=true&result=true`,
    '{}',
    { headers: {
      Authorization: `Basic ${encoding.b64encode(auth)}`,
      'Content-Type': 'application/json',
    }, timeout: '65s' },
  );
  const ok = check(response, {
    'HTTP 200': (r) => r.status === 200,
    'action status ok': (r) => {
      try { return r.json().status === 'ok'; } catch (_) { return false; }
    },
  });
  totalRequests.add(1, { rate: String(rate) });
  latency.add(response.timings.duration, { rate: String(rate) });
  if (ok) successfulRequests.add(1, { rate: String(rate) });
  else failedRequests.add(1, { rate: String(rate) });
}
