const { test, expect, openHome, fillText, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');

test('generated preview zooms without clipping the left edge and opens the image viewer', async ({ page }) => {
  await openHome(page);
  await useSmallCanvas(page);
  await fillText(page, '手写预览\n放大、缩小与全屏');
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  const current = page.getByTestId('preview-image');
  const canvas = page.getByTestId('preview-viewport');
  const fit = await current.evaluate((image) => image.offsetWidth);
  await page.getByRole('button', { name: '放大', exact: true }).click();
  await expect.poll(() => current.evaluate((image) => image.offsetWidth)).toBeGreaterThan(fit * 1.2);
  await expect.poll(() => canvas.evaluate((node) => node.scrollWidth - node.clientWidth)).toBeGreaterThan(0);
  expect(await canvas.evaluate((node) =>
    node.querySelector('img').getBoundingClientRect().left - node.getBoundingClientRect().left
  )).toBeGreaterThanOrEqual(0);
  await page.getByRole('button', { name: '缩小', exact: true }).click();
  await expect.poll(() => current.evaluate((image) => image.offsetWidth)).toBe(fit);
  await page.getByRole('button', { name: '缩小', exact: true }).click();
  await expect.poll(() => current.evaluate((image) => image.offsetWidth)).toBeLessThan(fit);
  await page.getByRole('button', { name: '适应窗口' }).click();
  await expect.poll(() => current.evaluate((image) => image.offsetWidth)).toBe(fit);
  await page.getByTestId('expand-preview').click();
  const viewer = page.getByTestId('fullscreen-preview');
  await expect(viewer).toBeVisible();
  const expanded = viewer.getByTestId('expanded-preview-image');
  const expandedCanvas = viewer.getByTestId('expanded-preview-viewport');
  await expect.poll(() => expandedCanvas.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeLessThanOrEqual(1);
  const expandedFit = await expanded.evaluate((image) => image.offsetWidth);
  await viewer.getByRole('button', { name: '放大', exact: true }).click();
  await expect.poll(() => expanded.evaluate((image) => image.offsetWidth)).toBeGreaterThan(expandedFit * 1.2);
  await page.keyboard.press('Escape');
  await expect(viewer).toHaveCount(0);
  await expect(page.getByTestId('expand-preview')).toBeFocused();
});

test('paper-only preview opens the image viewer on a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 720 });
  await openHome(page);
  const fullscreen = page.getByTestId('expand-preview');
  await expect(fullscreen).toBeDisabled();
  await page.getByTestId('paper-settings-toggle').click();
  await page.getByTestId('background-image-input').setInputFiles({
    name: 'plain.png',
    mimeType: 'image/png',
    buffer: Buffer.from(await page.evaluate(() => {
      const canvas = document.createElement('canvas');
      canvas.width = 160;
      canvas.height = 260;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#eee4d3';
      ctx.fillRect(0, 0, 160, 260);
      return canvas.toDataURL().split(',')[1];
    }), 'base64'),
  });
  await page.getByTestId('detect-background-cancel').click();
  await expect(fullscreen).toBeEnabled();
  await fullscreen.click();
  const viewer = page.getByTestId('fullscreen-preview');
  await expect(viewer.getByTestId('expanded-preview-image')).toBeVisible();
  await expect(viewer.getByTestId('expanded-preview-image')).toHaveJSProperty('naturalWidth', 160);
  await viewer.getByTestId('fullscreen-preview-close').click();
  await expect(viewer).toHaveCount(0);
});
