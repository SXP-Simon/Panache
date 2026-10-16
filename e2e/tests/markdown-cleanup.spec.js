const { test, expect, openHome } = require('./fixtures');

test('manual page breaks and blank lines remain until explicit Markdown cleanup', async ({ page }) => {
  await openHome(page);
  const input = page.getByTestId('text-input');
  const text = '# 第一段\n\n---\n \t\n第二段\n前---后\n-1\n![插图 1|50%]';
  await input.fill(text);
  await input.press('End');
  await input.press('Enter');
  await input.press('Enter');
  await input.pressSequentially('---');
  const manual = text + '\n\n---';
  await expect(input).toHaveValue(manual);
  await page.reload();
  await expect(input).toHaveValue(manual);
  await page.getByTestId('clean-markdown-btn').click();
  await expect(input).toHaveValue('第一段\n第二段\n前---后\n-1\n![插图 1|50%]');
  await input.press('End');
  await input.press('Enter');
  await input.press('Enter');
  await input.pressSequentially('---');
  await expect(input).toHaveValue('第一段\n第二段\n前---后\n-1\n![插图 1|50%]\n\n---');
});
