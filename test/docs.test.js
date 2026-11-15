const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

test('J3 feedback trial doc exists with heading and sentence', () => {
  const text = fs.readFileSync(path.join(__dirname, '..', 'docs', 'j3-feedback-trial.md'), 'utf8');
  assert.match(text, /^# J3 feedback trial$/m);
  assert.ok(text.includes('This disposable document exercises the pull request feedback loop.'));
  assert.ok(text.includes('Inline feedback was applied on the same pull request.'));
  assert.ok(text.includes('This document also tests autonomous feedback handling.'));
});

test('J3 feedback trial doc has the final outside-team sentence', () => {
  const text = fs.readFileSync(path.join(__dirname, '..', 'docs', 'j3-feedback-trial.md'), 'utf8');
  assert.ok(text.includes('This file supports the final outside-team feedback check.'));
});
