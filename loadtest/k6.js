// k6 run -e BASE=http://localhost:8080 -e TENANT=default -e USER=admin -e PASS=... loadtest/k6.js
// Ramps to 10,000 virtual users. Each VU behaves like a signed-in person: list, search, think.
// All VUs share one token (a morning login storm is covered separately by the login limiter).
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 10000 },
    { duration: '5m', target: 10000 },
    { duration: '1m', target: 0 },
  ],
  thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<500'] },
};

const BASE = __ENV.BASE || 'http://localhost:8080';
const json = { 'Content-Type': 'application/json' };

export function setup() {
  const login = http.post(`${BASE}/odata/auth/login`, JSON.stringify({
    Tenant: __ENV.TENANT || 'default', Username: __ENV.USER || 'admin', Password: __ENV.PASS,
  }), { headers: json });
  check(login, { 'login ok': (r) => r.status === 200 });
  const token = login.json('access_token');
  const auth = { headers: { Authorization: `Bearer ${token}` } };
  const ws = http.get(`${BASE}/odata/v4/ecm/Workspaces`, auth).json('value.0.ID');
  const words = ['report', 'invoice', 'contract', 'meeting', 'budget'];
  for (let i = 0; i < 200; i++) { // seed some documents so lists and search have something to return
    http.post(`${BASE}/odata/v4/ecm/Documents`, JSON.stringify({
      WorkspaceID: ws, Name: `seed-${i}.txt`, Title: `${words[i % words.length]} ${i}`,
    }), { headers: { ...json, Authorization: `Bearer ${token}` } });
  }
  return { token, ws };
}

export default function (data) {
  const auth = { headers: { Authorization: `Bearer ${data.token}` } };
  const base = `${BASE}/odata/v4/ecm`;
  const list = http.get(`${base}/Documents?$filter=WorkspaceID eq '${data.ws}'&$top=25&$count=true`, auth);
  check(list, { 'list ok': (r) => r.status === 200 });
  sleep(2 + Math.random() * 4);
  const q = ['report', 'invoice', 'contract', 'budget'][Math.floor(Math.random() * 4)];
  const search = http.get(`${base}/Documents?$search=${q}&$top=25`, auth);
  check(search, { 'search ok': (r) => r.status === 200 });
  sleep(4 + Math.random() * 8);
}
