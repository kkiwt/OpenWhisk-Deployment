import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const target = (__ENV.TARGET || 'direct').toLowerCase();
const api = (__ENV.OW_API || '').replace(/\/+$/, '');
const auth = __ENV.OW_AUTH || '';
const scenario = (__ENV.SCENARIO || 'concurrency').toLowerCase();
const duration = __ENV.DURATION || '60s';
const rate = Number(__ENV.RATE || 8);

if (!api) {
  throw new Error('Cần OW_API');
}

if (target === 'direct' && !auth) {
  throw new Error('Direct mode cần OW_AUTH');
}

if (!['direct', 'gateway'].includes(target)) {
  throw new Error('TARGET phải là direct hoặc gateway');
}

if (!Number.isInteger(rate) || rate < 1 || rate > 16) {
  throw new Error('RATE phải là số nguyên từ 1 đến 16');
}

export const options = {
  insecureSkipTLSVerify: true,

  scenarios: {
    [scenario]: scenario === 'smoke'
      ? {
          executor: 'constant-vus',
          vus: 1,
          duration: '30s',
        }
      : {
          executor: 'constant-arrival-rate',
          rate,
          timeUnit: '1s',
          duration,
          preAllocatedVUs: 100,
          maxVUs: 200,
        },
  },
};

const totalRequests = new Counter('demo_requests_total');
const successfulRequests = new Counter('demo_requests_successful');
const failedRequests = new Counter('demo_requests_failed');
const latency = new Trend('demo_latency_ms', true);

function action() {
  const r = Math.random();

  if (r < 0.6) return 'Group4_Action1';
  if (r < 0.9) return 'Group4_Action2';

  return 'Group4_Action3';
}

export default function () {
  const name = action();

  // Gateway mode: Global LB phân phối giữa C1 và C2
  const url = target === 'gateway'
    ? `${api}/global/invoke/${name}`
    : `${api}/api/v1/namespaces/guest/actions/${name}?blocking=true&result=true`;

  const headers = {
    'Content-Type': 'application/json',
  };

  if (target === 'direct') {
    headers.Authorization = `Basic ${encoding.b64encode(auth)}`;
  }

  const response = http.post(url, '{}', {
    headers,
    timeout: '60s',
  });

  totalRequests.add(1);
  latency.add(response.timings.duration);

  let validResult = false;

  try {
    const body = response.json();
    validResult = body && body.status === 'ok';
  } catch (_) {
    validResult = false;
  }

  const ok = check(response, {
    'HTTP 200': (r) => r.status === 200,
    'action status ok': () => validResult,
  });

  if (ok) {
    successfulRequests.add(1);
  } else {
    failedRequests.add(1);
  }
}