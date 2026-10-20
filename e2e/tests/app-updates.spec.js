const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const { test, expect, openHome } = require('./fixtures');
const output = path.resolve(__dirname, '../../preview_outputs/update-feature');
async function dismissPrompt(page) {
  await expect(page.getByTestId('update-prompt')).toBeVisible();
  await page.getByTestId('update-prompt-later').click();
  await expect(page.getByTestId('update-prompt')).toHaveCount(0);
}


test('desktop update settings support check, preference persistence and explicit download actions', async ({ page }) => {
  await page.addInitScript(() => {
    let state = { status: 'idle', current: '1.6.0', portable: false };
    let listener = () => {};
    window.updateDownloadCalls = 0;
    window.updateOpenCalls = 0;
    window.handwritingDesktop = {
      onDownloadFinished: () => () => {}, revealLastDownload() {}, onBeforeClose: () => () => {},
      storage: { readRecord: async (key) => localStorage.getItem(key), writeRecord: async (key, value) => localStorage.setItem(key, value), removeRecord: async (key) => localStorage.removeItem(key), readAsset: async () => null, writeAsset: async () => {}, removeAsset: async () => {} },
      updates: {
        state: async () => state, subscribe: (callback) => { listener = callback; return () => {}; },
        check: async () => { state = { status: 'available', current: '1.6.0', version: '1.7.0', notes: '- 测试预览 / Test preview\n- 改进手写排版与更新体验。', releaseUrl: 'https://github.com/SXP-Simon/Panache/releases/tag/v1.7.0' }; listener(state); return state; },
        download: async () => { window.updateDownloadCalls++; state = { ...state, status: 'ready' }; listener(state); return state; },
        cancel: async () => state, open: async () => { window.updateOpenCalls++; return { ...state, status: 'launched' }; },
      },
    };
  });
  await openHome(page);
  await page.getByTestId('appearance-btn').click();
  await page.getByTestId('update-auto').uncheck();
  await page.getByTestId('update-check').click(); await dismissPrompt(page);
  await expect(page.getByTestId('update-status')).toContainText('有新版本可用');
  await expect(page.getByTestId('update-status')).toContainText('v1.7.0');
  expect(await page.evaluate(() => window.updateDownloadCalls)).toBe(0);
  await fs.mkdir(output, { recursive: true });
  await page.getByTestId('update-settings').locator('summary').click();
  await page.getByTestId('update-settings').screenshot({ path: path.join(output, 'web-update-settings.png') });
  await page.getByTestId('update-download').click();
  await expect(page.getByTestId('update-status')).toContainText('已下载，可以安装');
  await page.getByTestId('appearance-modal-close').click();
  await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
  let blocked;
  const started = new Promise((resolve) => { blocked = resolve; });
  let pendingRequest;
  await page.route('**/api/generate_handwriting', (route) => { pendingRequest = route; blocked(); });
  await page.getByTestId('text-input').fill('生成期间不应开始安装。');
  await page.getByTestId('preview-btn').click(); await started;
  await page.getByTestId('appearance-btn').click(); await page.getByTestId('update-open').click();
  await expect(page.getByTestId('update-status')).toContainText('正在生成内容');
  expect(await page.evaluate(() => window.updateOpenCalls)).toBe(0);
  await pendingRequest.abort();
  await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await page.getByTestId('update-check').click(); await dismissPrompt(page); await page.getByTestId('update-download').click();
  await page.getByTestId('update-open').click();
  await expect(page.getByTestId('update-status')).toContainText('安装程序已打开');
  await page.reload();
  await page.getByTestId('appearance-btn').click();
  await expect(page.getByTestId('update-auto')).not.toBeChecked();
});

test('web environment explains deployment scope and never offers desktop installer controls', async ({ page }) => {
  await openHome(page); await page.getByTestId('appearance-btn').click();
  await expect(page.getByTestId('update-settings')).toContainText('服务端由部署管理员升级');
  await page.getByTestId('update-check').click();
  await expect(page.getByTestId('update-status')).toContainText('此环境不支持');
  await expect(page.getByTestId('update-download')).toHaveCount(0);
});

test('production deployment waits for approval and saves the draft before activating its real service worker', async ({ browser }) => {
  const dist = path.resolve(__dirname, '../../frontend/dist');
  let deployment = 'one';
  const mime = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.json': 'application/json', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };
  const server = http.createServer((req, res) => { void (async () => {
    const pathname = new URL(req.url, 'http://localhost').pathname;
    res.setHeader('Cache-Control', 'no-store');
    if (pathname.startsWith('/api/')) { res.setHeader('Content-Type', 'application/json'); res.end(pathname === '/api/fonts_info' ? '["云烟体.ttf"]' : '{"version":"self-hosted"}'); return; }
    const target = path.resolve(dist, `.${pathname === '/' ? '/index.html' : pathname}`);
    if (!target.startsWith(dist + path.sep)) { res.writeHead(403); res.end(); return; }
    try {
      let bytes = await fs.readFile(target);
      if (pathname === '/studio-worker.js') bytes = Buffer.from(bytes.toString() + `\n// deployment ${deployment}`);
      if (pathname === '/' || pathname === '/index.html') bytes = Buffer.from(bytes.toString().replace('<head>', `<head><meta name="test-deployment" content="${deployment}">`));
      res.setHeader('Content-Type', mime[path.extname(target)] ?? 'application/octet-stream'); res.end(bytes);
    } catch { res.writeHead(404); res.end(); }
  })().catch(() => { res.writeHead(500); res.end(); }); });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const context = await browser.newContext({ serviceWorkers: 'allow' });
  const page = await context.newPage();
  try {
    await page.goto(origin); await page.getByTestId('text-input').waitFor();
    await page.evaluate(async () => { await navigator.serviceWorker.ready; });
    await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
    await page.getByTestId('appearance-btn').click(); await page.getByTestId('update-auto').uncheck();
    await page.getByTestId('appearance-modal-close').click();
    await expect(page.getByTestId('appearance-modal')).toHaveCount(0);
    await page.getByTestId('text-input').fill('更新前必须保存的最后一笔。');
    await expect(page.getByTestId('text-input')).toHaveValue('更新前必须保存的最后一笔。');
    deployment = 'two';
    await page.getByTestId('appearance-btn').click(); await page.getByTestId('update-check').click();
    await expect(page.getByTestId('update-prompt')).toContainText('网页已更新');
    await expect(page.getByTestId('update-prompt-notes')).toHaveCount(0);
    await expect(page.getByTestId('update-prompt-now')).toHaveText('保存并刷新');
    await fs.mkdir(output, { recursive: true });
    await page.getByTestId('update-prompt').screenshot({ path: path.join(output, 'pwa-update-prompt.png') });
    await dismissPrompt(page);
    await expect(page.getByTestId('update-status')).toContainText('有新版本可用');
    expect(await page.locator('meta[name="test-deployment"]').getAttribute('content')).toBe('one');
    expect(await page.evaluate(async () => Boolean((await navigator.serviceWorker.getRegistration()).waiting))).toBe(true);
    await fs.mkdir(output, { recursive: true }); await page.getByTestId('update-settings').screenshot({ path: path.join(output, 'pwa-update-available.png') });
    await page.evaluate(() => {
      window.originalSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) { if (key === 'studio.workspace') throw new Error('disk full'); return window.originalSetItem.call(this, key, value); };
    });
    await page.getByTestId('update-auto').check();
    await page.getByTestId('update-open').click();
    await expect(page.getByTestId('update-status')).toContainText('尚未保存成功');
    expect(await page.locator('meta[name="test-deployment"]').getAttribute('content')).toBe('one');
    await page.evaluate(() => { Storage.prototype.setItem = window.originalSetItem; });
    await page.getByTestId('update-check').click(); await dismissPrompt(page);
    await page.getByTestId('update-open').click();
    await expect(page.locator('meta[name="test-deployment"]')).toHaveAttribute('content', 'two');
    await expect(page.getByTestId('text-input')).toHaveValue('更新前必须保存的最后一笔。');
    expect(await page.evaluate(() => JSON.parse(localStorage.getItem('studio.workspace')).text)).toBe('更新前必须保存的最后一笔。');
  } finally { await context.close(); await new Promise((resolve) => server.close(resolve)); }
});
