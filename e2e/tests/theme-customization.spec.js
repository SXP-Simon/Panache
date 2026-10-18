const path = require('node:path');
const { test, expect, openHome, fillText } = require('./fixtures');
const screenshots = path.resolve(__dirname, '../../preview_outputs/theme-customization');

test('mobile appearance edits persist and stay separate from paper ink', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.setViewportSize({ width: 390, height: 844 });
  await openHome(page);
  await expect(page.getByTestId('app-header')).not.toBeVisible();
  const panel = await page.getByTestId('text-panel').boundingBox();
  expect(panel.y).toBeLessThan(85);
  const ink = await page.getByTestId('ink-color-input').inputValue();
  await fillText(page, 'Panache · 自定义配色\n界面随心，纸张与笔迹保持原样。');
  await page.getByTestId('mobile-settings-btn').click();
  await page.getByTestId('theme-color-hex').fill('#xyz');
  await page.getByTestId('theme-color-apply').click();
  await expect(page.getByRole('alert')).toBeVisible();
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary'))).toBe('');
  await page.getByTestId('theme-color-hex').fill('#8b5cf6');
  await page.getByTestId('theme-color-apply').click();
  await expect(page.getByRole('alert')).toHaveCount(0);
  await page.screenshot({ path: path.join(screenshots, 'web-mobile-settings.png') });
  await page.getByTestId('appearance-modal-close').click();
  await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
  await expect(page.getByTestId('ink-color-input')).toHaveValue(ink);
  await page.screenshot({ path: path.join(screenshots, 'web-mobile-effect.png') });
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存');
  await page.reload();
  await expect(page.getByTestId('text-input')).toContainText('Panache');
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary'))).toBe('#8b5cf6');
  await page.getByTestId('mobile-settings-btn').click();
  await expect(page.getByTestId('theme-color-hex')).toHaveValue('#8b5cf6');
  await page.getByTestId('settings-theme-toggle').click();
  await page.getByTestId('appearance-modal-close').click();
  await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.screenshot({ path: path.join(screenshots, 'web-desktop-dark.png') });
  await page.getByTestId('appearance-btn').click();
  await page.getByTestId('theme-color-reset').click();
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary'))).toBe('');
});

test('color picker supports extreme colors with readable primary labels', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('appearance-btn').click();
  for (const dark of [false, true]) {
    if (dark) await page.getByTestId('settings-theme-toggle').click();
    for (const color of ['#000000', '#ffffff', '#ffff00', '#123456']) {
      await page.getByTestId('theme-color-picker').evaluate((input, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }, color);
      await expect(page.getByTestId('theme-color-hex')).toHaveValue(color);
      const foreground = await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary-foreground'));
      expect(foreground).toBe(color === '#000000' || color === '#123456' ? '#ffffff' : '#000000');
    }
  }
});
for (const damagedColor of [undefined, 'broken-color']) {
  test(`legacy workspace remains intact with theme color ${damagedColor}`, async ({ page }) => {
    await openHome(page);
    await fillText(page, '主题迁移保留草稿');
    await expect(page.getByTestId('draft-save-status')).toContainText('已保存');
    await page.addInitScript((color) => {
      const record = JSON.parse(localStorage.getItem('studio.workspace'));
      if (color === undefined) delete record.preferences.themeColor;
      else record.preferences.themeColor = color;
      localStorage.setItem('studio.workspace', JSON.stringify(record));
    }, damagedColor);
    await page.reload();
    await expect(page.getByTestId('text-input')).toHaveValue('主题迁移保留草稿');
    await page.getByTestId('appearance-btn').click();
    await expect(page.getByTestId('theme-color-hex')).toHaveValue('#a3f635');
    await expect(page.getByTestId('message-error')).toHaveCount(0);
  });
}
