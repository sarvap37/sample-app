const http = require('http');

const hostname = '0.0.0.0';
const port = 3000;

// Environment variable to simulate failures
const SCENARIO = process.env.SCENARIO || 'normal';

let iterations = 0;

const server = http.createServer((req, res) => {
  iterations++;
  
  if (SCENARIO === 'crash') {
    // Crash after 5 requests
    if (iterations >= 5) {
      console.log('Simulating crash...');
      process.exit(1);
    }
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end(`Hello World! (will crash soon - request ${iterations}/5)\n`);
  } 
  else if (SCENARIO === 'oom') {
    // Simulate memory leak - allocate huge array
    const leak = new Array(100000000).fill('memory leak');
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end('Hello World! (running out of memory)\n');
  }
  else {
    // Normal operation
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end('Hello World!\n');
  }
});

server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
  console.log(`Scenario: ${SCENARIO}`);
});
