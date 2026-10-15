#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");
const { planChanges, readPlan } = require("./plan-checks.cjs");
const { git, dirtyPaths } = require("./git-change-set.cjs");

const FRONTEND_CHECKS = [
  "pnpm --filter handwrite run typecheck",
  "pnpm --filter handwrite run lint",
  "pnpm --filter handwrite run format:check",
];
const PYTHON_CHECKS = [
  "uv run --extra dev ruff check .",
  "uv run --extra dev ruff format --check .",
  "uv run --extra dev pyright",
];
const DESKTOP_CHECKS = [
  "node --check desktop/main.js", "node --check desktop/preload.js",
  "node --check desktop/studio-storage.js", "pnpm run test:desktop-storage",
];
function qualityCommands(plan) {
  return [
    ...(plan.frontend ? FRONTEND_CHECKS : []),
    ...(plan.python ? PYTHON_CHECKS : []),
    ...(plan.hooks ? ["pnpm run test:hooks"] : []),
    ...(plan.unit_desktop ? DESKTOP_CHECKS : []),
  ];
}
const CHECKS = qualityCommands(planChanges([], { full: true }));

function assertCleanInputs(plan, files, groups = ["frontend", "python", "hooks", "unit_frontend", "unit_python", "unit_desktop",
  "build", "e2e", "sw_upgrade", "docs", "desktop_e2e"]) {
  const dirty = planChanges(files);
  const overlap = groups.filter((key) => plan[key] && dirty[key]);
  if (overlap.length) throw new Error(`相关检查输入存在未提交或未暂存修改（${overlap.join(", ")}），会测到错误版本。请先暂存对应改动，推送前则先提交或保存这些修改。`);
}

function runQualityChecks(run = spawnSync, write = console.error, checks = CHECKS) {
  const failures = [];
  for (const command of checks) {
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

function main(args) {
  if (!args.length || (args.length === 1 && args[0] === "--all")) return runQualityChecks();
  if (args.length !== 1 || args[0] !== "--staged") throw new Error("Use --staged or --all");
  const plan = readPlan(args);
  const commands = qualityCommands(plan);
  // Commit-time checks must represent the index, not a newer unstaged implementation.
  if (commands.length) assertCleanInputs(plan, dirtyPaths(), ["frontend", "python", "hooks", "unit_desktop"]);
  git(["diff", "--cached", "--check"]);
  console.log(`暂存区范围：${plan.scopes.join(", ") || "无文件变化"}；选择 ${commands.length} 项检查。`);
  return runQualityChecks(undefined, undefined, commands);
}
if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { console.error(`质量检查失败：${error.message}`); process.exitCode = 1; }
}
module.exports = { CHECKS, runQualityChecks, qualityCommands, assertCleanInputs, main };
