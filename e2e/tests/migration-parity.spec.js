const fs = require('fs');
const path = require('path');
const { test, expect, openHome, fillText, useSmallCanvas } = require('./fixtures');

test('legacy camelCase settings and myPreset migrate without losing text or font', async ({
  page,
}) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('audit.seeded')) return;
    const entries = {
      fontSize: 42,
      lineSpacing: 64,
      width: 600,
      height: 800,
      marginTop: 20,
      marginBottom: 20,
      marginLeft: 20,
      marginRight: 20,
      wordSpacing: 2,
      lineSpacingSigma: 0.5,
      selectedOption: '2',
      fill: '(24, 77, 50, 255)',
      isUnderlined: false,
      enableEnglishSpacing: true,
      enableFullPreview: true,
      text: '旧版草稿',
      selectedTextFileName: 'legacy.txt',
      markdownTableMode: 'aligned',
    };
    for (const [key, value] of Object.entries(entries))
      localStorage.setItem(key, JSON.stringify(value));
    localStorage.setItem(
      'myPreset',
      JSON.stringify({ ...entries, text: '旧预设备份', fontSize: 55, fontFile: null }),
    );
    localStorage.setItem('audit.seeded', '1');
  });
  await openHome(page);
  await expect(page.getByTestId('font-size-input')).toHaveValue('42');
  await expect(page.getByTestId('line-spacing-input')).toHaveValue('64');
  await expect(page.getByTestId('ink-color-input')).toHaveValue('#184d32');
  await expect(page.getByTestId('text-input')).toHaveValue('旧版草稿');
  await expect(page.getByTestId('text-file-name')).toHaveText('legacy.txt');
  await expect(page.getByTestId('underlined-checkbox')).not.toBeChecked();
  await expect(page.getByTestId('english-spacing-checkbox')).toBeChecked();
  await expect(page.getByTestId('full-preview-checkbox')).toBeChecked();
  await expect(page.getByTestId('markdown-table-mode')).toHaveValue('aligned');
  const secondFont = await page
    .getByTestId('font-select')
    .locator('option')
    .nth(1)
    .getAttribute('value');
  await expect(page.getByTestId('font-select')).toHaveValue(secondFont);
  await page.getByTestId('font-size-input').fill('43');
  await page.reload();
  await expect(page.getByTestId('font-size-input')).toHaveValue('43');
  await expect(page.getByTestId('full-preview-checkbox')).toBeChecked();
  await page.getByTestId('load-settings-btn').click();
  await expect(page.getByTestId('font-size-input')).toHaveValue('55');
  await expect(page.getByTestId('text-input')).toHaveValue('旧预设备份');
  await page.getByTestId('save-settings-btn').click();
  await fillText(page, '临时改写');
  await page.getByTestId('load-settings-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue('旧预设备份');
});

test('built-in small preset keeps every original handwriting value', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('english-spacing-checkbox').check();
  await page.getByTestId('builtin-preset-select').selectOption('smallUnderlined');
  for (const [id, value] of Object.entries({
    'font-size-input': 70,
    'line-spacing-input': 100,
    'word-spacing-input': 2,
    'margin-top-input': 150,
    'margin-bottom-input': 150,
    'margin-left-input': 150,
    'margin-right-input': 150,
    'line-spacing-sigma-input': 1,
    'font-size-sigma-input': 1,
    'word-spacing-sigma-input': 2,
    'perturb-x-sigma-input': 1,
    'perturb-y-sigma-input': 1,
    'perturb-theta-sigma-input': 0.05,
    'strikethrough-probability-input': 0,
    'strikethrough-width-input': 8,
  }))
    await expect(page.getByTestId(id)).toHaveValue(String(value));
  await expect(page.getByTestId('underlined-checkbox')).toBeChecked();
  await expect(page.getByTestId('english-spacing-checkbox')).not.toBeChecked();
});

test('reset removes background and uploaded font and preset cannot override a background', async ({
  page,
}) => {
  await openHome(page);
  const initialFont = await page.getByTestId('font-select').inputValue();
  await useSmallCanvas(page);
  const font = path.join(__dirname, '..', '..', 'backend', 'font_assets', '云烟体.ttf');
  await page.getByTestId('font-file-input').setInputFiles({
    name: 'reset-upload.ttf',
    mimeType: 'font/ttf',
    buffer: fs.readFileSync(font),
  });
  await page
    .getByTestId('background-image-input')
    .setInputFiles(path.join(__dirname, '..', 'fixtures', 'sample-page.png'));
  await page.getByTestId('detect-background-cancel').click();
  await page.getByTestId('builtin-preset-select').selectOption('smallUnderlined');
  await expect(page.getByTestId('font-size-input')).toHaveValue('50');
  await expect(page.getByTestId('message-info')).toContainText('先移除背景');
  await page.getByTestId('reset-settings-btn').click();
  await expect(page.getByTestId('width-input')).toBeEnabled();
  await expect(page.getByTestId('font-size-input')).toHaveValue('124');
  await expect(page.getByTestId('font-select')).toHaveValue(initialFont);
  await expect(
    page.getByTestId('font-select').locator('option[value="reset-upload.ttf"]'),
  ).toHaveCount(0);
});

test('multi-line letter ending can be restored to body and edited text invalidates undo', async ({
  page,
}) => {
  await openHome(page);
  const original = '亲爱的妈妈：\n最近一切都好。';
  await fillText(page, original);
  await page.getByTestId('letter-format-btn').click();
  await page.getByTestId('letter-signature-input').fill('你的孩子\n小明');
  await page.getByTestId('letter-date-input').fill('2026年10月15日');
  await page.getByTestId('letter-apply-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue(/>>>你的孩子\n>>>小明/);
  await page.getByTestId('letter-format-btn').click();
  await expect(page.getByTestId('letter-signature-input')).toHaveValue('你的孩子\n小明');
  await page.getByTestId('letter-restore-btn').click();
  await expect(page.getByTestId('letter-signature-input')).toHaveValue('');
  await expect(page.getByTestId('letter-preview')).toContainText('小明');
  await page.getByTestId('letter-apply-btn').click();
  await page.getByTestId('letter-undo-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue(original);
  await page.getByTestId('letter-format-btn').click();
  await page.getByTestId('letter-apply-btn').click();
  await page.getByTestId('text-input').press('End');
  await page.getByTestId('text-input').press('X');
  await expect(page.getByTestId('letter-undo-btn')).toHaveCount(0);
});

test('inline preview supports original 700% scale and image paste', async ({ page }) => {
  await openHome(page);
  await fillText(page, '插图粘贴');
  const image = fs
    .readFileSync(path.join(__dirname, '..', 'fixtures', 'inline-mark.png'))
    .toString('base64');
  await page.getByTestId('text-input').evaluate((element, data) => {
    const bytes = Uint8Array.from(atob(data), (char) => char.charCodeAt(0));
    const transfer = new DataTransfer();
    transfer.items.add(new File([bytes], 'pasted.png', { type: 'image/png' }));
    element.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, clipboardData: transfer }));
  }, image);
  await expect(page.getByTestId('text-input')).toHaveValue(/!\[插图 1\]/);
  await page.getByTestId('inline-image-preview-1').click();
  const dialog = page.getByTestId('image-preview-modal');
  await expect(dialog.getByRole('img')).toBeVisible();
  await page.getByTestId('image-scale-700').click();
  await expect(page.getByTestId('active-scale-badge')).toHaveText('700%');
  await page.getByTestId('scale-slider').fill('20');
  await expect(page.getByTestId('active-scale-badge')).toHaveText('20%');
  await page.getByTestId('modal-close-btn').click();
  await expect(page.getByTestId('text-input')).toHaveValue(/!\[插图 1\|20%\]/);
});

test('quick symbol inserts at selection and keeps the following typed character beside it', async ({
  page,
}) => {
  await openHome(page);
  await fillText(page, 'abcdef');
  await page.getByTestId('text-input').evaluate((element) => element.setSelectionRange(3, 3));
  await page.getByTestId('quick-symbol-α').click();
  await expect(page.getByTestId('text-input')).toBeFocused();
  await page.keyboard.type('Z');
  await expect(page.getByTestId('text-input')).toHaveValue('abcαZdef');
});

test('table mode and full preview remain selected after reload', async ({ page }) => {
  await openHome(page);
  await page.getByTestId('markdown-table-mode').selectOption('raw_pipe');
  await page.getByTestId('full-preview-checkbox').check();
  await page.reload();
  await expect(page.getByTestId('markdown-table-mode')).toHaveValue('raw_pipe');
  await expect(page.getByTestId('full-preview-checkbox')).toBeChecked();
});

test('queue counts and push/polling messages stay visible', async ({ page }) => {
  await page.route('**/api/generate_handwriting', (route) =>
    route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ task_id: 'audit-queued' }),
    }),
  );
  let socket;
  await page.routeWebSocket('**/api/generate_handwriting/ws/**', (connection) => {
    socket = connection;
    connection.send(
      JSON.stringify({
        task_status: 'pending',
        task_message: '正在排队',
        task_progress: 12,
        queue_ahead_count: 4,
        queue_pending_count: 6,
        processing_count: 2,
      }),
    );
  });
  await page.route('**/api/generate_handwriting/task/audit-queued', (route) =>
    route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        task_status: 'pending',
        task_message: '轮询正在等待',
        task_progress: 25,
        queue_ahead_count: 3,
        queue_pending_count: 5,
        processing_count: 2,
      }),
    }),
  );
  await openHome(page);
  await fillText(page, '队列状态');
  await page.getByTestId('preview-btn').click();
  const message = page.getByTestId('message-info');
  await expect(message).toContainText('前方排队 4');
  await expect(message).toContainText('当前排队 6');
  await expect(message).toContainText('处理中 2');
  await expect(page.locator('progress')).toHaveAttribute('value', '12');
  await socket.close();
  await expect(message).toContainText('轮询正在等待');
  await expect(message).toContainText('前方排队 3');
  await expect(page.locator('progress')).toHaveAttribute('value', '25');
});

test('legacy DOC/RTF file choices retain their actual backend behavior', async ({ page }) => {
  await openHome(page);
  const input = page.getByTestId('text-file-input');
  await expect(input).toHaveAttribute('accept', '.doc,.docx,.pdf,.txt,.rtf');
  await input.setInputFiles({
    name: 'legacy.rtf',
    mimeType: 'application/rtf',
    buffer: Buffer.from('RTF legacy text import'),
  });
  await expect(page.getByTestId('text-input')).toHaveValue('RTF legacy text import');
  await input.setInputFiles({
    name: 'legacy.doc',
    mimeType: 'application/msword',
    buffer: Buffer.from('legacy DOC placeholder'),
  });
  await expect(page.getByTestId('text-input')).toHaveValue('doc文件暂不支持');
});
