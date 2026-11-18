const fs = require('node:fs/promises');
const { execFileSync } = require('node:child_process');
const { existsSync } = require('node:fs');
const path = require('node:path');
const { test, expect, openHome, useSmallCanvas } = require('./fixtures');

test('fine editing moves real ink during drag and copies exactly what PDF and ZIP export', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 950 });
  await openHome(page);
  await useSmallCanvas(page);
  const editor = page.getByTestId('text-input');
  await editor.fill('甲甲甲');
  let renders = 0;
  page.on('request', (request) => {
    if (request.method() === 'POST' && request.url().endsWith('/api/generate_handwriting')) renders += 1;
  });
  const received = page.waitForResponse((response) => response.ok() && /\/task\/[^/]+\/result$/.test(response.url()));
  await page.getByTestId('fine-edit-toggle').click();
  const model = (await (await received).json()).fine_edit;
  const [first, second, third] = model.pages[0].glyphs;
  const overlay = page.getByTestId('fine-selection');
  const raster = page.getByTestId('preview-fine-raster');
  await expect(overlay).toBeVisible();
  await editor.press('Home');
  await editor.press('Shift+ArrowRight');
  await editor.press('Shift+ArrowRight');
  await expect(page.getByTestId('fine-selected-glyph')).toHaveCount(2);
  await editor.press('End');
  const pixelData = () => raster.evaluate((canvas) => canvas.toDataURL());
  const original = await pixelData();
  const hit = async (x, y) => {
    const bounds = await overlay.boundingBox();
    return { x: bounds.x + x * bounds.width / 400, y: bounds.y + y * bounds.height / 300 };
  };
  function center(glyph) { return [glyph[1] + glyph[3] / 2, glyph[2] + glyph[4] / 2]; }
  const a = await hit(...center(first));
  await page.mouse.click(a.x, a.y);
  await expect(page.getByTestId('fine-selected-glyph')).toHaveAttribute('data-glyph', String(first[0]));
  await page.getByTestId('fine-snap').uncheck();
  await page.getByRole('button', { name: '放大', exact: true }).click();
  await overlay.scrollIntoViewIfNeeded();
  const start = await hit(...center(first));
  const end = await hit(center(first)[0] + 65, center(first)[1] + 66);
  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.mouse.move(end.x, end.y, { steps: 6 });
  await expect.poll(pixelData).not.toBe(original);
  expect(renders).toBe(1);
  await page.mouse.up();
  await expect(page.getByTestId('fine-undo')).toBeEnabled();
  await page.getByTestId('fine-undo').click();
  await expect.poll(pixelData).toBe(original);
  await page.getByTestId('fine-redo').click();
  await expect.poll(pixelData).not.toBe(original);

  const left = await hit(second[1] - 4, second[2] - 5);
  const right = await hit(third[1] + third[3] + 5, Math.max(second[2] + second[4], third[2] + third[4]) + 5);
  await page.mouse.move(left.x, left.y);
  await page.mouse.down();
  await page.mouse.move(right.x, right.y, { steps: 6 });
  await page.mouse.up();
  await expect(page.getByTestId('fine-selected-glyph')).toHaveCount(2);
  const scale = page.getByTestId('fine-scale');
  const beforeSize = await pixelData();
  await scale.focus();
  await scale.press('ArrowRight');
  await page.getByTestId('fine-angle').press('ArrowRight');
  await page.getByTestId('fine-opacity').press('ArrowLeft');
  await page.getByTestId('fine-color').fill('#904927');
  await expect.poll(pixelData).not.toBe(beforeSize);
  for (const [field, value] of [['thickness', '7'], ['softness', '4']]) {
    const before = await pixelData();
    await page.getByTestId('fine-' + field).fill(value);
    await expect.poll(pixelData).not.toBe(before);
    await page.getByTestId('fine-' + field).blur();
  }
  const beforeFilter = await pixelData();
  await page.getByTestId('canvas-pane-ink').click();
  await page.getByTestId('ink-thickness-number').fill('0.7');
  await page.getByTestId('ink-softness').fill('0.4');
  await page.getByTestId('ink-opacity').fill('82');
  await expect.poll(pixelData).not.toBe(beforeFilter);
  expect(renders).toBe(1);

  const edited = await pixelData();
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await overlay.click({ button: 'right', position: { x: 30, y: 30 } });
  await page.getByTestId('preview-copy-image').click();
  await expect(page.getByRole('status').filter({ hasText: '已复制图片' })).toBeVisible();
  const copied = await page.evaluate(async () => {
    const [item] = await navigator.clipboard.read();
    const png = await item.getType('image/png');
    return [...new Uint8Array(await png.arrayBuffer())];
  });
  const imageFile = testInfo.outputPath('fine-preview.png');
  const copyFile = testInfo.outputPath('fine-copy.png');
  await fs.writeFile(imageFile, Buffer.from(edited.split(',')[1], 'base64'));
  await fs.writeFile(copyFile, Buffer.from(copied));
  await page.keyboard.press('Escape');
  const outputs = [];
  for (const [id, extension] of [['generate-image-btn', 'zip'], ['generate-pdf-btn', 'pdf']]) {
    const download = page.waitForEvent('download');
    await page.getByTestId(id).click();
    const target = testInfo.outputPath('fine-export.' + extension);
    await (await download).saveAs(target);
    outputs.push(target);
  }
  const venv = path.resolve(__dirname, '../../.venv');
  const python = process.env.E2E_PYTHON || [path.join(venv, 'Scripts/python.exe'), path.join(venv, 'bin/python')].find(existsSync) || 'python';
  execFileSync(python, ['-c', `
import io, sys, zipfile, fitz
from PIL import Image
def pixels(source):
    with Image.open(source) as image:
        return (image.size, image.convert('RGB').tobytes())
reference = pixels(sys.argv[1])
assert pixels(sys.argv[2]) == reference, 'Clipboard differs from preview'
with zipfile.ZipFile(sys.argv[3]) as archive:
    assert pixels(io.BytesIO(archive.read('0.png'))) == reference, 'ZIP differs from preview'
with fitz.open(sys.argv[4]) as pdf:
    img = pdf.extract_image(pdf[0].get_images()[0][0])['image']
    assert pixels(io.BytesIO(img)) == reference, 'PDF differs from preview'
`, imageFile, copyFile, ...outputs]);

  await expect(page.getByTestId('draft-save-status')).toHaveAttribute('data-state', 'saved');
  await page.reload();
  await page.getByTestId('preview-btn').click();
  await expect.poll(pixelData).toBe(edited);
});

test('touch lets the user box-select and then move the whole selection', async ({ browser, baseURL }) => {
  const context = await browser.newContext({ hasTouch: true, viewport: { width: 390, height: 680 }, baseURL });
  try {
    const page = await context.newPage();
    await page.goto('/');
    await page.getByTestId('live-preview-toggle').getByRole('checkbox').uncheck();
    await useSmallCanvas(page);
    await page.getByTestId('text-input').fill('甲乙');
    await page.getByTestId('workspace-pane-preview').click();
    const received = page.waitForResponse((response) => response.ok() && /\/task\/[^/]+\/result$/.test(response.url()));
    await page.getByTestId('fine-edit-toggle').tap();
    const { glyphs } = (await (await received).json()).fine_edit.pages[0];
    const overlay = page.getByTestId('fine-selection');
    await expect(overlay).toHaveCSS('touch-action', 'pan-y pinch-zoom');
    await page.getByTestId('fine-touch-box').tap();
    await expect(overlay).toHaveCSS('touch-action', 'none');
    const remote = await context.newCDPSession(page);
    const dispatch = async (type, position) => {
      await remote.send('Input.dispatchTouchEvent', { type, touchPoints: position ? [position] : [] });
    };
    const drag = async ([x1, y1], [x2, y2]) => {
      await overlay.scrollIntoViewIfNeeded();
      const box = await overlay.boundingBox();
      const point = (x, y) => ({ x: box.x + x * box.width / 400, y: box.y + y * box.height / 300 });
      await dispatch('touchStart', point(x1, y1));
      for (const progress of [0.33, 0.67, 1]) {
        await dispatch('touchMove', point(x1 + (x2 - x1) * progress, y1 + (y2 - y1) * progress));
      }
      await dispatch('touchEnd');
    };
    await drag([4, 5], [glyphs[1][1] + glyphs[1][3] + 2, 90]);
    const selected = page.getByTestId('fine-selected-glyph');
    await expect(selected).toHaveCount(2);
    const x = Number(await selected.first().getAttribute('x'));
    const move = page.getByTestId('fine-touch-move');
    await move.scrollIntoViewIfNeeded();
    const button = await move.boundingBox();
    await dispatch('touchStart', { x: button.x + button.width / 2, y: button.y + button.height / 2 });
    await dispatch('touchEnd');
    await expect(overlay).toHaveAttribute('data-touch-tool', 'move');
    const [, left, top, width, height] = glyphs[0];
    const grab = [left + width / 2, top + height / 2];
    await drag(grab, [grab[0] + 50, grab[1]]);
    await expect(selected).toHaveCount(2);
    const shift = await selected.first().evaluate((rect) => Number(rect.getAttribute('x'))) - x;
    expect(Math.abs(shift - 50)).toBeLessThanOrEqual(2);
    await expect(page.getByTestId('fine-undo')).toBeEnabled();
    const actions = page.getByTestId('fine-actions');
    const reset = actions.getByTestId('fine-reset');
    await reset.scrollIntoViewIfNeeded();
    for (const id of ['fine-color', 'fine-snap', 'fine-reset']) {
      await expect(actions.getByTestId(id)).toBeInViewport();
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
    await reset.tap();
    await expect.poll(() => selected.first().evaluate((rect) => Number(rect.getAttribute('x')))).toBe(x);
  } finally {
    await context.close();
  }
});
