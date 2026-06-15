const http = require('http');
const promClient = require('prom-client');

const hostname = '0.0.0.0';
const port = process.env.PORT || 3000;

const register = promClient.register;

// Default Node.js runtime metrics (event loop, GC, memory) — only when running as server.
// Guarded here to prevent a hanging setInterval during `npm test`.
if (require.main === module) {
  promClient.collectDefaultMetrics({ register });
}

const httpRequestsTotal = new promClient.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'path', 'status'],
  registers: [register],
});

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'path', 'status'],
  buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1],
  registers: [register],
});

function createHandler() {
  const SCENARIO = process.env.SCENARIO || 'normal';
  let iterations = 0;

  return function handler(req, res) {
    if (req.url === '/health') {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ status: 'ok' }));
      return;
    }

    if (req.url === '/metrics') {
      register.metrics().then((metrics) => {
        res.setHeader('Content-Type', register.contentType);
        res.end(metrics);
      }).catch((err) => {
        res.statusCode = 500;
        res.end(err.message);
      });
      return;
    }

    const endTimer = httpRequestDuration.startTimer({ method: req.method, path: req.url });
    iterations++;

    let body;
    if (SCENARIO === 'crash') {
      if (iterations >= 5) {
        console.log('Simulating crash...');
        process.exit(1);
      }
      body = `Hello World! (will crash soon - request ${iterations}/5)\n`;
    } else if (SCENARIO === 'oom') {
      const leak = new Array(100000000).fill('memory leak'); // eslint-disable-line no-unused-vars
      body = 'Hello World! (running out of memory)\n';
    } else {
      body = 'Hello World!\n';
    }

    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end(body);

    const status = String(res.statusCode);
    httpRequestsTotal.inc({ method: req.method, path: req.url, status });
    endTimer({ status });
  };
}

if (require.main === module) {
  const server = http.createServer(createHandler());
  server.listen(port, hostname, () => {
    console.log(`Server running at http://${hostname}:${port}/`);
    console.log(`Scenario: ${process.env.SCENARIO || 'normal'}`);
  });
}

module.exports = { createHandler };
