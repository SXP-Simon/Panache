const { test, expect, openHome } = require('./fixtures');

async function toggleHeights(page, testId, frames = 32) {
  return page.getByTestId(testId).evaluate(async (button, count) => {
    const content = document.getElementById(button.getAttribute('aria-controls'));
    const heights = [];
    button.click();
    for (let frame = 0; frame < count; frame += 1) {
      await new Promise(requestAnimationFrame);
      heights.push(content.getBoundingClientRect().height);
    }
    return heights;
  }, frames);
}

for (const testId of [
  'paper-settings-toggle',
  'variation-settings-toggle',
  'strike-settings-toggle',
]) {
  test(`${testId} animates real intermediate heights when opening and closing`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await openHome(page);
    const toggle = page.getByTestId(testId);
    const content = page.getByTestId(`${testId}-content`);
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await expect(content).toBeHidden();
    const opening = await toggleHeights(page, testId);
    await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    const fullHeight = await content.evaluate((element) => element.scrollHeight);
    expect(fullHeight).toBeGreaterThan(20);
    expect(opening.some((height) => height > 1 && height < fullHeight - 1)).toBe(true);
    const closing = await toggleHeights(page, testId);
    expect(closing.some((height) => height > 1 && height < fullHeight - 1)).toBe(true);
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await expect(content).toHaveAttribute('aria-hidden', 'true');
    await expect(content).toHaveCSS('height', '0px');
    await expect(content).toHaveCSS('visibility', 'hidden');
  });
}

test('rapid accordion reversals preserve values and finish in the requested state', async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await openHome(page);
  const toggle = page.getByTestId('paper-settings-toggle');
  await toggle.click();
  await page.getByTestId('width-input').fill('471');
  await toggle.evaluate(async (button) => {
    for (let index = 0; index < 8; index += 1) {
      button.click();
      await new Promise(requestAnimationFrame);
      await new Promise(requestAnimationFrame);
    }
  });
  await expect(toggle).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByTestId('width-input')).toBeVisible();
  await expect(page.getByTestId('width-input')).toHaveValue('471');
  await toggle.click();
  await expect(page.getByTestId('paper-settings-toggle-content')).toHaveCSS('visibility', 'hidden');
  await toggle.click();
  await expect(page.getByTestId('width-input')).toBeVisible();
  await expect(page.getByTestId('width-input')).toHaveValue('471');
});

test('collapsing settings immediately prevents programmatic and keyboard focus inside', async ({
  page,
}) => {
  await openHome(page);
  const toggle = page.getByTestId('paper-settings-toggle');
  const content = page.getByTestId('paper-settings-toggle-content');
  const width = page.getByTestId('width-input');
  await toggle.click();
  await width.focus();
  await expect(width).toBeFocused();
  await toggle.click();
  expect(
    await width.evaluate((element) => {
      element.focus();
      return document.activeElement === element;
    }),
  ).toBe(false);
  await toggle.focus();
  for (let index = 0; index < 6; index += 1) {
    await page.keyboard.press('Tab');
    expect(await content.evaluate((element) => element.contains(document.activeElement))).toBe(
      false,
    );
  }
});

test('reduced motion opens and closes settings without intermediate animation frames', async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await openHome(page);
  const content = page.getByTestId('paper-settings-toggle-content');
  const opening = await toggleHeights(page, 'paper-settings-toggle', 4);
  const fullHeight = await content.evaluate((element) => element.scrollHeight);
  expect(opening.slice(1).every((height) => Math.abs(height - fullHeight) <= 1)).toBe(true);
  const closing = await toggleHeights(page, 'paper-settings-toggle', 4);
  expect(closing.slice(1).every((height) => height <= 1)).toBe(true);
  await expect(content).toHaveCSS('visibility', 'hidden');
});

test('modal exit stays mounted while fading and restores focus after removal', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await openHome(page);
  const opener = page.getByTestId('guide-btn');
  await opener.click();
  const dialog = page.getByTestId('modal');
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveCSS('opacity', '1');
  const states = await page.getByTestId('modal-close').evaluate(async (button) => {
    const element = button.closest('dialog');
    button.click();
    const result = [];
    for (let frame = 0; frame < 32 && element.isConnected; frame += 1) {
      await new Promise(requestAnimationFrame);
      result.push({
        connected: element.isConnected,
        present: element.dataset.present,
        open: element.open,
        opacity: Number(getComputedStyle(element).opacity),
      });
    }
    return result;
  });
  expect(states.some((state) => state.connected && state.present === 'false' && state.open)).toBe(
    true,
  );
  expect(states.some((state) => state.connected && state.opacity > 0 && state.opacity < 1)).toBe(
    true,
  );
  await expect(dialog).toHaveCount(0);
  await expect(opener).toBeFocused();
});

test('reduced motion removes a modal promptly and restores its opener', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await openHome(page);
  const opener = page.getByTestId('guide-btn');
  await opener.click();
  const dialog = page.getByTestId('modal');
  await expect(dialog).toBeVisible();
  const remains = await page.getByTestId('modal-close').evaluate(async (button) => {
    const element = button.closest('dialog');
    button.click();
    await new Promise(requestAnimationFrame);
    await new Promise(requestAnimationFrame);
    return element.isConnected;
  });
  expect(remains).toBe(false);
  await expect(opener).toBeFocused();
});

test('typing during letter dialog exit cannot restore stale form state or reopen it', async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await openHome(page);
  await page.getByTestId('text-input').fill('亲爱的朋友：\n最近一切都好。');
  const opener = page.getByTestId('letter-format-btn');
  await opener.click();
  const dialog = page.getByTestId('letter-dialog');
  await page.getByTestId('letter-signature-input').focus();
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveAttribute('data-present', 'false');
  expect(await dialog.evaluate((element) => element.inert)).toBe(true);
  await page.keyboard.type('x');
  await expect(dialog).toHaveCount(0);
  await expect(opener).toBeFocused();
  await expect(page.getByTestId('text-input')).toHaveValue('亲爱的朋友：\n最近一切都好。');
});
