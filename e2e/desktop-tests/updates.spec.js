const { test, expect } = require('./fixtures');
const { createHash } = require('node:crypto');
const { resetHome } = require('./launch');

test('打包应用通过真实主进程桥校验固定来源更新，准备失败时安全保留当前应用', async ({ desktop }) => {
  const bytes = Buffer.from('Panache isolated update smoke test - not executable');
  await desktop.app.evaluate(({ session }, payload) => {
    const bytes = Uint8Array.from(payload.bytes);
    const version = '999.0.0';
    const name = process.platform === 'darwin' ? `Panache-${version}-arm64.zip` : `Panache-Setup-${version}.exe`;
    const url = `https://github.com/SXP-Simon/Panache/releases/download/v${version}/${name}`;
    session.defaultSession.protocol.handle('https', (request) => {
      if (request.url === 'https://api.github.com/repos/SXP-Simon/Panache/releases/latest') return new Response(JSON.stringify({
        tag_name: `v${version}`, draft: false, prerelease: false, body: '隔离测试安装包，不可执行。', assets: [{ name, state: 'uploaded', size: bytes.length, digest: `sha256:${payload.digest}`, browser_download_url: url }],
      }), { headers: { 'Content-Type': 'application/json' } });
      if (request.url === url) return new Response(bytes, { headers: { 'Content-Length': String(bytes.length) } });
      return new Response('Blocked by isolated test', { status: 403 });
    });
  }, { bytes: [...bytes], digest: createHash('sha256').update(bytes).digest('hex') });
  try {
    const { page } = desktop;
    await page.getByTestId('appearance-btn').click();
    await page.getByTestId('update-auto').uncheck();
    await page.getByTestId('update-check').click();
    await expect(page.getByTestId('update-prompt-version')).toContainText('v999.0.0');
    await page.getByTestId('update-prompt-now').click();
    // Windows 请求旧安装包时被隔离的 403 拦截；macOS 不需要旧安装包，直接拒绝假 ZIP。
    const expectedError = process.platform === 'darwin' ? 'network' : 'rateLimited';
    await expect.poll(() => page.evaluate(() => window.handwritingDesktop.updates.state())).toMatchObject({
      status: 'error', error: expectedError, manualAvailable: true,
    });
    const state = await page.evaluate(() => window.handwritingDesktop.updates.state());
    expect(state.status).toBe('error'); expect(state.manualAvailable).toBe(true); expect(state.current).toBe(require('../../desktop/package.json').version);
    expect(state).not.toHaveProperty('asset'); expect(state).not.toHaveProperty('file');
    expect(await desktop.app.evaluate(({ app }) => app.isPackaged)).toBe(true);
    expect(await page.evaluate(() => window.handwritingDesktop.updates.healthy())).toBe(false);
    // Both platform paths must keep the original app running; fake bytes must never execute.
  } finally { await desktop.app.evaluate(({ session }) => session.defaultSession.protocol.unhandle('https')); }
});

test('更新退出保存握手拒绝打断生成任务，取消后恢复可编辑状态', async ({ desktop }) => {
  await resetHome(desktop);
  const { page } = desktop;
  let route, started;
  const pending = new Promise((resolve) => { started = resolve; });
  await page.route('**/api/generate_handwriting', (request) => { route = request; started(); });
  await page.getByTestId('text-input').fill('生成期间仍要保留当前任务和编辑内容。');
  await page.getByTestId('preview-btn').click(); await pending;
  try {
    const acknowledgement = await desktop.app.evaluate(({ BrowserWindow, ipcMain }) => new Promise((resolve) => {
      ipcMain.once('storage:flush-complete', (_event, id, success, reason) => resolve({ id, success, reason }));
      BrowserWindow.getAllWindows()[0].webContents.send('storage:flush-request', '00000000-0000-4000-8000-000000000000', 'update');
    }));
    expect(acknowledgement.success).toBe(false); expect(acknowledgement.reason).toBe('generationBusy');
  } finally {
    await desktop.app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].webContents.send('storage:close-cancelled'));
    await route.abort(); await page.unroute('**/api/generate_handwriting');
  }
  await expect(page.getByTestId('preview-btn')).toBeEnabled();
  await page.getByTestId('text-input').fill('更新已延后，仍然可以继续编辑。');
  await expect(page.getByTestId('text-input')).toHaveValue('更新已延后，仍然可以继续编辑。');
});
