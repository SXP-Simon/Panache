const { test, expect } = require('./fixtures');

test('桌面存储桥只暴露固定记录和资源操作，合法字节可往返且刷新后保留', async ({ desktop }) => {
  const previous = await desktop.page.evaluate(() => window.handwritingDesktop.storage.readRecord('studio.preset'));
  try {
    await desktop.page.evaluate(async () => {
      const storage = window.handwritingDesktop.storage;
      await storage.writeRecord('studio.preset', JSON.stringify({ contract: '固定记录' }));
      await storage.writeAsset('e2e_storage_roundtrip', new Uint8Array([0, 1, 255, 128, 0]).buffer, 'application/octet-stream');
    });
    await desktop.page.reload();
    const result = await desktop.page.evaluate(async () => {
      const storage = window.handwritingDesktop.storage;
      const asset = await storage.readAsset('e2e_storage_roundtrip');
      return {
        methods: Object.keys(storage).sort(),
        record: await storage.readRecord('studio.preset'),
        bytes: Array.from(asset.bytes),
        mimeType: asset.mimeType,
      };
    });
    expect(result.methods).toEqual(['readAsset', 'readRecord', 'removeAsset', 'removeRecord', 'writeAsset', 'writeRecord']);
    expect(JSON.parse(result.record)).toEqual({ contract: '固定记录' });
    expect(result.bytes).toEqual([0, 1, 255, 128, 0]);
    expect(result.mimeType).toBe('application/octet-stream');
  } finally {
    await desktop.page.evaluate(async (previous) => {
      const storage = window.handwritingDesktop.storage;
      if (previous === null) await storage.removeRecord('studio.preset');
      else await storage.writeRecord('studio.preset', previous);
      await storage.removeAsset('e2e_storage_roundtrip');
    }, previous);
  }
});

test('所有桌面存储操作拒绝路径、未知记录键及越界资源ID', async ({ desktop }) => {
  const denied = await desktop.page.evaluate(async () => {
    const storage = window.handwritingDesktop.storage;
    const results = [];
    for (const key of ['../outside', '/tmp/escape', 'studio.unlisted', { path: '../outside' }]) {
      for (const operation of ['readRecord', 'writeRecord', 'removeRecord']) {
        try {
          await storage[operation](key, '{}');
          results.push({ operation, rejected: false });
        } catch {
          results.push({ operation, rejected: true });
        }
      }
    }
    for (const id of ['../outside', 'a/b', 'x'.repeat(97), { path: '../outside' }, 'nul', 'com1']) {
      for (const operation of ['readAsset', 'writeAsset', 'removeAsset']) {
        try {
          await storage[operation](id, new ArrayBuffer(1), 'application/octet-stream');
          results.push({ operation, rejected: false });
        } catch {
          results.push({ operation, rejected: true });
        }
      }
    }
    for (const call of [
      () => storage.writeRecord('studio.preset', { path: '../outside' }),
      () => storage.writeAsset('e2e_bad_payload', new Uint8Array(1), 'application/octet-stream'),
      () => storage.writeAsset('e2e_bad_payload', new ArrayBuffer(1), 'image/png;path=../outside'),
      () => storage.writeAsset('e2e_bad_payload', new ArrayBuffer(1), `image/${'x'.repeat(129)}`),
    ]) {
      try { await call(); results.push({ operation: 'payload', rejected: false }); }
      catch { results.push({ operation: 'payload', rejected: true }); }
    }
    return results;
  });
  expect(denied).toHaveLength(34);
  expect(denied.filter((result) => !result.rejected)).toEqual([]);
});

test('携带真实preload的其他窗口即使同源也不能读取或修改主窗口存储', async ({ desktop }) => {
  const previous = await desktop.page.evaluate(() => window.handwritingDesktop.storage.readRecord('studio.preset'));
  try {
    const results = await desktop.app.evaluate(async ({ app, BrowserWindow }, url) => {
      const denied = [];
      for (const address of [url, 'data:text/html,<title>Untrusted renderer</title>']) {
        const window = new BrowserWindow({
          show: false,
          webPreferences: {
            preload: `${app.getAppPath()}/preload.js`,
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: true,
          },
        });
        try {
          await window.loadURL(address);
          denied.push(...await window.webContents.executeJavaScript(`(async () => {
            const storage = window.handwritingDesktop?.storage;
            if (!storage) return Array(6).fill(true);
            const results = [];
            const calls = [
              () => storage.readRecord('studio.preset'),
              () => storage.writeRecord('studio.preset', '{}'),
              () => storage.removeRecord('studio.preset'),
              () => storage.readAsset('e2e_untrusted_asset'),
              () => storage.writeAsset('e2e_untrusted_asset', new ArrayBuffer(1), 'application/octet-stream'),
              () => storage.removeAsset('e2e_untrusted_asset'),
            ];
            for (const call of calls) {
              try { await call(); results.push(false); }
              catch { results.push(true); }
            }
            return results;
          })()`));
        } finally {
          window.destroy();
        }
      }
      return denied;
    }, desktop.url);
    expect(results).toEqual(Array(12).fill(true));
    expect(await desktop.page.evaluate(() => window.handwritingDesktop.storage.readRecord('studio.preset'))).toBe(previous);
  } finally {
    await desktop.page.evaluate(async (previous) => {
      const storage = window.handwritingDesktop.storage;
      if (previous === null) await storage.removeRecord('studio.preset');
      else await storage.writeRecord('studio.preset', previous);
      await storage.removeAsset('e2e_untrusted_asset');
    }, previous);
  }
});
