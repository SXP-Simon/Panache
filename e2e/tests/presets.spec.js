const { test, expect, openHome, setNumber } = require('./fixtures');

test.describe('预设与设置存取', () => {
  test('内置预设：一键套用小字加下划线（云烟体）', async ({ page }) => {
    await openHome(page);
    const presetSelect = page.getByTestId('builtin-preset-select');
    await expect(presetSelect).toBeEnabled();

    await presetSelect.selectOption('smallUnderlined');

    await expect(page.getByText('已应用预设')).toBeVisible();
    await expect(page.getByTestId('font-size-input')).toHaveValue('70');
    await expect(page.getByTestId('width-input')).toHaveValue('2481');
    await expect(page.getByTestId('height-input')).toHaveValue('3507');
    await expect(page.getByTestId('font-select')).toHaveValue('云烟体.ttf');
  });

  test('保存 / 重置 / 载入设置', async ({ page }) => {
    await openHome(page);
    await setNumber(page, 'font-size-input', 123);

    await page.getByTestId('save-settings-btn').click();
    await expect(page.getByText('预设设置保存成功！')).toBeVisible();

    await page.getByTestId('reset-settings-btn').click();
    await expect(page.getByTestId('font-size-input')).toHaveValue('124');

    await page.getByTestId('load-settings-btn').click();
    await expect(page.getByText('预设设置加载成功！')).toBeVisible();
    await expect(page.getByTestId('font-size-input')).toHaveValue('123');
  });

  test('没有保存过设置时载入给出提示', async ({ page }) => {
    await openHome(page);

    await page.getByTestId('load-settings-btn').click();

    await expect(page.getByText('没有找到保存的预设设置')).toBeVisible();
  });
});

test('草稿与参数刷新后保留，损坏预设不会覆盖当前值', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('text-input').fill('自动保存草稿 $x^2$');
  await setNumber(page, 'font-size-input', 99);
  await page.getByTestId('ink-color-input').fill('#184d32');
  await page.getByTestId('english-spacing-checkbox').check();
  await page.reload();
  await expect(page.getByTestId('text-input')).toHaveValue('自动保存草稿 $x^2$');
  await expect(page.getByTestId('font-size-input')).toHaveValue('99');
  await expect(page.getByTestId('ink-color-input')).toHaveValue('#184d32');
  await expect(page.getByTestId('english-spacing-checkbox')).toBeChecked();
  await page.evaluate(() =>
    localStorage.setItem('studio.preset', JSON.stringify({ line_spacing: 0 })),
  );
  await page.getByTestId('load-settings-btn').click();
  await expect(page.getByTestId('message-info')).toContainText('保存的数据无效');
  await expect(page.getByTestId('font-size-input')).toHaveValue('99');
  await expect(page.getByTestId('line-spacing-input')).not.toHaveValue('0');
});
