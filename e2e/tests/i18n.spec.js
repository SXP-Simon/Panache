const { test, expect, openHome, fillText } = require('./fixtures');

test('语言与主题切换即时生效并在刷新后保留草稿', async ({ page }) => {
  await openHome(page);
  await fillText(page, '语言主题不会清空我的草稿');
  await page.getByTestId('language-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await expect(page.getByTestId('preview-btn')).toHaveText('Generate preview');
  await expect(page.getByTestId('markdown-table-mode').locator('option').first()).toHaveText(
    'Tables: item list',
  );
  await page.getByTestId('theme-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await expect(page.getByTestId('text-input')).toHaveValue('语言主题不会清空我的草稿');
  await page.getByTestId('language-toggle').click();
  await page.getByTestId('theme-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
});
