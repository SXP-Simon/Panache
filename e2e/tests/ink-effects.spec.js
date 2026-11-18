const fs = require('node:fs/promises');
const { test, expect, openHome, setNumber, expectPreviewImageLoaded, previewPng } = require('./fixtures');

async function openInkDocument(page) {
  await openHome(page);
  await page.getByTestId('live-preview-toggle').getByRole('checkbox').uncheck();
  await page.getByTestId('canvas-pane-paper').click();
  await setNumber(page, 'width-input', 400);
  await setNumber(page, 'height-input', 300);
  await page.getByTestId('canvas-pane-layout').click();
  await setNumber(page, 'font-size-input', 32);
  await setNumber(page, 'line-spacing-input', 48);
}

test('dragging ink controls updates only the ink layer and exports the chosen look', async ({ page }, testInfo) => {
  await openInkDocument(page);
  await page.getByTestId('canvas-pane-edit').click();
  await page.getByTestId('text-input').fill('笔迹滤镜  x²');
  let submissions = 0;
  page.on('request', (request) => {
    if (request.method() === 'POST' && new URL(request.url()).pathname === '/api/generate_handwriting') {
      submissions += 1;
    }
  });
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  const paper = page.getByTestId('preview-image');
  const paperSource = await paper.getAttribute('src');
  const ink = page.getByTestId('preview-ink-layer');
  const mask = () => ink.evaluate((node) => getComputedStyle(node).maskImage);
  const originalMask = await mask();
  await page.getByTestId('canvas-pane-ink').click();

  async function startDrag(id, fraction) {
    const slider = page.getByTestId(id);
    await slider.scrollIntoViewIfNeeded();
    const box = await slider.boundingBox();
    await page.mouse.move(box.x + box.width * 0.5, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * fraction, box.y + box.height / 2, { steps: 4 });
    return slider;
  }

  const opacity = await startDrag('ink-opacity', 0.42);
  const value = () => opacity.inputValue();
  await expect.poll(value).toMatch(/^4\d$/);
  await expect(ink).toHaveCSS('opacity', String(Number(await value()) / 100));
  await page.mouse.up();

  const thickness = await startDrag('ink-thickness', 0.66);
  await expect(thickness).toHaveValue(/^0\.[5-9]$/);
  await expect(ink).not.toHaveCSS('mask-image', originalMask);
  await page.mouse.up();
  const draggedMask = await mask();
  await page.getByTestId('ink-thickness-number').fill('1.2');
  await expect(thickness).toHaveValue('1.2');
  await expect(ink).not.toHaveCSS('mask-image', draggedMask);

  const thickMask = await mask();
  const softness = await startDrag('ink-softness', 0.22);
  await expect(softness).toHaveValue(/^0\.[3-6]$/);
  await expect(ink).not.toHaveCSS('mask-image', thickMask);
  await page.mouse.up();
  await page.getByTestId('ink-color-input').fill('#254587');
  await expect(ink).toHaveCSS('background-color', 'rgb(37, 69, 135)');
  await expect(paper).toHaveAttribute('src', paperSource);
  expect(submissions).toBe(1);

  const preview = await previewPng(page);
  await fs.writeFile(testInfo.outputPath('preview.png'), Buffer.from(preview));
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  for (const prefix of ['preview', 'expanded-preview']) {
    if (prefix === 'expanded-preview') {
      await page.getByTestId('expand-preview').click();
      await expect(page.getByTestId('expanded-preview-ink-layer')).not.toHaveCSS('mask-image', originalMask);
    }
    await page.getByTestId(prefix + '-image').click({ button: 'right' });
    await page.getByTestId(prefix + '-copy-image').click();
    await expect(page.getByRole('status').filter({ hasText: '已复制图片' })).toBeVisible();
    const clipboard = await page.evaluate(async (expectedPng) => {
      const [item] = await navigator.clipboard.read();
      const copied = await createImageBitmap(await item.getType('image/png'));
      const expected = await createImageBitmap(new Blob([Uint8Array.from(expectedPng)], { type: 'image/png' }));
      const canvas = new OffscreenCanvas(expected.width, expected.height);
      const context = canvas.getContext('2d');
      context.drawImage(expected, 0, 0);
      const pixels = context.getImageData(0, 0, expected.width, expected.height).data;
      context.clearRect(0, 0, expected.width, expected.height);
      context.drawImage(copied, 0, 0);
      const actual = context.getImageData(0, 0, expected.width, expected.height).data;
      let worst = 0;
      for (let i = 0; i < pixels.length; i++) worst = Math.max(worst, Math.abs(pixels[i] - actual[i]));
      const result = { width: copied.width, height: copied.height, worst };
      copied.close();
      expected.close();
      return result;
    }, preview);
    expect(clipboard.width).toBe(400);
    expect(clipboard.height).toBe(300);
    expect(clipboard.worst).toBeLessThanOrEqual(2);
    await page.keyboard.press('Escape');
  }
  await page.getByTestId('fullscreen-preview-close').click();
  const saved = page.waitForEvent('download');
  await paper.click({ button: 'right' });
  await page.getByTestId('preview-save-image').click();
  expect((await saved).suggestedFilename()).toBe('images.png');
  const background = await paper.evaluate(async (image) => [...new Uint8Array(await (await fetch(image.src)).arrayBuffer())]);
  await fs.writeFile(testInfo.outputPath('paper.png'), Buffer.from(background));
  for (const [button, extension] of [['generate-image-btn', 'zip'], ['generate-pdf-btn', 'pdf']]) {
    const downloaded = page.waitForEvent('download');
    const submitted = page.waitForRequest((request) =>
      request.method() === 'POST' && new URL(request.url()).pathname === '/api/generate_handwriting',
    );
    await page.getByTestId(button).click();
    const form = (await submitted).postData();
    for (const [field, setting] of [
      ['ink_opacity', await value()],
      ['ink_thickness', await thickness.inputValue()],
      ['ink_softness', await softness.inputValue()],
      ['fill', '(37,69,135,255)'],
    ]) {
      expect(form).toContain('name="' + field + '"\r\n\r\n' + setting);
    }
    const download = await downloaded;
    await download.saveAs(testInfo.outputPath('export.' + extension));
  }
});

test('digit and English ink settings reach rendering, and filters update each layer independently', async ({ page }) => {
  await openInkDocument(page);
  await page.getByTestId('latin-font-select').selectOption('kalam');
  await page.getByTestId('digit-font-select').selectOption('latin');
  await page.getByTestId('canvas-pane-edit').click();
  await page.getByTestId('text-input').fill('中文\nKalam 123\n(1)/(x)');
  await page.getByTestId('canvas-pane-ink').click();
  await page.getByTestId('separate-latin-ink-checkbox').check();
  const submitted = page.waitForRequest(
    (request) => request.method() === 'POST' && request.url().endsWith('/api/generate_handwriting'),
  );
  await page.getByTestId('preview-btn').click();
  expect((await submitted).postData()).toMatch(/name="digit_font"\r?\n\r?\nlatin/);
  await expectPreviewImageLoaded(page);
  const main = page.getByTestId('preview-ink-layer');
  const latin = page.getByTestId('preview-latin-ink-layer');
  await expect(latin).toBeVisible();
  const readMask = (ink) => ink.evaluate((node) => getComputedStyle(node).maskImage);
  const mainMask = await readMask(main);
  const originalLatinMask = await readMask(latin);
  await page.getByTestId('latin-ink-opacity').fill('35');
  await page.getByTestId('latin-ink-thickness').fill('1.2');
  await page.getByTestId('latin-ink-softness').fill('0.4');
  await page.getByTestId('latin-ink-color-input').fill('#305ca8');
  await expect(latin).toHaveCSS('opacity', '0.35');
  await expect(latin).toHaveCSS('background-color', 'rgb(48, 92, 168)');
  await expect(latin).not.toHaveCSS('mask-image', originalLatinMask);
  await expect(main).toHaveCSS('opacity', '1');
  await expect(main).toHaveCSS('mask-image', mainMask);

  await page.getByTestId('expand-preview').click();
  await expect(page.getByTestId('expanded-preview-latin-ink-layer')).toHaveCSS('opacity', '0.35');
  await page.getByTestId('fullscreen-preview-close').click();
  await expect(page.getByTestId('fullscreen-preview')).toHaveCount(0);
  const saved = page.waitForEvent('download');
  await page.getByTestId('preview-image').click({ button: 'right' });
  await page.getByTestId('preview-save-image').click();
  const png = await fs.readFile(await (await saved).path(), 'base64');
  const containsBlueInk = await page.evaluate(async (encoded) => {
    const response = await fetch('data:image/png;base64,' + encoded);
    const image = await createImageBitmap(await response.blob());
    const canvas = new OffscreenCanvas(image.width, image.height);
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, 0, image.width, image.height).data;
    image.close();
    for (let index = 0; index < pixels.length; index += 4) {
      if (pixels[index + 2] - pixels[index] > 12) return true;
    }
    return false;
  }, png);
  expect(containsBlueInk).toBe(true);
  await expect(page.getByTestId('draft-save-status')).toHaveAttribute('data-state', 'saved');
  await page.reload();
  await page.getByTestId('canvas-pane-layout').click();
  await expect(page.getByTestId('digit-font-select')).toHaveValue('latin');
  await page.getByTestId('canvas-pane-ink').click();
  await expect(page.getByTestId('separate-latin-ink-checkbox')).toBeChecked();
  await expect(page.getByTestId('latin-ink-opacity')).toHaveValue('35');
});
