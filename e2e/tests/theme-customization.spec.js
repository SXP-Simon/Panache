const path = require('node:path');
const { test, expect, openHome, fillText, useSmallCanvas, expectPreviewImageLoaded } = require('./fixtures');
const screenshots = path.resolve(__dirname, '../../preview_outputs/theme-customization');

test('default blue accents keep light and dark workspaces neutral', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await openHome(page);
  await useSmallCanvas(page, { fontSize: 31, lineSpacing: 47 });
  await page.getByTestId('paper-settings-toggle').click();
  await fillText(page, 'Panache 手写工作台\n\n同一张纸，同一种笔迹。\n试写一段文字，看看它落在纸上的样子。');
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  const palette = () => page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    return {
      background: getComputedStyle(document.body).backgroundColor,
      primary: root.getPropertyValue('--primary').trim(),
      secondary: root.getPropertyValue('--secondary').trim(),
      card: getComputedStyle(document.querySelector('[data-slot="card"]')).backgroundColor,
    };
  });
  const light = await palette();
  const icons = page.locator('[data-slot="card-icon"]');
  await expect(icons).toHaveCount(3);
  const lightAccent = await icons.first().evaluate((icon) => getComputedStyle(icon).backgroundColor);
  expect(lightAccent).not.toBe('rgba(0, 0, 0, 0)');
  expect(light).toEqual({
    background: 'rgb(255, 255, 255)', primary: '#3c96ca',
    secondary: '#2f86bd', card: 'rgb(255, 255, 255)',
  });
  await page.screenshot({ path: path.join(screenshots, 'web-default-light.png') });
  await page.getByTestId('theme-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  const darkAccent = await icons.first().evaluate((icon) => getComputedStyle(icon).backgroundColor);
  expect(darkAccent).not.toBe(lightAccent);
  expect(darkAccent).not.toBe('rgba(0, 0, 0, 0)');
  await expect.poll(palette).toEqual({
    background: 'rgba(0, 0, 0, 0.42)', primary: '#5ba4d4',
    secondary: '#4a95c4', card: 'rgba(0, 0, 0, 0.18)',
  });
  await expect(page.getByTestId('preview-image')).toBeVisible();
  await page.screenshot({ path: path.join(screenshots, 'web-default-dark.png') });

  const wiring = await page.evaluate(() => {
    const read = () => {
      const background = (selector) => getComputedStyle(document.querySelector(selector)).backgroundColor;
      return {
        primary: background('[data-testid="preview-btn"]'),
        secondary: background('[data-testid="generate-image-btn"]'),
        primaryCard: background('[data-tone="primary"] [data-slot="card-icon"]'),
        secondaryCard: background('[data-tone="secondary"] [data-slot="card-icon"]'),
        fileField: background('[data-slot="file-field"]'),
      };
    };
    const root = document.documentElement;
    const baseline = read();
    root.style.setProperty('--primary', '#da6734');
    const primary = read();
    root.style.removeProperty('--primary');
    root.style.setProperty('--secondary', '#a77dac');
    const secondary = read();
    root.style.removeProperty('--secondary');
    return { baseline, primary, secondary };
  });
  for (const key of ['primary', 'primaryCard']) {
    expect(wiring.primary[key]).not.toBe(wiring.baseline[key]);
    expect(wiring.secondary[key]).toBe(wiring.baseline[key]);
  }
  for (const key of ['secondary', 'secondaryCard', 'fileField']) {
    expect(wiring.secondary[key]).not.toBe(wiring.baseline[key]);
    expect(wiring.primary[key]).toBe(wiring.baseline[key]);
  }
});

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
  await page.getByTestId('theme-secondary-color-hex').fill('#538577');
  await page.getByTestId('theme-secondary-color-apply').click();
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--secondary'))).toBe('#538577');
  await page.screenshot({ path: path.join(screenshots, 'web-mobile-settings.png') });
  await page.getByTestId('appearance-modal-close').click();
  await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
  await expect(page.getByTestId('ink-color-input')).toHaveValue(ink);
  await page.screenshot({ path: path.join(screenshots, 'web-mobile-effect.png') });
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存');
  await page.reload();
  await expect(page.getByTestId('text-input')).toContainText('Panache');
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary'))).toBe('#8b5cf6');
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--secondary'))).toBe('#538577');
  await page.getByTestId('mobile-settings-btn').click();
  await expect(page.getByTestId('theme-color-hex')).toHaveValue('#8b5cf6');
  await expect(page.getByTestId('theme-secondary-color-hex')).toHaveValue('#538577');
  await page.getByTestId('settings-theme-toggle').click();
  await page.getByTestId('appearance-modal-close').click();
  await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.screenshot({ path: path.join(screenshots, 'web-desktop-dark.png') });
  await page.getByTestId('appearance-btn').click();
  await page.getByTestId('theme-color-reset').click();
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--primary'))).toBe('');
  await expect(page.getByTestId('theme-secondary-color-hex')).toHaveValue('#538577');
  await page.getByTestId('theme-secondary-color-reset').click();
  await expect(page.getByTestId('theme-secondary-color-hex')).toHaveValue('#2f86bd');
  expect(await page.locator('html').evaluate((el) => el.style.getPropertyValue('--secondary'))).toBe('');
});

test('color picker supports extreme colors with readable primary labels', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
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
      const contrast = () => page.getByTestId('theme-color-apply').evaluate((button) => {
        const ctx = document.createElement('canvas').getContext('2d');
        const style = getComputedStyle(button);
        const luminance = (paint) => {
          ctx.clearRect(0, 0, 1, 1);
          ctx.fillStyle = paint;
          ctx.fillRect(0, 0, 1, 1);
          const channels = [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3).map((value) => {
            const srgb = value / 255;
            return srgb <= 0.04045 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
          });
          return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        };
        const foreground = luminance(style.color);
        const background = luminance(style.backgroundColor);
        return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
      });
      await expect.poll(contrast, { message: `${dark ? 'dark' : 'light'} theme with ${color}` }).toBeGreaterThanOrEqual(4.5);
    }
  }
});
for (const damagedColor of [undefined, 'broken-color', '#a3f635']) {
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
    await expect(page.getByTestId('theme-color-hex')).toHaveValue('#3c96ca');
    await expect(page.getByTestId('theme-secondary-color-hex')).toHaveValue('#2f86bd');
    await expect(page.getByTestId('message-error')).toHaveCount(0);
  });
}
