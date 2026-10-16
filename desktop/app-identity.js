const fs = require("fs");
const path = require("path");

// 2026-10-16：产品更名后保留原 Chromium 存储与单实例锁身份。
function configureAppIdentity(app) {
  if (!app.isPackaged || app.commandLine.hasSwitch("user-data-dir")) return;
  const directory = path.join(app.getPath("appData"), "HandwritingWeb");
  fs.mkdirSync(directory, { recursive: true });
  app.setPath("userData", directory);
  app.setPath("sessionData", directory);
}

module.exports = { configureAppIdentity };
