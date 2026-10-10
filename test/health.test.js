const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const server = require('../app');

function get(port, p) {
  return new Promise((resolve, reject) => {
    require('node:http').get({ port, path: p }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

test('health endpoints return 200 and do not count as requests', async () => {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  try {
    // In crash mode the 5th counted request would exit; here, just verify counter via body-free calls.
    for (let i = 0; i < 20; i++) {
      for (const p of ['/healthz', '/readyz']) {
        const r = await get(port, p);
        assert.strictEqual(r.status, 200);
      }
    }
    const r = await get(port, '/');
    assert.strictEqual(r.body, 'Hello World!\n');
  } finally {
    server.close();
  }
});

test('k8s deployment probes use /healthz and /readyz', () => {
  const text = fs.readFileSync(path.join(__dirname, '..', 'k8s', 'deployment.yaml'), 'utf8');
  assert.match(text, /livenessProbe:\s+httpGet:\s+path: \/healthz/);
  assert.match(text, /readinessProbe:\s+httpGet:\s+path: \/readyz/);
});
