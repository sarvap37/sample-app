const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// Bug: the Argo CD app syncs k8s/, so only the healthy workload may live there.
test('k8s/ contains only the healthy workload (no crash/OOM deployments)', () => {
  const dir = path.join(__dirname, '..', 'k8s');
  const files = fs.readdirSync(dir).filter((f) => /\.ya?ml$/.test(f)).sort();
  assert.deepStrictEqual(files, ['deployment.yaml', 'service.yaml']);
  for (const f of files) {
    const text = fs.readFileSync(path.join(dir, f), 'utf8');
    assert.ok(!/crash|oom/i.test(text), `${f} references a failure scenario`);
  }
});
