const fs = require('fs');
const path = require('path');
const {
  test,
  expect,
  openHome,
  fillText,
  useSmallCanvas,
  expectPreviewImageLoaded,
} = require('./fixtures');

test.describe('文本文件上传', () => {
  test('上传 txt 后自动填充正文并显示文件名', async ({ page }) => {
    await openHome(page);

    await page
      .getByTestId('text-file-input')
      .setInputFiles(path.join(__dirname, '..', 'fixtures', 'sample-letter.txt'));

    await expect(page.getByTestId('text-input')).toHaveValue(/这是一份用于端到端测试的文本文件。/);
    await expect(page.getByTestId('text-file-name')).toHaveText('sample-letter.txt');
  });
});

const pdfBuffer = Buffer.from(
  'JVBERi0xLjcKJcK1wrYKCjEgMCBvYmoKPDwvVHlwZS9DYXRhbG9nL1BhZ2VzIDIgMCBSPj4KZW5kb2JqCgoyIDAgb2JqCjw8L1R5cGUvUGFnZXMvQ291bnQgMS9LaWRzWzQgMCBSXT4+CmVuZG9iagoKMyAwIG9iago8PC9Gb250PDwvaGVsdiA1IDAgUj4+Pj4KZW5kb2JqCgo0IDAgb2JqCjw8L1R5cGUvUGFnZS9NZWRpYUJveFswIDAgMzAwIDIwMF0vUm90YXRlIDAvUmVzb3VyY2VzIDMgMCBSL1BhcmVudCAyIDAgUi9Db250ZW50c1s2IDAgUl0+PgplbmRvYmoKCjUgMCBvYmoKPDwvVHlwZS9Gb250L1N1YnR5cGUvVHlwZTEvQmFzZUZvbnQvSGVsdmV0aWNhL0VuY29kaW5nL1dpbkFuc2lFbmNvZGluZz4+CmVuZG9iagoKNiAwIG9iago8PC9MZW5ndGggMTE3L0ZpbHRlci9GbGF0ZURlY29kZT4+CnN0cmVhbQp42h2LsQoCQRBD+/mK+QNncnOZWxCLAxs7YTuxUNzFQgsbv9/1CITkkchH1iquNuSKYTStb9k92+ur7lq7XvazRQRhLHyksScyttYyODMT9JEKOxvsz3LKmG5j4+gEDPfBp/TtueSCgna41pMcq5zlB8oMHeoKZW5kc3RyZWFtCmVuZG9iagoKeHJlZgowIDcKMDAwMDAwMDAwMCAwMDAwMSBmIAowMDAwMDAwMDE2IDAwMDAwIG4gCjAwMDAwMDAwNjIgMDAwMDAgbiAKMDAwMDAwMDExNCAwMDAwMCBuIAowMDAwMDAwMTU1IDAwMDAwIG4gCjAwMDAwMDAyNjIgMDAwMDAgbiAKMDAwMDAwMDM1MSAwMDAwMCBuIAoKdHJhaWxlcgo8PC9TaXplIDcvUm9vdCAxIDAgUi9JRFs8NzVCQkU5ODQ0NzlEMzhEMUExMEYwNzhFNjI2Nzk5RTk+PDRBM0M2N0M4ODkyNEI4NjBFMTk4RDlFNzdBRjRGQTYxPl0+PgpzdGFydHhyZWYKNTM3CiUlRU9GCg==',
  'base64',
);
for (const [extension, text] of [
  ['docx', 'DOCX import integration test'],
  ['pdf', 'PDF import integration test'],
]) {
  test(`真实 ${extension} 导入解析正文`, async ({ page }) => {
    await openHome(page);
    await page.getByTestId('text-file-input').setInputFiles(
      extension === 'pdf'
        ? {
            name: 'sample-document.pdf',
            mimeType: 'application/pdf',
            buffer: pdfBuffer,
          }
        : path.join(__dirname, '..', 'fixtures', `sample-document.${extension}`),
    );
    await expect(page.getByTestId('text-input')).toHaveValue(new RegExp(text));
    await expect(page.getByTestId('text-file-name')).toHaveText(`sample-document.${extension}`);
  });
}

test('上传字体随真实生成请求发送并出图', async ({ page }) => {
  await openHome(page);
  await useSmallCanvas(page);
  await fillText(page, '上传字体 Font 123');
  const font = path.join(__dirname, '..', '..', 'backend', 'font_assets', '云烟体.ttf');
  await page.getByTestId('font-file-input').setInputFiles({
    name: 'custom-upload.ttf',
    mimeType: 'font/ttf',
    buffer: fs.readFileSync(font),
  });
  await expect(page.getByTestId('font-select')).toHaveValue('custom-upload.ttf');
  for (const language of ['en', 'zh-CN']) {
    const refreshed = page.waitForResponse((response) =>
      response.url().endsWith('/api/fonts_info'),
    );
    await page.getByTestId('language-toggle').click();
    await refreshed;
    await expect(page.locator('html')).toHaveAttribute('lang', language);
    await expect(page.getByTestId('font-select')).toHaveValue('custom-upload.ttf');
    await expect(
      page.getByTestId('font-select').locator('option[value="custom-upload.ttf"]'),
    ).toHaveCount(1);
  }
  const submitted = page.waitForRequest(
    (request) => request.url().endsWith('/api/generate_handwriting') && request.method() === 'POST',
  );
  await page.getByTestId('preview-btn').click();
  const request = await submitted;
  expect(request.postDataBuffer().toString('utf8')).toContain('name="font_file"; filename="');
  await expectPreviewImageLoaded(page);
});
