const { test, expect, openHome } = require('./fixtures');

for (const width of [320, 390, 768, 1440]) {
  for (const locale of ['cn', 'en']) {
    test(`header source link is visible without scrolling: ${width}px ${locale}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await page.addInitScript((language) => localStorage.setItem('studio.locale', language), locale);
      await openHome(page);
      const link = page.getByTestId('project-source-link');
      await expect(link).toHaveText('SXP-Simon/handwriting-web');
      await expect(link).toHaveAttribute('href', 'https://github.com/SXP-Simon/handwriting-web');
      await expect(link).toHaveAttribute('target', '_blank');
      await expect(link).toBeInViewport();
      const bounds = await link.boundingBox();
      expect(bounds.x).toBeGreaterThanOrEqual(0);
      expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
      expect(bounds.y + bounds.height).toBeLessThan(120);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      if (locale === 'cn' && (width === 320 || width === 1440)) {
        await page.screenshot({ path: test.info().outputPath('header.png') });
      }
    });
  }
}
