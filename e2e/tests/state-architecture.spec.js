const fs = require('node:fs');
const path = require('node:path');
const {
  test,
  expect,
  openHome,
  openPaperSettings,
  useSmallCanvas,
  expectPreviewImageLoaded,
} = require('./fixtures');

const fixture = (name) => path.join(__dirname, '..', 'fixtures', name);
const png = fs.readFileSync(fixture('inline-mark.png'));
const dataUrl = `data:image/png;base64,${png.toString('base64')}`;

async function saved(page) {
  await expect(page.getByTestId('draft-save-status')).toContainText('已保存到本机');
}

// Mock only the transport: persisted Files and the submitted FormData still come from the real stores.
async function generationTransport(page, { pending = false } = {}) {
  const forms = [];
  const sockets = new Set();
  let complete = !pending;
  let connections = 0;
  const frame = () => ({
    task_id: 'state-contract-task',
    task_status: complete ? 'completed' : 'processing',
    task_stage: complete ? 'completed' : 'rendering',
    task_progress: complete ? 100 : 25,
    task_message: complete ? '已完成' : '正在恢复生成任务',
    error_message: '',
  });
  await page.route('**/api/generate_handwriting', async (route) => {
    const request = route.request();
    expect(request.method()).toBe('POST');
    forms.push(await new Response(request.postDataBuffer(), {
      headers: { 'content-type': request.headers()['content-type'] },
    }).formData());
    await route.fulfill({ json: { task_id: 'state-contract-task' } });
  });
  await page.route('**/api/generate_handwriting/task/**', async (route) => {
    if (new URL(route.request().url()).pathname.endsWith('/result'))
      await route.fulfill({ contentType: 'image/png', body: png });
    else await route.fulfill({ json: frame() });
  });
  await page.routeWebSocket('**/api/generate_handwriting/ws/**', (socket) => {
    connections++;
    sockets.add(socket);
    socket.onClose(() => sockets.delete(socket));
    socket.send(JSON.stringify(frame()));
  });
  return {
    forms,
    connections: () => connections,
    finish() {
      complete = true;
      for (const socket of sockets) socket.send(JSON.stringify(frame()));
    },
  };
}

test('连续输入和插图刷新后完整恢复，生成仍提交原始图片与末尾文字', async ({ page }) => {
  const transport = await generationTransport(page);
  await openHome(page);
  await useSmallCanvas(page);
  const editor = page.getByTestId('text-input');
  await editor.pressSequentially('连续输入的草稿 English 123\n', { delay: 0 });
  await page.getByTestId('inline-image-input').setInputFiles(fixture('inline-mark.png'));
  await expect(editor).toHaveValue(/!\[插图 1\]/);
  await editor.fill(`${await editor.inputValue()}\n最后一段，不可丢失。`);
  const expected = await editor.inputValue();
  await saved(page);
  await page.reload();
  await expect(editor).toHaveValue(expected);
  await expect(page.locator('.inline-image-row img')).toHaveCount(1);
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  expect(transport.forms).toHaveLength(1);
  expect(transport.forms[0].get('text')).toContain(dataUrl);
  expect(transport.forms[0].get('text')).toContain('最后一段，不可丢失。');
  expect(transport.forms[0].get('text')).not.toMatch(/!\[插图 1\](?!\()/);
});

test('内置字体按名称持久化，刷新与字体列表重排后保持选择', async ({ page }) => {
  let fonts = ['first.ttf', 'chosen.ttf'];
  await page.route('**/api/fonts_info', (route) => route.fulfill({ json: fonts }));
  const transport = await generationTransport(page);
  await openHome(page);
  await page.getByTestId('font-select').selectOption('chosen.ttf');
  await saved(page);
  fonts = ['new-first.ttf', 'first.ttf', 'chosen.ttf'];
  await page.reload();
  await expect(page.getByTestId('font-select')).toHaveValue('chosen.ttf');
  await page.getByTestId('text-input').fill('使用上次选择的字体');
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  expect(transport.forms[0].get('font_option')).toBe('chosen.ttf');

  fonts = ['replacement.ttf'];
  await page.reload();
  await expect(page.getByTestId('font-select')).toHaveValue('replacement.ttf');
  await saved(page);
  await page.reload();
  await expect(page.getByTestId('font-select')).toHaveValue('replacement.ttf');
});

test('上传字体和纸张背景刷新后恢复二进制资源而非仅文件名', async ({ page }) => {
  const transport = await generationTransport(page);
  const fontBytes = fs.readFileSync(path.join(__dirname, '../../backend/font_assets/云烟体.ttf'));
  const backgroundBytes = fs.readFileSync(fixture('sample-page.png'));
  await openHome(page);
  await useSmallCanvas(page);
  await page.getByTestId('text-input').fill('资源恢复后的正文');
  await page.getByTestId('font-file-input').setInputFiles({
    name: 'persisted-upload.ttf', mimeType: 'font/ttf', buffer: fontBytes,
  });
  await page.getByTestId('background-image-input').setInputFiles(fixture('sample-page.png'));
  await page.getByTestId('detect-background-cancel').click();
  await saved(page);
  await page.reload();
  await expect(page.getByTestId('font-select')).toHaveValue('persisted-upload.ttf');
  await openPaperSettings(page);
  await expect(page.getByTestId('width-input')).toBeDisabled();
  await expect(page.getByTestId('height-input')).toBeDisabled();
  await page.getByTestId('preview-btn').click();
  await expectPreviewImageLoaded(page);
  expect(transport.forms).toHaveLength(1);
  const font = transport.forms[0].get('font_file');
  const background = transport.forms[0].get('background_image');
  expect(font.name).toBe('persisted-upload.ttf');
  expect(Buffer.from(await font.arrayBuffer())).toEqual(fontBytes);
  expect(background.name).toBe('sample-page.png');
  expect(Buffer.from(await background.arrayBuffer())).toEqual(backgroundBytes);
});

test('防抖尚未结束立即刷新仍保留最后几个输入字符', async ({ page }) => {
  await openHome(page);
  const editor = page.getByTestId('text-input');
  await editor.fill('已存在的内容');
  await saved(page);
  await editor.press('End');
  await editor.pressSequentially(' 最后输入XYZ987', { delay: 0 });
  // Deliberately do not wait for a saved indicator, network idle or a debounce timer.
  await page.reload();
  await expect(editor).toHaveValue('已存在的内容 最后输入XYZ987');
});

for (const source of ['studio-records', 'camel-case']) {
  test(`旧 ${source} 草稿含插图时迁移并保留参数，后续编辑不被旧值覆盖`, async ({ page }) => {
    await page.addInitScript(({ source, dataUrl }) => {
      if (localStorage.getItem('state.migration.seeded')) return;
      const text = `历史草稿\n![迁移插图](${dataUrl})\n完整末尾`;
      if (source === 'studio-records') {
        localStorage.setItem('studio.draft', JSON.stringify(text));
        localStorage.setItem('studio.settings', JSON.stringify({ font_size: 48, line_spacing: 72, ink: '#184d32', englishSpacing: true }));
      } else {
        for (const [key, value] of Object.entries({ text, fontSize: 48, lineSpacing: 72, fill: '(24,77,50,255)', enableEnglishSpacing: true }))
          localStorage.setItem(key, JSON.stringify(value));
      }
      localStorage.setItem('state.migration.seeded', '1');
    }, { source, dataUrl });
    await openHome(page);
    const editor = page.getByTestId('text-input');
    await expect(editor).toHaveValue(/历史草稿[\s\S]*!\[插图 1\][\s\S]*完整末尾/);
    await expect(page.getByTestId('font-size-input')).toHaveValue('48');
    await expect(page.getByTestId('line-spacing-input')).toHaveValue('72');
    await expect(page.getByTestId('ink-color-input')).toHaveValue('#184d32');
    await expect(page.getByTestId('english-spacing-checkbox')).toBeChecked();
    await editor.fill(`${await editor.inputValue()}\n迁移后的新文字`);
    await saved(page);
    await page.reload();
    await expect(editor).toHaveValue(/!\[插图 1\][\s\S]*迁移后的新文字$/);
    await expect(page.locator('.inline-image-row img')).toHaveCount(1);
  });
}

test('正文和语言更新复用字体版本缓存，切语言不覆盖正在编辑的正文', async ({ page }) => {
  let fonts = 0;
  let versions = 0;
  await page.route('**/api/fonts_info', (route) => {
    fonts++;
    return route.fulfill({ json: ['云烟体.ttf', '华阳手写体.ttf'] });
  });
  await page.route('**/api/version', (route) => {
    versions++;
    return route.fulfill({ json: { version: 'state-cache-test' } });
  });
  await openHome(page);
  const editor = page.getByTestId('text-input');
  await editor.fill('正在编辑的中文 English');
  for (const language of ['en', 'zh-CN']) {
    await page.getByTestId('language-toggle').click();
    await expect(page.locator('html')).toHaveAttribute('lang', language);
    await expect(editor).toHaveValue('正在编辑的中文 English');
    await editor.press('End');
    await editor.pressSequentially('!', { delay: 0 });
    await editor.fill('正在编辑的中文 English');
  }
  await page.waitForLoadState('networkidle');
  expect(fonts).toBe(1);
  expect(versions).toBe(1);
});

test('活跃生成任务刷新后继续观测同一任务，不能重新POST生成', async ({ page }) => {
  const transport = await generationTransport(page, { pending: true });
  await openHome(page);
  await useSmallCanvas(page);
  await page.getByTestId('text-input').fill('仅创建一次的任务');
  await page.getByTestId('preview-btn').click();
  await expect.poll(transport.connections).toBe(1);
  expect(transport.forms).toHaveLength(1);
  await page.reload();
  await expect.poll(transport.connections).toBe(2);
  expect(transport.forms).toHaveLength(1);
  transport.finish();
  await expectPreviewImageLoaded(page);
  expect(transport.forms).toHaveLength(1);
  await expect.poll(() => page.evaluate(() => localStorage.getItem('studio.generation'))).toBeNull();
});

test('记录写入失败明确显示保存失败，当前正文仍然可编辑', async ({ page }) => {
  await openHome(page);
  await page.evaluate(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (key === 'studio.workspace') throw new DOMException('Simulated full disk', 'QuotaExceededError');
      return original.call(this, key, value);
    };
  });
  await page.getByTestId('text-input').fill('保存失败也不能吞掉当前编辑');
  await expect(page.getByTestId('message-info')).toContainText('无法保存到本机，请检查存储权限或可用空间');
  await expect(page.getByTestId('draft-save-status')).not.toContainText('已保存到本机');
  await expect(page.getByTestId('text-input')).toHaveValue('保存失败也不能吞掉当前编辑');
});

test('图片资源写入失败不能把仅内存中的插图误报为已保存', async ({ page }) => {
  await openHome(page);
  await page.evaluate(() => {
    IDBObjectStore.prototype.put = function () {
      throw new DOMException('Simulated asset storage failure', 'QuotaExceededError');
    };
  });
  await page.getByTestId('text-input').fill('图片保存失败的正文');
  await page.getByTestId('inline-image-input').setInputFiles(fixture('inline-mark.png'));
  await expect(page.getByTestId('message-info')).toContainText('无法保存到本机，请检查存储权限或可用空间');
  await expect(page.getByTestId('draft-save-status')).not.toContainText('已保存到本机');
  await expect(page.getByTestId('text-input')).toHaveValue(/图片保存失败的正文/);
});

test('新插图写入失败后刷新恢复上一份完整快照，不留下断图占位符', async ({ page }) => {
  await openHome(page);
  const editor = page.getByTestId('text-input');
  await editor.fill('上一次成功保存的正文');
  await page.getByTestId('inline-image-input').setInputFiles(fixture('inline-mark.png'));
  await expect(editor).toHaveValue(/!\[插图 1\]/);
  await saved(page);
  const previousText = await editor.inputValue();
  await page.evaluate(() => {
    // Reads remain available; only future asset writes fail.
    IDBObjectStore.prototype.put = function () {
      throw new DOMException('Simulated next asset write failure', 'QuotaExceededError');
    };
  });
  await editor.fill(`${previousText}\n这一次未能保存的新文字`);
  await page.getByTestId('inline-image-input').setInputFiles(fixture('sample-page.png'));
  await expect(editor).toHaveValue(/!\[插图 2\]/);
  await expect(page.getByTestId('message-info')).toContainText('无法保存到本机，请检查存储权限或可用空间');
  await page.reload();
  await expect(editor).toHaveValue(previousText);
  await expect(page.locator('.inline-image-row img')).toHaveCount(1);
  const restoredBytes = await page.locator('.inline-image-row img').evaluate(async (image) =>
    Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())),
  );
  expect(Buffer.from(restoredBytes)).toEqual(png);
});

test('数字输入可先清空再填写，签名内全选只替换签名', async ({ page }) => {
  await openHome(page);
  const fontSize = page.getByTestId('font-size-input');
  await fontSize.fill('');
  await expect(fontSize).toHaveValue('');
  await fontSize.pressSequentially('82', { delay: 0 });
  await fontSize.press('Tab');
  await expect(fontSize).toHaveValue('82');
  await fontSize.fill('');
  await fontSize.press('Tab');
  await expect(fontSize).toHaveValue('82');
  const spacing = page.getByTestId('word-spacing-input');
  await spacing.fill('');
  await spacing.pressSequentially('-5', { delay: 0 });
  await spacing.press('Tab');
  await expect(spacing).toHaveValue('-5');
  const editor = page.getByTestId('text-input');
  const original = '亲爱的朋友：\n正文必须完整保留。';
  await editor.fill(original);
  await page.getByTestId('letter-format-btn').click();
  const signature = page.getByTestId('letter-signature-input');
  await signature.fill('原署名 ABC');
  await signature.press('ControlOrMeta+A');
  await expect(signature).toBeFocused();
  await signature.pressSequentially('新署名 XYZ', { delay: 0 });
  await expect(signature).toHaveValue('新署名 XYZ');
  await expect(editor).toHaveValue(original);
  await page.getByTestId('letter-cancel-btn').click();
  await expect(editor).toHaveValue(original);
});

test('旧大字体预设尚未保存完时再次保存，最终加载第二份快照', async ({ page }) => {
  await openHome(page);
  await saved(page);
  await page.evaluate(() => {
    const originalDigest = SubtleCrypto.prototype.digest;
    const originalWrite = Storage.prototype.setItem;
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    let paused = false;
    window.stateTestPresetWrites = [];
    window.stateTestPresetPaused = false;
    SubtleCrypto.prototype.digest = function (algorithm, data) {
      if (!paused && data.byteLength > 1_000_000) {
        paused = true;
        window.stateTestPresetPaused = true;
        return gate.then(() => originalDigest.call(this, algorithm, data));
      }
      return originalDigest.call(this, algorithm, data);
    };
    Storage.prototype.setItem = function (key, value) {
      originalWrite.call(this, key, value);
      if (key === 'studio.preset') window.stateTestPresetWrites.push(JSON.parse(value));
    };
    window.stateTestReleasePreset = () => release();
    window.stateTestRestorePresetHooks = () => {
      release();
      SubtleCrypto.prototype.digest = originalDigest;
      Storage.prototype.setItem = originalWrite;
    };
  });
  try {
    const fontBytes = fs.readFileSync(path.join(__dirname, '../../ttf_files/悠哉手写体.ttf'));
    await page.getByTestId('text-input').fill('第一份慢预设');
    await page.getByTestId('font-file-input').setInputFiles({
      name: 'large-preset.ttf', mimeType: 'font/ttf', buffer: fontBytes,
    });
    await page.getByTestId('save-settings-btn').click();
    await page.waitForFunction(() => window.stateTestPresetPaused);
    await page.getByTestId('reset-settings-btn').click();
    await page.getByTestId('text-input').fill('第二份完整的新预设');
    await page.getByTestId('font-size-input').fill('84');
    await page.getByTestId('save-settings-btn').click();
    await page.evaluate(() => window.stateTestReleasePreset());
    await expect.poll(() => page.evaluate(() => window.stateTestPresetWrites.length)).toBe(2);
    const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('studio.preset')));
    expect(stored.text).toBe('第二份完整的新预设');
    expect(stored.assets.font).toBeNull();
    await page.getByTestId('text-input').fill('临时覆盖，随后载入');
    await page.getByTestId('load-settings-btn').click();
    await expect(page.getByTestId('text-input')).toHaveValue('第二份完整的新预设');
    await expect(page.getByTestId('font-size-input')).toHaveValue('84');
    await expect(page.getByTestId('font-select')).not.toHaveValue('large-preset.ttf');
  } finally {
    await page.evaluate(() => window.stateTestRestorePresetHooks());
  }
});

test('延迟文档导入期间加载同正文不同文件名的预设，旧响应不能覆盖新快照', async ({ page }) => {
  const text = '相同正文也必须保留当前文档身份。';
  let releaseImport;
  const importGate = new Promise((resolve) => { releaseImport = resolve; });
  let imports = 0;
  await page.route('**/api/textfileprocess', async (route) => {
    expect(route.request().method()).toBe('POST');
    imports++;
    if (imports === 3) {
      await importGate;
      await route.fulfill({ json: { text: '较早导入的旧正文，不应覆盖已加载的预设。' } });
    } else await route.fulfill({ json: { text } });
  });
  await openHome(page);
  const editor = page.getByTestId('text-input');
  const fileName = page.getByTestId('text-file-name');
  const upload = (name) => page.getByTestId('text-file-input').setInputFiles({
    name, mimeType: 'text/plain', buffer: Buffer.from(text, 'utf8'),
  });
  try {
    await upload('preset-document.txt');
    await expect(editor).toHaveValue(text);
    await expect(fileName).toContainText('preset-document.txt');
    await page.getByTestId('save-settings-btn').click();
    await expect(page.getByTestId('message-info')).toContainText('预设设置保存成功！');

    await upload('current-document.txt');
    await expect(fileName).toContainText('current-document.txt');
    await expect(editor).toHaveValue(text);
    await upload('delayed-document.txt');
    await expect.poll(() => imports).toBe(3);
    await page.getByTestId('load-settings-btn').click();
    // The body is identical: checking only its string value would miss this document change.
    await expect(fileName).toContainText('preset-document.txt');
    await expect(editor).toHaveValue(text);
    releaseImport();
    await expect(page.getByTestId('message-info')).toContainText('正文已更新，未覆盖为稍早导入的文档');
    await expect(editor).toHaveValue(text);
    await expect(fileName).toContainText('preset-document.txt');
    await expect(fileName).not.toContainText('delayed-document.txt');
    expect(imports).toBe(3);
  } finally {
    releaseImport();
  }
});
