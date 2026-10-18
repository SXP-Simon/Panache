const { test, expect, openHome } = require('./fixtures');

for (const width of [320, 390, 768, 1440]) {
  for (const locale of ['cn', 'en']) {
    test(`source link remains accessible: ${width}px ${locale}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.addInitScript((language) => localStorage.setItem('studio.locale', language), locale);
      await openHome(page);
      await expect(page).toHaveTitle('Panache');
      if (width <= 720) {
        await expect(page.getByTestId('app-header')).not.toBeVisible();
        await page.getByTestId('mobile-settings-btn').click();
      } else await expect(page.getByTestId('brand-title')).toHaveText('Panache');
      const link = page.getByTestId(width <= 720 ? 'settings-project-source-link' : 'project-source-link');
      await expect(link).toHaveText('SXP-Simon/Panache');
      await expect(link).toHaveAttribute('href', 'https://github.com/SXP-Simon/Panache');
      await expect(link).toHaveAttribute('target', '_blank');
      await expect(link).toBeInViewport();
      const bounds = await link.boundingBox();
      expect(bounds.x).toBeGreaterThanOrEqual(0);
      expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
      if (width > 720) expect(bounds.y + bounds.height).toBeLessThan(120);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      if (locale === 'cn' && (width === 320 || width === 1440)) {
        await page.screenshot({ path: test.info().outputPath('header.png') });
      }
    });
  }
}
