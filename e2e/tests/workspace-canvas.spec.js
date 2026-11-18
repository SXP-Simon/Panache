const { test, expect } = require('./fixtures');

test('wide workspace docks panels beside the tools and warns only for a long all-page preview', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 950 });
  await page.goto('/');

  const previewPanel = page.getByTestId('preview-panel');
  await expect(previewPanel.getByTestId('preview-btn')).toBeVisible();
  await expect(previewPanel.getByTestId('live-preview-toggle')).toBeVisible();
  const live = page.getByTestId('live-preview-toggle').getByRole('checkbox');
  await live.uncheck();
  await page.getByTestId('canvas-pane-paper').click();
  await page.getByTestId('width-input').fill('720');
  await page.getByTestId('height-input').fill('960');
  const paper = page.getByTestId('paper-style-dots');
  await paper.check();
  await page.getByTestId('canvas-pane-layout').click();
  const latinFont = page.getByTestId('latin-font-select');
  await latinFont.selectOption('kalam');
  const scale = page.getByTestId('latin-font-scale-number');
  await scale.fill('115');
  await expect(page.getByTestId('latin-font-scale')).toHaveValue('115');
  const indent = page.getByTestId('first-line-indent-checkbox');
  const monospaced = page.getByTestId('monospaced-layout-checkbox');
  await indent.check();
  await monospaced.check();
  await page.getByTestId('font-size-input').fill('38');
  await page.getByTestId('line-spacing-input').fill('68');

  const tools = await page.getByTestId('canvas-tools').boundingBox();
  const settings = await page.getByTestId('settings-panel').boundingBox();
  const preview = await page.getByTestId('preview-panel').boundingBox();
  const pageWidth = await page.evaluate(() => document.documentElement.clientWidth);
  expect(settings.x).toBeCloseTo(tools.x + tools.width, 1);
  expect(preview.x).toBeCloseTo(settings.x + settings.width, 1);
  expect(preview.x + preview.width).toBeCloseTo(pageWidth, 1);
  expect(settings.height).toBe(preview.height);

  await page.getByTestId('canvas-pane-edit').click();
  expect(await page.getByTestId('text-panel').boundingBox()).toEqual(settings);
  expect(await page.getByTestId('preview-panel').boundingBox()).toEqual(preview);
  const editor = page.getByTestId('text-input');
  await editor.fill('第一页 Handwriting\n---\n第二页\n---\n第三页');
  const allPages = page.getByTestId('full-preview-checkbox');
  const pageCount = page.getByTestId('preview-page-indicator');
  const hint = page.locator('#long-preview-hint');
  await allPages.check();
  const submitted = page.waitForRequest(
    (request) => request.method() === 'POST' && request.url().endsWith('/api/generate_handwriting'),
  );
  await live.check();
  const form = (await submitted).postData();
  expect(form).toMatch(/name="latin_font_option"\r?\n\r?\nkalam/);
  expect(form).toMatch(/name="latin_font_scale"\r?\n\r?\n115/);
  expect(form).toMatch(/name="paper_pattern"\r?\n\r?\ndots/);
  expect(form).toMatch(/name="first_line_indent"\r?\n\r?\ntrue/);
  expect(form).toMatch(/name="monospaced"\r?\n\r?\ntrue/);
  await expect(pageCount).toHaveText(/1\s*\/\s*3/);
  await expect(hint).toBeHidden();

  await editor.fill('第一页 Handwriting\n---\n第二页\n---\n第三页\n---\n第四页');
  await expect(pageCount).toHaveText(/1\s*\/\s*4/);
  await expect(hint).toBeInViewport();
  await allPages.uncheck();
  await expect(pageCount).toHaveText(/1\s*\/\s*1/);
  await expect(hint).toBeHidden();

  await expect(page.getByTestId('draft-save-status')).toHaveAttribute('data-state', 'saved');
  await page.reload();
  await page.getByTestId('canvas-pane-layout').click();
  await expect(latinFont).toHaveValue('kalam');
  await expect(scale).toHaveValue('115');
  await expect(indent).toBeChecked();
  await expect(monospaced).toBeChecked();
  await page.getByTestId('canvas-pane-paper').click();
  await expect(paper).toBeChecked();
});
