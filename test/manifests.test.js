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

// Bug: scenario Services must not collide with the normal Service.
const read = (...p) => fs.readFileSync(path.join(__dirname, '..', ...p), 'utf8');

for (const s of ['crash', 'oom']) {
  test(`scenarios/${s} Service has a unique name, nodePort and selector`, () => {
    const svc = read('scenarios', s, 'service.yaml');
    assert.match(svc, new RegExp(`name: hello-world-app-${s}\\n`));
    assert.match(svc, new RegExp(`selector:\\n    app: hello-world-app\\n    scenario: ${s}\\n`));
    assert.ok(!/nodePort: 30000\b/.test(svc), 'nodePort 30000 belongs to the normal Service');
  });
}

test('every Argo CD Application has the resources-finalizer', () => {
  const dir = path.join(__dirname, '..', 'argocd');
  for (const f of fs.readdirSync(dir).filter((x) => /\.ya?ml$/.test(x))) {
    assert.match(read('argocd', f), /finalizers:\n\s+- resources-finalizer\.argocd\.argoproj\.io\n/, f);
  }
});
