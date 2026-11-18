const { test, expect, openHome } = require('./fixtures');

test('外观与设置里的版本号来自后端', async ({ page }) => {
  await openHome(page);
  await expect(page.getByTestId('app-version')).toHaveCount(0);
  await page.getByTestId('appearance-btn').click();
  const updates = page.getByTestId('appearance-modal').getByTestId('update-settings');
  await expect(updates.getByTestId('app-version')).toHaveText(/^v\d+\.\d+\.\d+$/);
});

test('指南和桌面下载入口使用有效对话框', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('guide-btn').click();
  const guide = page.getByRole('dialog');
  await expect(guide).toBeVisible();
  await expect(guide).toHaveAccessibleName('在这里，让文字变成笔迹');
  await page.keyboard.press('Escape');
  await page.getByTestId('desktop-download-btn').click();
  const desktop = page.getByRole('dialog');
  await expect(desktop).toHaveAccessibleName('桌面版');
  await expect(desktop.getByRole('link')).toHaveAttribute(
    'href',
    'https://github.com/SXP-Simon/Panache/releases',
  );
  await expect(desktop.getByRole('link')).toHaveAttribute('rel', /noopener/);
});
