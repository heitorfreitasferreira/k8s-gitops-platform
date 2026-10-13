// ABOUTME: Teste de carga da todolist-app. Sobe VUs em rampa, mantendo a
// ABOUTME: sessao por VU, para exercitar CPU e provar o HPA do cluster.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://todolist';
const ADMIN_USER = __ENV.ADMIN_USER || 'admin';
const ADMIN_PASSWORD = __ENV.ADMIN_PASSWORD || 'admin';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 20 },
        { duration: '2m', target: 60 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<800'],
  },
};

export default function () {
  const jar = http.cookieJar();

  const login = http.post(
    `${BASE_URL}/login`,
    { username: ADMIN_USER, password: ADMIN_PASSWORD },
    { redirects: 0 },
  );
  check(login, { 'login ok': (r) => r.status === 200 || r.status === 302 });

  const list = http.get(`${BASE_URL}/`);
  check(list, { 'lista ok': (r) => r.status === 200 });

  const title = `load-${__VU}-${__ITER}`;
  const add = http.post(`${BASE_URL}/add`, { task: title }, { redirects: 0 });
  check(add, { 'add ok': (r) => r.status === 200 || r.status === 302 });

  sleep(1);
}
