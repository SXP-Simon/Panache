const fs = require('node:fs/promises');
const path = require('node:path');
const { test, expect, openHome } = require('./fixtures');
const output = path.resolve(__dirname, '../../preview_outputs/update-feature');
async function bridge(page) {
  await page.addInitScript(() => {
    let state = { status: 'idle', current: '1.6.0' }, notify = () => {};
    window.updateChecks = 0; window.updateDownloads = 0; window.nextUpdateStatus = 'available';
    window.handwritingDesktop = {
      onDownloadFinished: () => () => {}, revealLastDownload() {}, onBeforeClose: () => () => {},
      storage: { readRecord: async (key) => localStorage.getItem(key), writeRecord: async (key, value) => localStorage.setItem(key, value), removeRecord: async (key) => localStorage.removeItem(key), readAsset: async () => null, writeAsset: async () => {}, removeAsset: async () => {} },
      updates: {
        state: async () => state, subscribe: (callback) => { notify = callback; return () => {}; },
        check: async () => { window.updateChecks++; state = { status: window.nextUpdateStatus, current: '1.6.0', version: '1.7.0', notes: '### Features\n- **fe/path:** 支持检查和安装更新 ([abcdef1](https://github.com/SXP-Simon/Panache/commit/abcdef1))\n- 改进手写表格排版\n<!-- download-guide -->\n- 不应出现的下载指南', releaseUrl: 'https://github.com/SXP-Simon/Panache/releases/tag/v1.7.0' }; notify(state); return state; },
        download: async () => { window.updateDownloads++; state = { ...state, status: 'ready' }; notify(state); return state; },
        cancel: async () => state, open: async () => ({ ...state, status: 'launched' }),
      },
    };
  });
}
async function later(page) { await page.getByTestId('update-prompt-later').click(); await expect(page.getByTestId('update-prompt')).toHaveCount(0); }
async function automatic(page) { await page.evaluate(async () => { const updates = await import('/src/features/updates/runtime.ts'); await updates.checkUpdates('automatic'); }); }

test('automatic update dialog opens changelog, dismisses once, and manual checks can reopen with restored focus', async ({ page }) => {
  await bridge(page); await openHome(page);
  await expect(page.getByTestId('update-prompt')).toBeVisible();
  await expect(page.getByTestId('update-prompt-version')).toHaveText('Panache v1.7.0');
  await expect(page.getByTestId('update-prompt-notes')).toContainText('支持检查和安装更新');
  await expect(page.getByTestId('update-prompt-notes')).not.toContainText('fe/path');
  await expect(page.getByTestId('update-prompt-notes')).not.toContainText('abcdef1');
  await expect(page.getByTestId('update-prompt-notes')).not.toContainText('下载指南');
  expect(await page.evaluate(() => window.updateDownloads)).toBe(0);
  await fs.mkdir(output, { recursive: true }); await page.getByTestId('update-prompt').screenshot({ path: path.join(output, 'web-update-prompt.png') });
  await later(page); await automatic(page); await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await page.getByTestId('appearance-btn').click(); await page.getByTestId('update-check').click();
  await expect(page.getByTestId('update-prompt')).toBeVisible();
  await page.keyboard.press('Escape'); await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await expect(page.getByTestId('update-check')).toBeFocused();
  await page.getByTestId('update-show-prompt').click(); await page.getByTestId('update-prompt-now').click();
  await expect(page.getByTestId('update-prompt-status')).toContainText('已下载');
  expect(await page.evaluate(() => window.updateDownloads)).toBe(1);
  await later(page); await expect(page.getByTestId('update-prompt')).toHaveCount(0);
});

test('automatic notice waits for another dialog, remains quiet on errors and pending packages', async ({ page }) => {
  await bridge(page); await openHome(page); await page.getByTestId('guide-btn').click();
  await expect.poll(() => page.evaluate(() => window.updateChecks)).toBeGreaterThan(0);
  await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await page.keyboard.press('Escape'); await expect(page.getByTestId('update-prompt')).toBeVisible(); await later(page);
  for (const status of ['current', 'error', 'pending', 'unsupported']) {
    await page.evaluate((status) => { window.nextUpdateStatus = status; }, status); await automatic(page);
    await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  }
});

test('generation delays automatic notices and a later current result discards a stale notice', async ({ page }) => {
  await bridge(page); await openHome(page);
  // Close the startup notice if font loading outlasted the startup check.
  if (await page.getByTestId('update-prompt').count()) await later(page);
  await page.evaluate(async () => { const { useUpdatesStore } = await import('/src/features/updates/store.ts'); useUpdatesStore.setState({ seen: [] }); });
  let routeReady, route;
  const started = new Promise((resolve) => { routeReady = resolve; });
  await page.route('**/api/generate_handwriting', (pending) => { route = pending; routeReady(); });
  await page.getByTestId('text-input').fill('正在生成时，先完成当前工作。'); await page.getByTestId('preview-btn').click(); await started;
  await automatic(page); await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await page.evaluate(() => { window.nextUpdateStatus = 'current'; }); await automatic(page);
  await route.abort(); await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await page.evaluate(() => { window.nextUpdateStatus = 'available'; }); await automatic(page);
  await expect(page.getByTestId('update-prompt')).toBeVisible();
});

test('mobile dark update dialog wraps notes and stays usable without overflow', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 740 });
  await page.addInitScript(() => localStorage.setItem('studio.theme', 'dark'));
  await bridge(page); await openHome(page); await expect(page.getByTestId('update-prompt')).toBeVisible();
  const bounds = await page.getByTestId('update-prompt').boundingBox(); expect(bounds.width).toBeLessThanOrEqual(390); expect(bounds.height).toBeLessThanOrEqual(740);
  await expect(page.getByTestId('update-prompt-now')).toBeVisible();
  await fs.mkdir(output, { recursive: true }); await page.getByTestId('update-prompt').screenshot({ path: path.join(output, 'web-update-prompt-mobile-dark.png') });
  await later(page);
});


test('automatic notice waits for editor letter dialogs outside the application settings', async ({ page }) => {
  await bridge(page); await openHome(page);
  await page.getByTestId('text-input').fill('你好，这是一封待排版的信。');
  await page.getByTestId('letter-format-btn').click();
  await expect(page.getByTestId('letter-dialog')).toBeVisible();
  await automatic(page);
  await expect(page.getByTestId('update-prompt')).toHaveCount(0);
  await page.getByTestId('letter-cancel-btn').click();
  await expect(page.getByTestId('letter-dialog')).toHaveCount(0);
  await expect(page.getByTestId('update-prompt')).toBeVisible();
});
