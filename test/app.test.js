const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { createHandler } = require('../app');

function startServer(scenario) {
  process.env.SCENARIO = scenario;
  const server = http.createServer(createHandler());
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () =>
      resolve({ server, port: server.address().port })
    );
  });
}

function get(port) {
  return new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${port}`, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

test('normal: GET / responds 200 with Hello World', async (t) => {
  const { server, port } = await startServer('normal');
  t.after(() => server.close());

  const { status, body } = await get(port);
  assert.equal(status, 200);
  assert.equal(body, 'Hello World!\n');
});

test('normal: Content-Type is text/plain', async (t) => {
  const { server, port } = await startServer('normal');
  t.after(() => server.close());

  await new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${port}`, (res) => {
      assert.match(res.headers['content-type'], /text\/plain/);
      res.resume();
      res.on('end', resolve);
    }).on('error', reject);
  });
});

test('crash: first request returns countdown message', async (t) => {
  const { server, port } = await startServer('crash');
  t.after(() => server.close());

  const { status, body } = await get(port);
  assert.equal(status, 200);
  assert.match(body, /will crash soon/);
  assert.match(body, /1\/5/);
});

test('crash: request count increments each call', async (t) => {
  const { server, port } = await startServer('crash');
  t.after(() => server.close());

  const r1 = await get(port);
  const r2 = await get(port);
  assert.match(r1.body, /1\/5/);
  assert.match(r2.body, /2\/5/);
});
