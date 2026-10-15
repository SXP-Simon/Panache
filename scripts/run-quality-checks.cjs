#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");

const CHECKS = [
  "pnpm --filter handwrite run typecheck",
  "pnpm --filter handwrite run lint",
  "pnpm --filter handwrite run format:check",
  "uv run --extra dev ruff check .",
  "uv run --extra dev ruff format --check .",
  "uv run --extra dev pyright",
];

function runQualityChecks(run = spawnSync, write = console.error) {
  const failures = [];
  for (const command of CHECKS) {
    write(`\n正在检查：${command}`);
    // Commands are fixed project constants; shell mode supports pnpm.cmd and uv on Windows.
    const result = run(command, { shell: true, stdio: "inherit" });
    if (result.status !== 0) failures.push(command);
  }
  if (failures.length) {
    write(`\n提交前质量检查未通过：\n${failures.map((command) => `- ${command}`).join("\n")}\n\n请先阅读上方诊断，再运行适用的修复命令：\n  uv run --extra dev ruff check --fix .\n  uv run --extra dev ruff format .\n  uv run --extra dev pyright\n\n前端请修复类型和 lint 诊断，并按项目格式命令整理代码。\n修复后先审阅 git diff，再运行 pnpm run quality:check。检查不会自动暂存文件，也不能通过跳过 hook 代替修复。`);
  }
  return failures.length ? 1 : 0;
}

if (require.main === module) process.exitCode = runQualityChecks();
module.exports = { CHECKS, runQualityChecks };
