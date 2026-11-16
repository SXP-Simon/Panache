const { test: base, expect } = require('@playwright/test');

// 2026-10-15：阻止测试请求外站，真实应用接口仍连接本机 FastAPI。
async function blockThirdParty(page) {
  await page.route(/^https?:\/\/(?!127\.0\.0\.1|localhost)/, (route) => route.abort());
}

const test = base.extend({
  page: async ({ page }, use) => {
    await blockThirdParty(page);
    await use(page);
  },
});

// 打开首页并等字体列表就绪（生成请求要靠它取 font_option，没加载完就点会报错）
async function openHome(page) {
  await page.goto('/');
  await expect(page.getByTestId('preview-btn')).toBeVisible();
  await expect(page.getByTestId('font-select').locator('option')).not.toHaveCount(0);
  await page.evaluate(() => document.fonts.ready);
}

async function fillText(page, text) {
  await page.getByTestId('text-input').fill(text);
}

async function setNumber(page, testId, value) {
  await page.getByTestId(testId).fill(String(value));
}

async function openPaperSettings(page) {
  if (!(await page.getByTestId('width-input').isVisible()))
    await page.getByTestId('paper-settings-toggle').click();
}

// 小画布 + 短文本，真实渲染约 2 秒
async function useSmallCanvas(page, { fontSize = 50, lineSpacing = 60 } = {}) {
  await openPaperSettings(page);
  await setNumber(page, 'width-input', 400);
  await setNumber(page, 'height-input', 300);
  await setNumber(page, 'font-size-input', fontSize);
  await setNumber(page, 'line-spacing-input', lineSpacing);
  await setNumber(page, 'margin-top-input', 20);
  await setNumber(page, 'margin-bottom-input', 20);
  await setNumber(page, 'margin-left-input', 20);
  await setNumber(page, 'margin-right-input', 20);
}

// 等真实生成的 PNG 预览完成，不以占位画布作为成功条件。
async function expectPreviewImageLoaded(page, timeout = 90_000) {
  await expect(page.getByTestId('message-info')).toContainText('预览图像已加载', { timeout });
  const image = page.getByTestId('preview-image');
  await expect(image).toHaveAttribute('src', /^(blob:|data:image\/png)/);
  await expect
    .poll(() => image.evaluate((el) => el.naturalWidth), { timeout: 30_000 })
    .toBeGreaterThan(0);
}


async function previewPng(page) {
  return page.getByTestId('preview-image').evaluate(async (image) => {
    await image.decode();
    const layer = image.parentElement.querySelector('[data-testid="preview-ink-layer"]');
    if (!layer) return [...new Uint8Array(await (await fetch(image.src)).arrayBuffer())];

    const style = getComputedStyle(layer);
    const maskUrl = style.maskImage.slice(5, -2);
    const mask = await createImageBitmap(await (await fetch(maskUrl)).blob());
    const canvas = new OffscreenCanvas(image.naturalWidth, image.naturalHeight);
    const context = canvas.getContext('2d');
    context.fillStyle = style.backgroundColor;
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.globalCompositeOperation = 'destination-in';
    context.drawImage(mask, 0, 0);
    mask.close();
    const output = new OffscreenCanvas(canvas.width, canvas.height);
    const composite = output.getContext('2d');
    composite.drawImage(image, 0, 0);
    composite.globalAlpha = Number(style.opacity);
    composite.drawImage(canvas, 0, 0);
    return [...new Uint8Array(await (await output.convertToBlob()).arrayBuffer())];
  });
}


module.exports = {
  test,
  expect,
  blockThirdParty,
  openHome,
  fillText,
  setNumber,
  useSmallCanvas,
  openPaperSettings,
  expectPreviewImageLoaded,
  previewPng,
};
