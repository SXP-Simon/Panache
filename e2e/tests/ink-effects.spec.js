const fs = require('node:fs/promises');
const { test, expect, openHome, fillText, useSmallCanvas, expectPreviewImageLoaded, previewPng } = require('./fixtures');

test('dragging ink controls updates only the ink layer and exports the chosen look', async ({ page }, testInfo) => {
  await openHome(page);
  await useSmallCanvas(page);
  await fillText(page, '笔迹滤镜  x²');
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
  await page.getByTestId('ink-effects-toggle').click();

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

  const thickness = await startDrag('ink-thickness', 0.98);
  await expect(thickness).toHaveValue('2');
  await expect(ink).not.toHaveCSS('mask-image', originalMask);
  await page.mouse.up();

  const thickMask = await mask();
  const softness = await startDrag('ink-softness', 0.98);
  await expect(softness).toHaveValue('2');
  await expect(ink).not.toHaveCSS('mask-image', thickMask);
  await page.mouse.up();
  await page.getByTestId('ink-color-input').fill('#254587');
  await expect(ink).toHaveCSS('background-color', 'rgb(37, 69, 135)');
  await expect(paper).toHaveAttribute('src', paperSource);
  expect(submissions).toBe(1);

  await fs.writeFile(testInfo.outputPath('preview.png'), Buffer.from(await previewPng(page)));
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
