const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const { launchDesktopApp } = require('./launch');

for (const exit of ['window.close', 'app.quit']) {
  test(`刚输入正文立即 ${exit}，退出前保存末尾字符`, async () => {
    const desktop = await launchDesktopApp();
    let window;
    try {
      const editor = desktop.page.getByTestId('text-input');
      await editor.fill('已经正常保存的旧正文');
      await expect(desktop.page.getByTestId('draft-save-status')).toContainText('已保存到本机');
      if (exit === 'window.close') window = await desktop.app.browserWindow(desktop.page);
      const closed = desktop.app.waitForEvent('close', { timeout: 45_000 });
      const latest = `已经正常保存的旧正文\n尚未等待防抖的末尾字符 ${exit} XYZ987完整。`;
      await editor.fill(latest);
      // Do not wait for saving, blur the editor, or mock storage before triggering real shutdown.
      if (window) {
        await window.evaluate((browserWindow) => {
          setTimeout(() => browserWindow.close(), 0);
        });
      } else {
        await desktop.app.evaluate(({ app }) => {
          setTimeout(() => app.quit(), 0);
        });
      }
      await closed;
      // Read before desktop.close() removes this application's isolated data directory.
      const record = path.join(desktop.dataDir, 'studio', 'records', 'studio.workspace.json');
      const workspace = JSON.parse(fs.readFileSync(record, 'utf8'));
      expect(workspace.version).toBe(2);
      expect(workspace.text).toBe(latest);
    } finally {
      await window?.dispose().catch(() => {});
      await desktop.close();
    }
  });
}
