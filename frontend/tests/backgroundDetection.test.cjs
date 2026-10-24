const { test } = require('node:test');
const assert = require('node:assert/strict');

const margins = { marginLeft: 40, marginRight: 40, marginTop: 80, marginBottom: 100, lineSpacing: 70 };
const modules = () => import('../src/features/workspace/backgroundDetection.ts');

test('legacy measurements align to the detected spacing, including a first line near the edge', async () => {
  const { detectedLayout } = await modules();
  assert.equal(detectedLayout(margins).top_margin, 10);
  assert.equal(detectedLayout({ ...margins, marginTop: 20 }).top_margin, 20);
  assert.equal(detectedLayout({ ...margins, marginTop: 0 }).top_margin, 0);
});

test('layout coordinates include last-line descender space and reject inconsistent geometry', async () => {
  const { detectedLayout } = await modules();
  const current = { ...margins, firstBaseline: 80, layoutTopMargin: 10, layoutBottomMargin: 82, imageWidth: 800, imageHeight: 1000 };
  assert.equal(detectedLayout(current).bottom_margin, 82);
  for (const changes of [{ layoutTopMargin: 80 }, { imageWidth: 70 }, { imageHeight: 150 }]) {
    assert.throws(() => detectedLayout({ ...current, ...changes }), { code: 'invalidResponse' });
  }
});

test('unchanged background retains its identity and malformed corrected images never apply', async () => {
  const { correctedPaper } = await modules();
  const file = new File(['original'], 'paper.jpg');
  assert.equal(await correctedPaper(file, margins), file);
  for (const encoded of ['%%%', btoa('not a PNG')]) {
    await assert.rejects(correctedPaper(file, { ...margins, correctedBackground: encoded }), { code: 'invalidResponse' });
  }
});

test('corrected PNG dimensions are verified and decoded resources are released', async (t) => {
  const { correctedPaper } = await modules();
  const original = Object.getOwnPropertyDescriptor(globalThis, 'createImageBitmap');
  let closed = 0;
  Object.defineProperty(globalThis, 'createImageBitmap', { configurable: true, value: async () => ({ width: 800, height: 1000, close() { closed++; } }) });
  t.after(() => original ? Object.defineProperty(globalThis, 'createImageBitmap', original) : delete globalThis.createImageBitmap);
  const input = { ...margins, imageWidth: 800, imageHeight: 1000, correctedBackground: Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).toString('base64') };
  const file = new File(['original'], '纸张.jpg');
  const corrected = await correctedPaper(file, input);
  assert.equal(corrected.name, '纸张.png');
  assert.equal(corrected.type, 'image/png');
  assert.equal(closed, 1);
  await assert.rejects(correctedPaper(file, { ...input, imageWidth: 900 }), { code: 'invalidResponse' });
  assert.equal(closed, 2);
});
