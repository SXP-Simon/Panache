const { test, expect, openHome, fillText, openPaperSettings } = require('./fixtures');

async function expectUnifiedFont(page) {
  const violations = await page.evaluate(() =>
    [...document.querySelectorAll('body *')]
      .filter((element) => {
        const style = getComputedStyle(element);
        const visible =
          element.getClientRects().length &&
          style.visibility !== 'hidden' &&
          style.display !== 'none';
        const hasText = [...element.childNodes].some(
          (node) => node.nodeType === Node.TEXT_NODE && node.textContent.trim(),
        );
        return (
          visible &&
          (hasText || element.matches('input,textarea,select,button,dialog,pre,code,kbd,samp'))
        );
      })
      .map((element) => ({
        tag: element.tagName,
        testId: element.getAttribute('data-testid'),
        font: getComputedStyle(element).fontFamily,
      }))
      .filter((item) => item.font.replaceAll(/["']/g, '').trim() !== 'LXGW WenKai'),
  );
  expect(violations, 'Every visible UI text and control must inherit LXGW WenKai').toEqual([]);
}

for (const width of [1440, 390]) {
  for (const language of ['cn', 'en']) {
    for (const theme of ['light', 'dark']) {
      test(`all UI modules use WenKai: ${width}px ${language} ${theme}`, async ({ page }) => {
        await page.setViewportSize({ width, height: 900 });
        await page.addInitScript(
          ({ language, theme }) => {
            localStorage.setItem('studio.locale', language);
            localStorage.setItem('studio.theme', theme);
          },
          { language, theme },
        );
        await openHome(page);
        const loaded = await page.evaluate(
          async () => (await document.fonts.load('16px "LXGW WenKai"', '中文English0123')).length,
        );
        expect(loaded, 'The self-hosted WenKai font must actually load').toBeGreaterThan(0);
        await openPaperSettings(page);
        await page.getByTestId('variation-settings-toggle').click();
        await page.getByTestId('strike-settings-toggle').click();
        await expectUnifiedFont(page);
        if (width <= 720) {
          await page.getByTestId('mobile-settings-btn').click();
          await expectUnifiedFont(page);
          await page.getByTestId('settings-guide-btn').click();
        } else await page.getByTestId('guide-btn').click();
        await expectUnifiedFont(page);
        await page.keyboard.press('Escape');
        await expect(page.getByTestId('modal')).toHaveCount(0);
        await fillText(page, '亲爱的朋友：\nHello from 手写工作室。');
        await page.evaluate(() => document.fonts.load('16px "LXGW WenKai"', '亲爱的朋友 Hello'));
        const session = await page.context().newCDPSession(page);
        await session.send('DOM.enable');
        await session.send('CSS.enable');
        const documentNode = await session.send('DOM.getDocument');
        const renderedFonts = [];
        for (const selector of [
          ...(width > 720 ? ['h1', '[data-testid="brand-title"]', '[data-testid="project-source-link"]'] : ['[data-testid="mobile-settings-btn"]']),
          '[data-testid="quick-symbol-α"]',
          '[data-testid="text-input"]',
        ]) {
          const node = await session.send('DOM.querySelector', {
            nodeId: documentNode.root.nodeId,
            selector,
          });
          const rendered = await session.send('CSS.getPlatformFontsForNode', {
            nodeId: node.nodeId,
          });
          renderedFonts.push(...rendered.fonts.filter((font) => font.glyphCount > 0));
        }
        expect(renderedFonts.length).toBeGreaterThanOrEqual(width <= 720 ? 2 : 3);
        expect(
          renderedFonts.filter((font) => font.familyName !== 'LXGW WenKai' || !font.isCustomFont),
        ).toEqual([]);
        await session.detach();
        await page.getByTestId('letter-format-btn').click();
        await expectUnifiedFont(page);
        await expect(page.getByTestId('letter-signature-input')).toBeVisible();
        await page.keyboard.press('Escape');
        await expect(page.getByTestId('letter-dialog')).toHaveCount(0);
        expect(
          await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1),
        ).toBe(false);
      });
    }
  }
}
