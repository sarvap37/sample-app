const http = require('http');

const hostname = '0.0.0.0';
const port = process.env.PORT || 3000;

function createHandler() {
  const SCENARIO = process.env.SCENARIO || 'normal';
  let iterations = 0;

  return function handler(req, res) {
    iterations++;

    if (SCENARIO === 'crash') {
      if (iterations >= 5) {
        console.log('Simulating crash...');
        process.exit(1);
      }
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/plain');
      res.end(`Hello World! (will crash soon - request ${iterations}/5)\n`);
    } else if (SCENARIO === 'oom') {
      const leak = new Array(100000000).fill('memory leak'); // eslint-disable-line no-unused-vars
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/plain');
      res.end('Hello World! (running out of memory)\n');
    } else {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'text/plain');
      res.end('Hello World!\n');
    }
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
