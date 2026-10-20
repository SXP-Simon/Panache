const { test, expect } = require('./fixtures');

test('打包应用通过真实主进程桥校验固定来源更新，下载后仍等待用户打开', async ({ desktop }) => {
  await desktop.app.evaluate(({ app, session }) => {
    const { createHash } = require('node:crypto');
    const bytes = Buffer.from('Panache isolated update smoke test - not executable');
    const version = '999.0.0';
    const name = process.platform === 'darwin' ? `Panache-${version}-arm64.dmg` : `Panache-Setup-${version}.exe`;
    const url = `https://github.com/SXP-Simon/Panache/releases/download/v${version}/${name}`;
    session.defaultSession.protocol.handle('https', (request) => {
      if (request.url === 'https://api.github.com/repos/SXP-Simon/Panache/releases/latest') return new Response(JSON.stringify({
        tag_name: `v${version}`, draft: false, prerelease: false, body: '隔离测试安装包，不可执行。', assets: [{ name, state: 'uploaded', size: bytes.length, digest: `sha256:${createHash('sha256').update(bytes).digest('hex')}`, browser_download_url: url }],
      }), { headers: { 'Content-Type': 'application/json' } });
      if (request.url === url) return new Response(bytes, { headers: { 'Content-Length': String(bytes.length) } });
      return new Response('Blocked by isolated test', { status: 403 });
    });
  });
  try {
    const { page } = desktop;
    await page.getByTestId('appearance-btn').click();
    await page.getByTestId('update-auto').uncheck();
    await page.getByTestId('update-check').click();
    await expect(page.getByTestId('update-status')).toContainText('v999.0.0');
    await page.getByTestId('update-download').click();
    await expect(page.getByTestId('update-status')).toContainText('通过校验');
    await expect(page.getByTestId('update-open')).toBeVisible();
    const state = await page.evaluate(() => window.handwritingDesktop.updates.state());
    expect(state.status).toBe('ready'); expect(state.current).toBe(require('../../desktop/package.json').version);
    expect(state).not.toHaveProperty('asset'); expect(state).not.toHaveProperty('file');
    expect(await desktop.app.evaluate(({ app }) => app.isPackaged)).toBe(true);
    // Only metadata, progress and an explicit button reach the renderer; never run test bytes.
  } finally { await desktop.app.evaluate(({ session }) => session.defaultSession.protocol.unhandle('https')); }
});
