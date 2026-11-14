/**
 * load-test.js - K6 stress-test các action OpenWhisk trên cụm K3s cloud.
 *
 * Kế thừa k6/load.js của repo (cùng tỉ lệ 60% A1 / 30% A2 / 10% A3, cùng hợp đồng /invoke/<action>)
 * nhưng đổi 3 thứ cho cụm thật:
 *   1) 4 kịch bản chọn bằng SCENARIO: smoke | rate | users (người dùng đồng thời) | stress (tìm điểm gãy)
 *   2) Ngưỡng theo TỪNG action. Ngưỡng P95 < 500ms toàn cục của load.js gốc KHÔNG BAO GIỜ đạt: A3 chiếm 10% request
 *      và tự bận CPU 500ms, nên P95 toàn mẫu về mặt toán học luôn >= ~500ms + overhead.
 *   3) setup() gọi thử `ping` và dừng ngay nếu cụm/Gateway chưa sẵn sàng, thay vì chạy 5 phút toàn lỗi.
 *
 * Gọi thẳng NodePort của cụm cloud (mặc định, không cần Gateway):
 *   k6 run -e OW_API=https://10.0.0.10:31001 -e OW_AUTH="$(kubectl -n openwhisk get secret owdev-whisk.auth -o jsonpath='{.data.guest}' | base64 -d)" tests/load-test.js
 * Nếu cần đo thêm Gateway, đặt TARGET=gateway và GATEWAY_URL.
 * Xuất kết quả cho analyze.py:  thêm  --summary-export results/k6.json
 */
import http from 'k6/http';
import encoding from 'k6/encoding';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const TARGET = (__ENV.TARGET || 'direct').toLowerCase();             // gateway | direct
const GATEWAY_URL = (__ENV.GATEWAY_URL || 'http://localhost:8080').replace(/\/+$/, '');
const OW_API = (__ENV.OW_API || '').replace(/\/+$/, '');
const OW_AUTH = __ENV.OW_AUTH || '';                                  // "uuid:key" của khóa guest
const SCENARIO = (__ENV.SCENARIO || 'rate').toLowerCase();
const RATE = Number(__ENV.RATE || 30);
const DURATION = __ENV.DURATION || '5m';

if (TARGET !== 'gateway' && TARGET !== 'direct') throw new Error('TARGET phải là gateway hoặc direct');
if (TARGET === 'direct' && (!OW_API.startsWith('https://') || !OW_AUTH)) {
  throw new Error('TARGET=direct cần OW_API=https://<ip-private-node>:31001 và OW_AUTH=uuid:key');
}

const SCENARIOS = {
  // Kiểm tra đường ống thông suốt, 1 người dùng.
  smoke: { executor: 'constant-vus', vus: 1, duration: '30s' },

  // Tải CỐ ĐỊNH theo tốc độ đến (open model): K6 giữ đúng RATE req/s bất kể cụm chậm hay nhanh.
  // Đây mới là cách đo năng lực; vòng kín (VU) sẽ tự giảm tải khi hệ thống chậm và che mất điểm gãy.
  rate: {
    executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: DURATION,
    preAllocatedVUs: 100, maxVUs: 300,
  },

  // Người dùng đồng thời (closed model): mỗi VU gửi - chờ phản hồi - nghĩ 0,2-1s rồi gửi tiếp.
  users: {
    executor: 'ramping-vus', startVUs: 0, gracefulRampDown: '30s',
    stages: [
      { duration: '30s', target: 20 },
      { duration: '1m',  target: 50 },
      { duration: '2m',  target: 100 },
      { duration: '30s', target: 0 },
    ],
  },

  // Tăng dần tốc độ đến để tìm điểm gãy. Trần 160 req/s = mức Golden Config đã tính cho K6.
  // Điểm gãy thường đến từ CPU của invoker/action pod, không phải mạng.
  stress: {
    executor: 'ramping-arrival-rate', startRate: 10, timeUnit: '1s',
    preAllocatedVUs: 200, maxVUs: 600,
    stages: [
      { duration: '1m', target: 40 },
      { duration: '1m', target: 80 },
      { duration: '1m', target: 120 },
      { duration: '1m', target: 160 },
      { duration: '30s', target: 0 },
    ],
  },
};
if (!SCENARIOS[SCENARIO]) throw new Error('SCENARIO phải là: ' + Object.keys(SCENARIOS).join(' | '));

export const options = {
  insecureSkipTLSVerify: TARGET === 'direct',   // cert nginx của OpenWhisk tự ký
  scenarios: { [SCENARIO]: SCENARIOS[SCENARIO] },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    // Ngưỡng = thời gian bận CPU của action + dư địa mạng/xếp hàng.
    'http_req_duration{action:A1}': ['p(95)<500'],    // bận 0,05s
    'http_req_duration{action:A2}': ['p(95)<800'],    // bận 0,20s
    'http_req_duration{action:A3}': ['p(95)<1500'],   // bận 0,50s
    ow_throttled_429: ['count==0'],                    // còn 429 = chưa nâng giới hạn gọi (Việc 2 của Golden)
  },
};

// Ngưỡng "luôn đạt" (count>=0) chỉ để K6 in số request của TỪNG cụm trong bảng tổng kết
// (K6 chỉ tách theo tag khi tag đó xuất hiện trong một ngưỡng). Dùng để xem Gateway có chia tải sang c4 không.
if (__ENV.CLUSTERS) {
  for (const c of __ENV.CLUSTERS.split(',')) {
    options.thresholds[`ow_cluster_hits{cluster:${c.trim()}}`] = ['count>=0'];
  }
}

const clusterHits = new Counter('ow_cluster_hits');      // phân bố tải theo cụm (xem tag cluster)
const throttled = new Counter('ow_throttled_429');
const accepted202 = new Counter('ow_accepted_202');      // OpenWhisk nhận nhưng chưa xong kịp (thường là cold-start)
const serverErrors = new Counter('ow_server_errors');

function pickAction() {
  const r = Math.random();
  return r < 0.6 ? 'A1' : (r < 0.9 ? 'A2' : 'A3');
}
function urlFor(action) {
  return TARGET === 'direct'
    ? `${OW_API}/api/v1/namespaces/_/actions/${action}?blocking=true&result=true`
    : `${GATEWAY_URL}/invoke/${action}`;
}
function headers() {
  const h = { 'Content-Type': 'application/json' };
  if (TARGET === 'direct') h.Authorization = `Basic ${encoding.b64encode(OW_AUTH)}`;
  return h;
}

export function setup() {
  // Timeout 60s vì lần gọi đầu có thể là cold-start (dựng container Python 10-20s).
  const res = http.post(urlFor('ping'), '{}', { headers: headers(), timeout: '60s', tags: { action: 'setup' } });
  if (res.status !== 200) {
    exec.test.abort(`setup: gọi ping trả HTTP ${res.status} (${String(res.body).slice(0, 120)}). ` +
                    'Cụm/Gateway chưa sẵn sàng, hoặc chưa chạy actions/deploy-actions.sh.');
  }
}

export default function () {
  const action = pickAction();
  const res = http.post(urlFor(action), '{}', {
    headers: headers(), timeout: '65s',
    tags: { action, target: TARGET },
  });

  if (res.status === 429) throttled.add(1);
  else if (res.status === 202) accepted202.add(1);
  else if (res.status >= 500) serverErrors.add(1);

  let body = null;
  try { body = res.json(); } catch (_) { /* phản hồi không phải JSON (lỗi nginx/gateway) */ }

  const ok = check(res, {
    'HTTP 200': (r) => r.status === 200,
    'action trả status=ok': () => body !== null && body.status === 'ok',
  }, { action });

  if (ok && body.cluster) clusterHits.add(1, { cluster: String(body.cluster) });
  // Chỉ in 1/50 lỗi để log không nuốt CPU của máy chạy K6 và làm méo kết quả.
  if (!ok && exec.vu.iterationInInstance % 50 === 0) {
    console.warn(`${action} -> HTTP ${res.status}: ${String(res.body).slice(0, 120)}`);
  }

  if (SCENARIO === 'users') sleep(0.2 + Math.random() * 0.8);
}
