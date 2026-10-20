// 2026-10-20：只签名构建目录中的新产物；更新助手不重签、不修改 quarantine。
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

function createAfterPack({ sign = (options) => require('@electron/osx-sign').signAsync(options), run = promisify(execFile) } = {}) {
  return async (context) => {
    if (context.electronPlatformName !== 'darwin') return;
    const { packager } = context;
    const app = path.join(context.appOutDir, `${packager.appInfo.productFilename}.app`);
    // 2026-10-20：复用锁定的 builder 25 签名参数，保留主程序、Helper 与 Python 的 JIT/加载权限。
    const optionsForFile = await packager.getOptionsForFile(app, false, packager.platformSpecificBuildOptions);
    await sign({
      app,
      platform: 'darwin',
      version: packager.config.electronVersion,
      identity: '-',
      identityValidation: false,
      preAutoEntitlements: false,
      optionsForFile: (file) => ({ ...optionsForFile(file), timestamp: 'none' }),
    });
    // 2026-10-20：ad-hoc 只提供包完整性，并非 Developer ID 或公证；保留系统首次打开确认。
    await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app], { timeout: 120000 });
    await run(path.join(app, 'Contents', 'Resources', 'updater', 'panache-updater'), ['--self-check'], { timeout: 30000 });
  };
}

module.exports = createAfterPack();
module.exports.createAfterPack = createAfterPack;
