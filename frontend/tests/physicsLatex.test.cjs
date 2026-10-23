const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/physicsLatex.json'), 'utf8'));
const modulePromise = import('../src/utils/physicsLatex.ts');
for (const { name, source, expected } of fixtures) {
  test(`physics normalizer: ${name}`, async () => {
    const { normalizePhysicsLatex } = await modulePromise;
    assert.equal(normalizePhysicsLatex(source), expected);
    assert.equal(normalizePhysicsLatex(expected), expected, 'normalization must be idempotent');
  });
}

test('physics bounds preserve deeply nested and oversized input', async () => {
  const { normalizePhysicsLatex } = await modulePromise;
  for (const source of [
    '\\abs{'.repeat(18) + 'x' + '}'.repeat(18),
    '\\dv{' + 'x'.repeat(4097) + '}{t}',
    ' '.repeat(32769) + '\\dv{x}',
  ]) assert.equal(normalizePhysicsLatex(source), source);
});

test('unsupported derivative prevents partial mutation of the formula', async () => {
  const { normalizePhysicsLatex } = await modulePromise;
  const source = String.raw`\abs{x}+\pdv{\norm{u}}{x}{y}`;
  assert.equal(normalizePhysicsLatex(source), source);
});

test('large sequences use bounded scans and preserve every derivative', async () => {
  const { normalizePhysicsLatex } = await modulePromise;
  const source = String.raw`\dv{x}+`.repeat(2000);
  const expected = String.raw`\frac{\mathrm{d}}{\mathrm{d}{x}}+`.repeat(2000);
  assert.equal(normalizePhysicsLatex(source), expected);
});
