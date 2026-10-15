#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function findBash(platform = process.platform, locate = spawnSync) {
  if (platform !== "win32") return "bash";
  const found = locate("where.exe", ["git"], { encoding: "utf8" });
  const candidates = (found.stdout || "").trim().split(/\r?\n/).flatMap((git) => [
    path.resolve(path.dirname(git), "../bin/bash.exe"),
    path.resolve(path.dirname(git), "../../bin/bash.exe"),
  ]);
  const bash = candidates.find((candidate) => fs.existsSync(candidate));
  if (!bash) throw new Error("未找到 Git Bash；请先安装 Git for Windows。不会使用 PATH 中可能指向 WSL 的 bash。");
  return bash;
}
function main() {
  const build = spawnSync(findBash(), ["desktop/build.sh", "--app-only"], { stdio: "inherit" });
  if (build.status !== 0) return 1;
  const tests = spawnSync("pnpm --filter handwriting-web-e2e run test:desktop", { shell: true, stdio: "inherit" });
  return tests.status === 0 ? 0 : 1;
}
if (require.main === module) {
  try { process.exitCode = main(); }
  catch (error) { console.error(`桌面验证失败：${error.message}`); process.exitCode = 1; }
}
module.exports = { findBash, main };
