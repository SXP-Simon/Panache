#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function git(args, cwd) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || `git ${args.join(" ")} 失败。`);
  return result.stdout.trim();
}

function installHooks(cwd = process.cwd(), environment = process.env, run = spawnSync) {
  // CI executes quality:check directly. Installing local hooks there would alter semantic-release commits.
  if (environment.CI && !["0", "false"].includes(environment.CI)) return "ci";
  git(["rev-parse", "--git-dir"], cwd);
  const configured = spawnSync("git", ["config", "--get", "core.hooksPath"], { cwd, encoding: "utf8" });
  if (configured.status !== 1) throw new Error("检测到自定义 core.hooksPath；请先把现有检查整合进 lefthook.yml，再移除该配置。不会自动覆盖。");
  const hooksPath = path.resolve(cwd, git(["rev-parse", "--git-path", "hooks"], cwd));
  for (const name of ["pre-commit", "commit-msg", "pre-push"]) {
    const active = path.join(hooksPath, name);
    const backup = `${active}.old`;
    const managed = fs.existsSync(active) && /lefthook/iu.test(fs.readFileSync(active, "utf8"));
    if (fs.existsSync(backup)) {
      if (managed) {
        // npm may run the dependency postinstall first. Restore its inert .old backup instead of losing checks.
        fs.copyFileSync(backup, active);
        fs.chmodSync(active, fs.statSync(backup).mode);
      }
      throw new Error(`检测到已有 hook 备份 ${backup}；已保留原检查，请先人工整合进 lefthook.yml。不会把备份当作已执行。`);
    }
    if (fs.existsSync(active) && !managed) throw new Error(`检测到现有 hook ${active}；请先整合已有检查，不会覆盖或静默停用。`);
  }
  const command = path.join(cwd, "node_modules", "lefthook", "bin", "index.js");
  const result = run(process.execPath, [command, "install"], { cwd, env: environment, stdio: "inherit" });
  if (result.status !== 0) throw new Error("Lefthook 安装失败；修正错误后运行 pnpm run hooks:install，不能跳过现有检查。");
  return "installed";
}

if (require.main === module) {
  try {
    const result = installHooks();
    console.log(result === "ci" ? "CI 直接执行质量门禁，不安装本地 Git hooks。" : "Lefthook 已安装：提交前质量检查、提交说明校验、推送前完整测试。");
  } catch (error) {
    console.error(`安装 Git hooks 失败：${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = { installHooks };
