const fs = require('node:fs/promises');
const path = require('node:path');
const { test, expect, openHome, openPaperSettings, expectPreviewImageLoaded } = require('./fixtures');
const OUTPUT = path.resolve(__dirname, '../../preview_outputs/homework-layout');

const assignment = String.raw`# 离散数学 · 推理与证明
1. 推理：从一组已知命题出发，依据推理规则得出新命题的思维过程。
2. 前提：推理中作为依据的已知命题。
3. 结论：由前提推导出的命题。
4. 推理定律
(1) 附加律：A ⇒ A∨B
(2) 化简律：A∧B ⇒ A，A∧B ⇒ B
(3) 假言推理：(A→B)∧A ⇒ B
(4) 拒取式：(A→B)∧¬B ⇒ ¬A
(5) 析取三段论：(A∨B)∧¬A ⇒ B
(6) 假言三段论：(A→B)∧(B→C) ⇒ (A→C)
(7) 等价三段论：(A↔B)∧(B↔C) ⇒ (A↔C)
(8) 构造性二难：(A→B)∧(C→D)∧(A∨C) ⇒ (B∨D)
(9) 破坏性二难：(A→B)∧(C→D)∧(¬B∨¬D) ⇒ (¬A∨¬C)
第二题：数值积分
令 $f(x)=x^2$，在区间 $[0,1]$ 上验证积分。
$$I=\int_0^1 x^2\,dx=\frac13$$
复合公式：$T_n=\frac{h}{2}(f(x_0)+2f(x_1)+2f(x_2)+2f(x_3)+f(x_4))$。
嵌套分式：$R=\frac{1}{1+\frac{x+1}{x+2}}$，分子、分母和上下标应保持完整。
检查单位：$v=3.5\,\mathrm{m/s}$，误差 $E_n=I-T_n$。
第三题：结论
增加节点数，观察结果变化。英文说明：convergence and numerical stability.
保留用户自己输入的段落与换行，不需要手动补空格。`;

async function seed(page, extra = {}) {
  await page.addInitScript((extra) => {
    if (localStorage.getItem('homework.seeded')) return;
    localStorage.setItem('studio.settings', JSON.stringify({
      width: 1200, height: 1697, font_size: 46, line_spacing: 82,
      top_margin: 28, bottom_margin: 64, left_margin: 35, right_margin: 35,
      font: '云烟体.ttf', underlined: true, fullPreview: true,
      line_spacing_sigma: 0, font_size_sigma: 0.6, word_spacing_sigma: 0.7,
      perturb_x_sigma: 0.6, perturb_y_sigma: 0.6, perturb_theta_sigma: 0.012,
      strikethrough_probability: 0, ink_depth_sigma: 0,
      ...extra,
    }));
    localStorage.setItem('homework.seeded', '1');
  }, extra);
}

async function generate(page, name, style) {
  await page.getByTestId('layout-style-select').selectOption(style);
  const request = page.waitForRequest((r) => r.url().endsWith('/api/generate_handwriting') && r.method() === 'POST');
  await page.getByTestId('preview-btn').click();
  const form = (await request).postDataBuffer().toString('utf8');
  expect(form).toContain(`name="layout_style"\r\n\r\n${style}`);
  await expectPreviewImageLoaded(page);
  await fs.mkdir(OUTPUT, { recursive: true });
  let index = 1;
  do {
    const bytes = await page.getByTestId('preview-image').evaluate(async (image) =>
      Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())));
    await fs.writeFile(path.join(OUTPUT, `${name}-page-${index}.png`), Buffer.from(bytes));
    if (await page.getByTestId('preview-next-btn').isDisabled()) break;
    const previous = await page.getByTestId('preview-image').getAttribute('src');
    await page.getByTestId('preview-next-btn').click();
    await expect(page.getByTestId('preview-image')).not.toHaveAttribute('src', previous);
    await expect.poll(() => page.getByTestId('preview-image').evaluate((image) => image.complete && image.naturalWidth > 0)).toBe(true);
    index++;
    expect(index).toBeLessThan(10);
  } while (true);
  while (!(await page.getByTestId('preview-prev-btn').isDisabled())) await page.getByTestId('preview-prev-btn').click();
  return { form, pages: index };
}

test('同一份真实作业在标准和作业笔记模式下出图，切换不改原文与字体', async ({ page }) => {
  await seed(page);
  await openHome(page);
  await page.getByTestId('text-input').fill(assignment);
  await page.getByTestId('prepare-text-btn').click();
  await expect(page.getByTestId('prepare-text-undo')).toBeVisible();
  const prepared = await page.getByTestId('text-input').inputValue();
  expect(prepared).not.toContain('\\frac');
  expect(prepared).toContain('假言三段论');
  await generate(page, 'web-standard', 'standard');
  const notebook = await generate(page, 'web-homework', 'homework');
  expect(notebook.pages).toBeGreaterThanOrEqual(2);
  await expect(page.getByTestId('text-input')).toHaveValue(prepared);
  await expect(page.getByTestId('font-select')).toHaveValue('云烟体.ttf');
  await expect(page.getByTestId('font-size-input')).toHaveValue('46');
  await expect(page.getByTestId('layout-preset-help')).toContainText('条目自动缩进');
  await fs.writeFile(path.join(OUTPUT, 'web-assignment-source.txt'), assignment);
  await fs.writeFile(path.join(OUTPUT, 'web-assignment-prepared.txt'), prepared);
  await page.screenshot({ path: path.join(OUTPUT, 'web-homework-ui.png'), fullPage: true });
});

test('作业笔记随草稿和预设保存，旧预设明确回退标准模式', async ({ page }) => {
  await seed(page);
  await openHome(page);
  const text = '1. 原文保持不变。\n(1) (A→B)∧(B→C)⇒(A→C)';
  await page.getByTestId('text-input').fill(text);
  await page.getByTestId('layout-style-select').selectOption('homework');
  await page.getByTestId('save-settings-btn').click();
  await expect(page.getByTestId('message-info')).toContainText('保存成功');
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存到本机');
  await page.reload();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('homework');
  await page.getByTestId('layout-style-select').selectOption('standard');
  await page.getByTestId('load-settings-btn').click();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('homework');
  await expect(page.getByTestId('text-input')).toHaveValue(text);
  await page.evaluate(() => {
    const preset = JSON.parse(localStorage.getItem('studio.preset'));
    const configuration = JSON.parse(preset.configuration);
    delete configuration.layoutStyle;
    preset.configuration = JSON.stringify(configuration);
    localStorage.setItem('studio.preset', JSON.stringify(preset));
  });
  await page.getByTestId('load-settings-btn').click();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('standard');
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存到本机');
  await page.reload();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('standard');
  await page.getByTestId('reset-settings-btn').click();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('standard');
});

test('上传浅色横线背景后仍可启用作业笔记，切换保留识别参数', async ({ page }) => {
  await seed(page);
  await openHome(page);
  await openPaperSettings(page);
  const encoded = await page.evaluate(() => {
    const canvas = document.createElement('canvas'); canvas.width = 1200; canvas.height = 1697;
    const ctx = canvas.getContext('2d'); ctx.fillStyle = '#fffdf6'; ctx.fillRect(0, 0, 1200, 1697);
    ctx.strokeStyle = '#c4c9c4'; ctx.lineWidth = 2;
    for (let y = 110; y < 1630; y += 82) { ctx.beginPath(); ctx.moveTo(35, y); ctx.lineTo(1165, y); ctx.stroke(); }
    ctx.strokeStyle = '#e1bab3'; ctx.beginPath(); ctx.moveTo(28, 65); ctx.lineTo(28, 1630); ctx.stroke();
    return canvas.toDataURL('image/png').split(',')[1];
  });
  await page.getByTestId('background-image-input').setInputFiles({ name: 'ruled-note.png', mimeType: 'image/png', buffer: Buffer.from(encoded, 'base64') });
  await page.getByTestId('detect-background-confirm').click();
  await expect(page.getByTestId('message-info')).toContainText('纸张已识别对齐');
  const ids = ['margin-top-input', 'margin-left-input', 'line-spacing-input', 'font-size-input'];
  const values = await Promise.all(ids.map((id) => page.getByTestId(id).inputValue()));
  await page.getByTestId('text-input').fill(assignment);
  await page.getByTestId('prepare-text-btn').click();
  await expect(page.getByTestId('prepare-text-undo')).toBeVisible();
  const { form } = await generate(page, 'web-uploaded-homework', 'homework');
  expect(form).toContain('name="background_ruled"\r\n\r\ntrue');
  expect(form).not.toContain('name="width"');
  for (const [i, id] of ids.entries()) await expect(page.getByTestId(id)).toHaveValue(values[i]);
  await page.getByTestId('layout-style-select').selectOption('standard');
  for (const [i, id] of ids.entries()) await expect(page.getByTestId(id)).toHaveValue(values[i]);
  await page.getByTestId('layout-style-select').selectOption('homework');
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存到本机');
  await page.reload();
  await expect(page.getByTestId('layout-style-select')).toHaveValue('homework');
});

for (const theme of ['light', 'dark']) {
  test(`移动端作业笔记设置入口：${theme}`, async ({ page }) => {
    await seed(page, { layoutStyle: 'homework' });
    await page.setViewportSize({ width: 390, height: 844 });
    if (theme === 'light') await page.addInitScript(() => localStorage.setItem('studio.locale', 'en'));
    await openHome(page);
    if (theme === 'dark') {
      await page.getByTestId('mobile-settings-btn').click();
      await page.getByTestId('settings-theme-toggle').click();
      await page.getByTestId('appearance-modal-close').click();
      await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
    }
    await expect(page.getByTestId('layout-style-select')).toHaveValue('homework');
    await expect(page.getByTestId('layout-preset-help')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await fs.mkdir(OUTPUT, { recursive: true });
    await page.getByTestId('settings-panel').screenshot({ path: path.join(OUTPUT, `web-mobile-${theme}-settings.png`) });
  });
}
