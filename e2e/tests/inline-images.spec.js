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
  const scale = page.getByTestId('inline-image-scale-1');
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
  await page.getByTestId('inline-image-remove-1').click();
  await expect(text).not.toHaveValue(/!\[插图/);
  await expect(scale).toHaveCount(0);
});

test('invalid inline image leaves document intact and allows a valid retry', async ({ page }) => {
  await openHome(page);
  await fillText(page, '保留正文');
  const upload = page.getByTestId('inline-image-input');
  await upload.setInputFiles({ name: 'broken.png', mimeType: 'image/png', buffer: Buffer.from('not a picture') });
  await expect(page.getByTestId('inline-image-preview-1')).toHaveCount(0);
  await expect(page.getByTestId('text-input')).toHaveValue('保留正文');
  await expect(page.getByTestId('message-info')).toContainText('无法读取图片');
  await upload.setInputFiles(path.join(__dirname, '..', 'fixtures', 'inline-mark.png'));
  await expect(page.getByTestId('inline-image-preview-1')).toBeVisible();
});

test('batch insertion is atomic and repeated selection can be resized after reload', async ({ page }) => {
  await openHome(page);
  await fillText(page, '正文');
  const upload = page.getByTestId('inline-image-input');
  const valid = path.join(__dirname, '..', 'fixtures', 'inline-mark.png');
  const fs = require('fs');
  await upload.setInputFiles([
    { name: 'valid.png', mimeType: 'image/png', buffer: fs.readFileSync(valid) },
    { name: 'broken.png', mimeType: 'image/png', buffer: Buffer.from('broken') },
  ]);
  await expect(page.getByTestId('message-info')).toContainText('无法读取图片');
  await expect(page.getByTestId('text-input')).toHaveValue('正文');
  await upload.setInputFiles([valid, path.join(__dirname, '..', 'fixtures', 'sample-page.png')]);
  await expect(page.getByTestId('inline-image-preview-2')).toBeVisible();
  await page.getByTestId('inline-image-preview-2').click();
  await page.getByTestId('image-scale-50').click();
  await page.getByTestId('modal-close-btn').click();
  await page.reload();
  await expect(page.getByTestId('text-input')).toHaveValue(/!\[插图 2\|50%\]/);
  await page.getByTestId('inline-image-remove-1').click();
  await expect(page.getByTestId('inline-image-preview-2')).toBeVisible();
});

test('editing while an image is decoding never overwrites newer text', async ({ page }) => {
  await openHome(page);
  await fillText(page, '原文');
  await page.evaluate(() => {
    const decode = Image.prototype.decode;
    Image.prototype.decode = function () {
      return new Promise((resolve, reject) => {
        window.releaseImageDecode = () => decode.call(this).then(resolve, reject);
      });
    };
  });
  await page.getByTestId('inline-image-input').setInputFiles(path.join(__dirname, '..', 'fixtures', 'inline-mark.png'));
  await page.getByTestId('text-input').fill('用户继续输入的新正文');
  await page.evaluate(() => window.releaseImageDecode());
  await expect(page.getByTestId('message-info')).toContainText('正文已更改');
  await expect(page.getByTestId('text-input')).toHaveValue('用户继续输入的新正文');
  await expect(page.getByTestId('inline-image-preview-1')).toHaveCount(0);
});

test('camera-sized images are bounded and temporary URLs are released', async ({ page }) => {
  await openHome(page);
  const bytes = await page.evaluate(() => {
    const create = URL.createObjectURL;
    const revoke = URL.revokeObjectURL;
    window.imageUrls = { created: [], revoked: [] };
    URL.createObjectURL = function (blob) {
      const url = create.call(URL, blob);
      if (blob.type.startsWith('image/')) window.imageUrls.created.push(url);
      return url;
    };
    URL.revokeObjectURL = function (url) {
      window.imageUrls.revoked.push(url);
      revoke.call(URL, url);
    };
    const canvas = document.createElement('canvas');
    canvas.width = 6000;
    canvas.height = 30;
    const context = canvas.getContext('2d');
    context.fillStyle = 'red';
    context.fillRect(0, 0, canvas.width, canvas.height);
    return canvas.toDataURL('image/png').split(',')[1];
  });
  await page.getByTestId('inline-image-input').setInputFiles({ name: 'camera.png', mimeType: 'image/png', buffer: Buffer.from(bytes, 'base64') });
  await expect(page.getByTestId('inline-image-preview-1')).toBeVisible();
  const dimensions = await page.getByTestId('inline-image-preview-1').evaluate((button) => {
    const image = button.querySelector('img');
    return [image.naturalWidth, image.naturalHeight];
  });
  expect(dimensions).toEqual([4000, 20]);
  const urls = await page.evaluate(() => window.imageUrls);
  expect(urls.created.length).toBeGreaterThan(0);
  for (const url of urls.created) expect(urls.revoked).toContain(url);
  await page.getByTestId('inline-image-preview-1').click();
  await page.getByTestId('image-scale-10').click();
  await expect(page.getByTestId('active-scale-badge')).toHaveText('10%');
  await expect(page.getByTestId('text-input')).toHaveValue(/!\[插图 1\|10%\]/);
});
