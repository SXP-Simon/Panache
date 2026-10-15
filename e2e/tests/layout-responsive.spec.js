const { test, expect, openHome, fillText } = require('./fixtures');

async function metrics(page) {
  return page.evaluate(() => {
    const panels = ['text-panel', 'preview-panel', 'settings-panel'].map((id) => {
      const element = document.querySelector(`[data-testid="${id}"]`);
      const bounds = element.getBoundingClientRect();
      return { left: Math.round(bounds.left), top: Math.round(bounds.top), width: bounds.width };
    });
    return { panels, overflow: document.documentElement.scrollWidth > innerWidth + 1 };
  });
}

for (const viewport of [
  { width: 1440, height: 900, mode: 'desktop' },
  { width: 1024, height: 768, mode: 'tablet' },
  { width: 390, height: 844, mode: 'mobile' },
  { width: 320, height: 740, mode: 'narrow mobile' },
]) {
  test(`${viewport.mode}: panels stay usable without horizontal overflow`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openHome(page);
    await fillText(page, 'A'.repeat(1000) + '\n' + '中文公式 $x^2$ '.repeat(30));
    const symbolLayout = await page.getByTestId('symbol-strip').evaluate((strip) => {
      const label = strip.querySelector('[data-testid="symbol-strip-label"]');
      const text = document.createRange();
      text.selectNodeContents(label);
      return {
        lines: new Set([...text.getClientRects()].map((rect) => Math.round(rect.top))).size,
        labelWrap: getComputedStyle(label).whiteSpace,
        overflow: strip.scrollWidth > strip.clientWidth + 1,
        symbols: strip.querySelectorAll('button').length,
      };
    });
    expect(symbolLayout).toEqual({ lines: 1, labelWrap: 'nowrap', overflow: false, symbols: 16 });
    const layout = await metrics(page);
    expect(layout.overflow).toBe(false);
    expect(layout.panels.every((panel) => panel.width >= 260)).toBe(true);
    if (viewport.mode === 'desktop') {
      for (const id of ['generate-image-btn', 'generate-pdf-btn', 'save-settings-btn']) {
        const bounds = await page.getByTestId(id).boundingBox();
        expect(bounds.y + bounds.height).toBeLessThanOrEqual(viewport.height);
      }
      const input = await page.getByTestId('text-input').boundingBox();
      expect(input.height).toBeLessThanOrEqual(360);
      await expect(page.getByTestId('width-input')).not.toBeVisible();
      expect(new Set(layout.panels.map((panel) => panel.left)).size).toBe(3);
      expect(new Set(layout.panels.map((panel) => panel.top)).size).toBe(1);
    } else if (viewport.mode === 'tablet') {
      expect(layout.panels[0].top).toBe(layout.panels[1].top);
      expect(layout.panels[2].top).toBeGreaterThan(layout.panels[0].top);
    } else {
      expect(new Set(layout.panels.map((panel) => panel.left)).size).toBe(1);
      expect(layout.panels[1].top).toBeGreaterThan(layout.panels[0].top);
      expect(layout.panels[2].top).toBeGreaterThan(layout.panels[0].top);
      expect(layout.panels[1].top).toBeGreaterThan(layout.panels[2].top);
    }
    await page.getByTestId('language-toggle').click();
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    expect((await metrics(page)).overflow).toBe(false);
  });
}
