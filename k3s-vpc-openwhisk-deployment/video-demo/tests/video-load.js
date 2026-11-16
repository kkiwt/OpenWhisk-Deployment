import http from 'k6/http';
import encoding from 'k6/encoding';
import { check } from 'k6';

const api = (__ENV.OW_API || '').replace(/\/+$/, '');
const auth = __ENV.OW_AUTH || '';
const scenario = (__ENV.SCENARIO || 'concurrency').toLowerCase();
const duration = __ENV.DURATION || '60s';
if (!api || !auth) throw new Error('Cần OW_API và OW_AUTH');

export const options = {
  insecureSkipTLSVerify: true,
  scenarios: {
    [scenario]: scenario === 'smoke'
      ? { executor: 'constant-vus', vus: 1, duration: '30s' }
      : { executor: 'constant-arrival-rate', rate: Number(__ENV.RATE || 8),
          timeUnit: '1s', duration, preAllocatedVUs: 30, maxVUs: 100 },
  },
  thresholds: { http_req_failed: ['rate<0.05'], checks: ['rate>0.95'] },
};

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
  check(response, {
    'HTTP 200': (r) => r.status === 200,
    'action status ok': (r) => {
      try { return r.json().status === 'ok'; } catch (_) { return false; }
    },
  });
}
