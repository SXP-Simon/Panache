const { test, expect, openHome, fillText } = require('./fixtures');

test('modal keyboard focus stays inside and Escape restores the opener', async ({ page }) => {
  await openHome(page);
  await fillText(page, '亲爱的朋友：\n祝好！');
  const opener = page.getByTestId('letter-format-btn');
  await opener.click();
  const dialog = page.getByTestId('letter-dialog');
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAccessibleName('书信排版');
  for (let index = 0; index < 18; index++) {
    await page.keyboard.press(index < 9 ? 'Tab' : 'Shift+Tab');
    expect(await dialog.evaluate((element) => element.contains(document.activeElement))).toBe(true);
  }
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(opener).toBeFocused();
  await expect(page.getByTestId('text-input')).toHaveValue('亲爱的朋友：\n祝好！');
});

test('dialog content clicks keep it open and backdrop click closes it', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openHome(page);
  const opener = page.getByTestId('guide-btn');
  await opener.click();
  const dialog = page.getByRole('dialog');
  await page.getByTestId('modal-title').click();
  await expect(dialog).toBeVisible();
  await page.mouse.click(5, 5);
  await expect(dialog).toHaveCount(0);
  await expect(opener).toBeFocused();
});
