const path = require('path');
const {
  test,
  expect,
  openHome,
  fillText,
  useSmallCanvas,
  expectPreviewImageLoaded,
} = require('./fixtures');

test('inline image upload, scale, reload, expanded request and removal', async ({ page }) => {
  await openHome(page);
  await useSmallCanvas(page);
  await fillText(page, '正文中的插图');
  await page.getByTestId('text-input').focus();
  await page.getByTestId('text-input').press('End');
  await page
    .getByTestId('inline-image-input')
    .setInputFiles(path.join(__dirname, '..', 'fixtures', 'inline-mark.png'));
  const text = page.getByTestId('text-input');
  await expect(text).toHaveValue(/!\[插图 1\]/);
  await expect(text).not.toHaveValue(/data:image/);
  const scale = page.getByRole('slider');
  await scale.fill('150');
  await expect(text).toHaveValue(/!\[插图 1\|150%\]/);
  await page.reload();
  await expect(text).toHaveValue(/!\[插图 1\|150%\]/);
  const submitted = page.waitForRequest(
    (request) => request.url().endsWith('/api/generate_handwriting') && request.method() === 'POST',
  );
  await page.getByTestId('preview-btn').click();
  const body = (await submitted).postDataBuffer().toString('utf8');
  expect(body).toContain('data:image/png;base64,');
  expect(body).toContain('150%');
  await expectPreviewImageLoaded(page);
  await page.getByRole('button', { name: '删除插图', exact: true }).click();
  await expect(text).not.toHaveValue(/!\[插图/);
  await expect(scale).toHaveCount(0);
});
