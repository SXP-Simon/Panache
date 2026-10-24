const fs = require('node:fs/promises');
const path = require('node:path');
const { test, expect, openHome, openPaperSettings, expectPreviewImageLoaded } = require('./fixtures');
const OUTPUT = path.resolve(__dirname, '../../preview_outputs/paper-alignment');

const cases = [
  { name: 'thin', ink: '#708792', paper: '#fffdf5', thickness: 1, angle: 0 },
  { name: 'thick', ink: '#46535a', paper: '#ffffff', thickness: 9, angle: 0 },
  { name: 'pale', ink: '#d0d7cf', paper: '#f2f4ee', thickness: 2, angle: 0 },
  { name: 'tilted-positive', ink: '#8294a5', paper: '#f8f3e7', thickness: 2, angle: 4, margin: true },
  { name: 'tilted-negative', ink: '#99a69a', paper: '#f3f6ed', thickness: 3, angle: -6 },
  { name: 'near-top', ink: '#a0afbf', paper: '#fffdf6', thickness: 2, angle: 0, first: 22 },
];

async function paper(page, options) {
  const encoded = await page.evaluate((options) => {
    const canvas = document.createElement('canvas');
    canvas.width = 800; canvas.height = 1000;
    const context = canvas.getContext('2d');
    context.fillStyle = options.paper;
    context.fillRect(0, 0, 800, 1000);
    context.translate(400, 500); context.rotate(options.angle * Math.PI / 180); context.translate(-400, -500);
    context.strokeStyle = options.ink; context.lineWidth = options.thickness;
    for (let y = options.first ?? 80; y < 920; y += 70) {
      context.beginPath(); context.moveTo(60, y); context.lineTo(740, y); context.stroke();
    }
    if (options.margin) {
      context.strokeStyle = '#d59d9b'; context.lineWidth = 2;
      context.beginPath(); context.moveTo(48, 50); context.lineTo(48, 950); context.stroke();
    }
    return canvas.toDataURL('image/png').split(',')[1];
  }, options);
  return { name: `${options.name}.png`, mimeType: 'image/png', buffer: Buffer.from(encoded, 'base64') };
}

async function uploadAndDetect(page, file) {
  await page.getByTestId('background-image-input').setInputFiles(file);
  const response = page.waitForResponse((r) => r.url().includes('/api/imagefileprocess'));
  await page.getByTestId('detect-background-confirm').click();
  const result = await response;
  expect(result.status()).toBe(200);
  const detected = await result.json();
  await expect(page.getByTestId('message-info')).toContainText('纸张已识别对齐');
  return detected;
}

for (const options of cases) {
  test(`真实横线纸识别、对齐、重识别与出图：${options.name}`, async ({ page }) => {
    await page.addInitScript(() => {
      if (localStorage.getItem('paper.seeded')) return;
      localStorage.setItem('studio.settings', JSON.stringify({
        font_size: 36, line_spacing: 190, font: '云烟体.ttf',
        font_size_sigma: 0, line_spacing_sigma: 0, word_spacing_sigma: 1,
        perturb_x_sigma: 0.5, perturb_y_sigma: 0.5, perturb_theta_sigma: 0.01,
        strikethrough_probability: 0, ink_depth_sigma: 0,
      }));
      localStorage.setItem('paper.seeded', '1');
    });
    await openHome(page);
    await openPaperSettings(page);
    const source = await paper(page, options);
    const detected = await uploadAndDetect(page, source);
    expect(Math.abs(detected.lineSpacing - 70)).toBeLessThanOrEqual(2);
    await expect(page.getByTestId('margin-top-input')).toHaveValue(String(detected.layoutTopMargin));
    expect(Math.abs(detected.layoutTopMargin + detected.lineSpacing - detected.firstBaseline)).toBeLessThanOrEqual(1);
    expect(Boolean(detected.correctedBackground)).toBe(Boolean(options.angle));
    const firstSettings = await Promise.all(['margin-top-input', 'margin-left-input', 'line-spacing-input'].map((id) => page.getByTestId(id).inputValue()));
    const rerun = page.waitForResponse((r) => r.url().includes('/api/imagefileprocess'));
    await page.getByTestId('redetect-background-btn').click();
    const repeated = await (await rerun).json();
    expect(repeated.correctedBackground).toBeUndefined();
    await expect(page.getByTestId('message-info')).toContainText('纸张已识别对齐');
    const afterSettings = await Promise.all(['margin-top-input', 'margin-left-input', 'line-spacing-input'].map((id) => page.getByTestId(id).inputValue()));
    for (const [index, value] of firstSettings.entries()) expect(Math.abs(Number(value) - Number(afterSettings[index]))).toBeLessThanOrEqual(2);
    await page.getByTestId('text-input').fill([
      '数值分析 · 作业练习',
      '一、复合梯形公式',
      '区间 [0, 1]，步长 h = 1/n。',
      '取 f(x) = x²，计算积分近似值。',
      'I = ∫₀¹ x² dx = ⅓',
      '二、误差与收敛性',
      '增加分段数，观察误差的变化。',
      'n = 10，20，40，80',
      '误差逐渐减小，结果趋近 ⅓。',
      '英文记录：accuracy & stability',
      '检查每一行与纸张横线的位置。',
    ].join('\n'));
    await page.getByTestId('font-select').selectOption('云烟体.ttf');
    await page.getByTestId('font-size-input').fill('36');
    await page.reload();
    await openPaperSettings(page);
    await expect(page.getByTestId('margin-top-input')).toHaveValue(afterSettings[0]);
    const submitted = page.waitForRequest((r) => r.url().endsWith('/api/generate_handwriting') && r.method() === 'POST');
    await page.getByTestId('preview-btn').click();
    const form = (await submitted).postDataBuffer().toString('utf8');
    expect(form).toContain('name="background_ruled"\r\n\r\ntrue');
    await expectPreviewImageLoaded(page);
    await fs.mkdir(OUTPUT, { recursive: true });
    await fs.writeFile(path.join(OUTPUT, `web-${options.name}-input.png`), source.buffer);
    const image = page.getByTestId('preview-image');
    const bytes = await image.evaluate(async (node) => Array.from(new Uint8Array(await (await fetch(node.src)).arrayBuffer())));
    await fs.writeFile(path.join(OUTPUT, `web-${options.name}-render.png`), Buffer.from(bytes));
    await fs.writeFile(path.join(OUTPUT, `web-${options.name}-measurements.json`), JSON.stringify({ detected: { ...detected, correctedBackground: Boolean(detected.correctedBackground) }, repeated }, null, 2));
    await page.screenshot({ path: path.join(OUTPUT, `web-${options.name}-ui.png`), fullPage: true });
  });
}

test('识别期间手动修改参数，旧结果不覆盖；重新识别可再次应用', async ({ page }) => {
  await openHome(page); await openPaperSettings(page);
  const file = await paper(page, cases[0]);
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  await page.route('**/api/imagefileprocess', async (route) => {
    await gate;
    await route.fulfill({ json: { marginLeft: 60, marginRight: 60, marginTop: 80, marginBottom: 100, lineSpacing: 70 } });
  });
  await page.getByTestId('background-image-input').setInputFiles(file);
  const request = page.waitForRequest('**/api/imagefileprocess');
  await page.getByTestId('detect-background-confirm').click();
  await request;
  try {
    await expect(page.getByTestId('modal')).toHaveCount(0);
    await expect(page.getByTestId('redetect-background-btn')).toBeDisabled();
    await page.getByTestId('line-spacing-input').fill('123');
    await page.getByTestId('line-spacing-input').press('Tab');
    await expect(page.getByTestId('line-spacing-input')).toHaveValue('123');
  } finally { release(); }
  await expect(page.getByTestId('redetect-background-btn')).toBeEnabled();
  await expect(page.getByTestId('line-spacing-input')).toHaveValue('123');
  await page.getByTestId('redetect-background-btn').click();
  await expect(page.getByTestId('line-spacing-input')).toHaveValue('70');
  await expect(page.getByTestId('margin-top-input')).toHaveValue('10');
  await expect(page.getByTestId('font-size-input')).toHaveValue('50');
  await expect(page.getByTestId('message-info')).toContainText('过大的字号已缩小');
});

test('校正图损坏时不替换背景或任何参数', async ({ page }) => {
  await openHome(page); await openPaperSettings(page);
  const previous = await page.getByTestId('line-spacing-input').inputValue();
  await page.route('**/api/imagefileprocess', (route) => route.fulfill({ json: {
    marginLeft: 60, marginRight: 60, marginTop: 80, marginBottom: 100, lineSpacing: 70,
    correctedBackground: 'bm90IGEgcG5n', imageWidth: 800, imageHeight: 1000,
  } }));
  await page.getByTestId('background-image-input').setInputFiles(await paper(page, cases[0]));
  await page.getByTestId('detect-background-confirm').click();
  await expect(page.getByTestId('message-info')).toHaveClass(/status-message--error/);
  await expect(page.getByTestId('line-spacing-input')).toHaveValue(previous);
  await expect(page.locator('.background-row')).toContainText('thin.png');
});

test('换背景时丢弃旧识别，并清除横线网格标记', async ({ page }) => {
  await openHome(page); await openPaperSettings(page);
  await page.getByTestId('font-size-input').fill('36');
  await uploadAndDetect(page, await paper(page, cases[0]));
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  await page.route('**/api/imagefileprocess', async (route) => {
    await gate;
    await route.fulfill({ json: { marginLeft: 999, marginRight: 60, marginTop: 80, marginBottom: 100, lineSpacing: 777 } });
  });
  const pending = page.waitForRequest('**/api/imagefileprocess');
  await page.getByTestId('redetect-background-btn').click();
  await pending;
  try {
    await page.getByTestId('background-image-input').setInputFiles(await paper(page, cases[2]));
    await page.getByTestId('detect-background-cancel').click();
    await expect(page.getByTestId('modal')).toHaveCount(0);
  } finally { release(); }
  await expect(page.getByTestId('redetect-background-btn')).toBeEnabled();
  await expect(page.getByTestId('line-spacing-input')).toHaveValue('70');
  await expect(page.locator('.background-row')).toContainText('pale.png');
  await page.getByTestId('text-input').fill('新背景仍可使用');
  const submitted = page.waitForRequest((r) => r.url().endsWith('/api/generate_handwriting') && r.method() === 'POST');
  await page.getByTestId('preview-btn').click();
  expect((await submitted).postDataBuffer().toString('utf8')).toContain('name="background_ruled"\r\n\r\nfalse');
  await expectPreviewImageLoaded(page);
});

for (const theme of ['light', 'dark']) {
  test(`移动端重新识别入口清晰且不溢出：${theme}`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.addInitScript((theme) => {
      localStorage.setItem('studio.theme', theme);
      localStorage.setItem('studio.locale', theme === 'light' ? 'en' : 'cn');
    }, theme);
    await openHome(page); await openPaperSettings(page);
    await page.getByTestId('background-image-input').setInputFiles(await paper(page, cases[2]));
    await page.getByTestId('detect-background-confirm').click();
    await expect(page.getByTestId('message-info')).toContainText(theme === 'light' ? 'Paper aligned' : '纸张已识别对齐');
    await expect(page.getByTestId('redetect-background-btn')).toBeEnabled();
    await expect(page.getByTestId('font-size-input')).toHaveValue('50');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await fs.mkdir(OUTPUT, { recursive: true });
    await page.getByTestId('settings-panel').screenshot({ path: path.join(OUTPUT, `web-mobile-${theme}-settings.png`) });
  });
}
