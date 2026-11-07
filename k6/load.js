import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';

const GATEWAY_URL = (__ENV.GATEWAY_URL || 'http://localhost:8080').replace(/\/+$/, '');
const TARGET_MODE = (__ENV.TARGET_MODE || 'gateway').toLowerCase();
const DIRECT_API_URL = (__ENV.DIRECT_API_URL || '').replace(/\/+$/, '');
const DIRECT_AUTH = __ENV.DIRECT_AUTH || '';
const DIRECT_CLUSTER = __ENV.DIRECT_CLUSTER || 'unknown';
const DIRECT_NAMESPACE = __ENV.DIRECT_NAMESPACE || '_';
const DRY_RUN = __ENV.DRY_RUN === '1';

if (TARGET_MODE !== 'gateway' && TARGET_MODE !== 'direct') {
  throw new Error('TARGET_MODE must be gateway or direct');
}
if (TARGET_MODE === 'direct' && (!DIRECT_API_URL.startsWith('https://') || !DIRECT_AUTH)) {
  throw new Error('Direct mode requires HTTPS DIRECT_API_URL and DIRECT_AUTH');
}

export const options = {
  insecureSkipTLSVerify: TARGET_MODE === 'direct',
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 50),
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs: Number(__ENV.PRE_VUS || 100),
      maxVUs: Number(__ENV.MAX_VUS || 300),
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

export default function () {
  const r = Math.random();
  const action = r < 0.6 ? 'A1' : (r < 0.9 ? 'A2' : 'A3');

  const url = TARGET_MODE === 'direct'
    ? `${DIRECT_API_URL}/api/v1/namespaces/${encodeURIComponent(DIRECT_NAMESPACE)}/actions/${action}?blocking=true&result=true`
    : `${GATEWAY_URL}/invoke/${action}`;

  if (DRY_RUN) {
    console.log(`DRY_RUN: POST ${url}`);
    return;
  }

  const headers = { 'Content-Type': 'application/json' };
  if (TARGET_MODE === 'direct') {
    headers.Authorization = `Basic ${encoding.b64encode(DIRECT_AUTH)}`;
  }
  const response = http.post(url, '{}', {
    headers,
    tags: {
      action: action,
      target_mode: TARGET_MODE,
      cluster: TARGET_MODE === 'direct' ? DIRECT_CLUSTER : 'gateway',
    },
  });

  const success = check(response, {
    'HTTP 2xx': (res) => res.status >= 200 && res.status < 300,
  });

  if (!success) {
    console.log(`Lỗi tại ${url} -> Status: ${response.status}, Body: ${response.body}`);
  }
}
