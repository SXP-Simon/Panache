#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const { git, staged } = require("./git-change-set.cjs");

const TYPES = "feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert";
const HEADER = new RegExp(`^(?:${TYPES})(?:\\([a-zA-Z0-9][a-zA-Z0-9._/-]*\\))?!?: \\S.*$`, "u");
const NUMBER = "(?:0|[1-9]\\d*)";
const PRE_ID = "(?:0|[1-9]\\d*|\\d*[A-Za-z-][0-9A-Za-z-]*)";
const VERSION = `${NUMBER}\\.${NUMBER}\\.${NUMBER}(?:-${PRE_ID}(?:\\.${PRE_ID})*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?`;
const RELEASE = new RegExp(`^chore\\(release\\): ${VERSION} \\[skip ci\\]$`, "u");
const SKIP_CI = /\[(?:skip ci|ci skip|no ci|skip actions|actions skip)\]|^\s*skip-checks\s*:/imu;
const SECTION = /^(?:#{1,6}[ \t]+)?(背景|解决手段|收益)(?:[：:][ \t]*(.*)|[ \t]*)$/u;

const EXAMPLE = `fix(math): 修复嵌套分式与根式重叠

背景：
嵌套公式的实际高度超过固定行高，导致相邻行墨迹重叠。

解决手段：
按真实字形边界计算行距，并增加窄纸分页回归测试。

收益：
保留完整公式结构，12 个新增回归样例通过。`;

function validateCommitMessage(source) {
  const message = source.replace(/^\uFEFF/u, "").replace(/\r\n?/gu, "\n").replace(/\n+$/u, "");
  // Only the exact message emitted by release.config.js is exempt from prose.
  // The presence of a skip directive, CI variable, or release scope alone never grants an exemption.
  if (RELEASE.test(message)) return [];
  const lines = message.split("\n");
  const errors = [];
  if (!HEADER.test(lines[0]) || lines[0] !== lines[0].trim()) {
    errors.push("标题必须是 Conventional Commits：type(scope): 清晰描述；可用类型为 feat/fix/docs/style/refactor/perf/test/build/ci/chore/revert。");
  }
  if (SKIP_CI.test(message)) {
    errors.push("普通提交不能包含跳过 CI 的指令；仅 semantic-release 的精确版本发布消息允许 [skip ci]。");
  }
  if (lines.length < 3 || lines[1] !== "") errors.push("标题与正文之间必须保留一个空行。");
  const sections = new Map();
  let current;
  for (let index = 2; index < lines.length; index++) {
    const match = SECTION.exec(lines[index]);
    if (match) {
      current = match[1];
      if (sections.has(current)) errors.push(`正文的「${current}」段落不能重复。`);
      if (lines[index - 1].trim() !== "") errors.push(`「${current}」必须独立成段，与上一段之间留一个空行。`);
      sections.set(current, match[2] ?? "");
    } else if (current) {
      sections.set(current, `${sections.get(current)}\n${lines[index]}`);
    }
  }
  for (const name of ["背景", "解决手段", "收益"]) {
    if (!sections.has(name) || !/[\p{L}\p{N}]/u.test(sections.get(name))) {
      errors.push(`正文必须包含非空的「${name}：」段落，写明真实内容。`);
    }
  }
  return errors;
}

function report(label, errors, write = console.error) {
  write(`提交说明校验失败（${label}）：\n${errors.map((error) => `- ${error}`).join("\n")}\n\n可复制的完整示例：\n\n${EXAMPLE}\n\n请把真实说明保存到文本文件，再执行 git commit -F <文件路径>。\n原子提交建议：只提交一个独立行为变更及其必要测试；无关修复、格式化和文档拆成各自通过检查的最小提交。`);
}

function validateScopePaths(source, paths) {
  const scope = /^(?:[^\n(]+)\((fe|be)(?:\/([^)]*))?\)!?: /u.exec(source);
  if (!scope) return [];
  const [, layer, suffix] = scope;
  if (suffix !== undefined && suffix.split("/").some((part) => !part || part === "." || part === "..")) {
    return ["fe/be scope 必须使用仓库内的真实路径，不能包含空路径、. 或 ..。"];
  }
  const target = `${layer === "fe" ? "frontend" : "backend"}${suffix ? `/${suffix}` : ""}`;
  return paths.some((file) => file === target || file.startsWith(`${target}/`)) ? []
    : [`scope「${scope[1]}${suffix ? `/${suffix}` : ""}」未对应实际修改路径「${target}」。`];
}

function main(args) {
  if (args.length === 1 && args[0] !== "--range") {
    const source = fs.readFileSync(args[0], "utf8");
    const errors = [...validateCommitMessage(source), ...validateScopePaths(source, staged().paths)];
    if (errors.length) report(args[0], errors);
    return errors.length ? 1 : 0;
  }
  if (args.length === 2 && args[0] === "--range") {
    const revisions = spawnSync("git", ["rev-list", "--reverse", args[1]], { encoding: "utf8" });
    if (revisions.status !== 0) throw new Error(revisions.stderr || "无法读取 Git 提交范围。");
    let failed = false;
    for (const revision of revisions.stdout.trim().split(/\s+/u).filter(Boolean)) {
      const ruleHistory = spawnSync("git", ["log", "-1", "--format=%H", revision, "--", "scripts/check-commit-message.cjs"], { encoding: "utf8" });
      if (ruleHistory.status !== 0) throw new Error(ruleHistory.stderr || "无法确认提交规则的生效范围。");
      if (!ruleHistory.stdout.trim()) {
        console.log(`${revision}：规则生效前的历史提交，不追溯修改。`);
        continue;
      }
      const result = spawnSync("git", ["show", "-s", "--format=%B", revision], { encoding: "utf8" });
      if (result.status !== 0) throw new Error(result.stderr || `无法读取提交 ${revision}。`);
      const changed = git(["diff-tree", "--root", "--first-parent", "-m", "--no-commit-id", "--name-only", "-r", "-z", "--no-renames", revision, "--"])
        .split("\0").filter(Boolean);
      const errors = [...validateCommitMessage(result.stdout), ...validateScopePaths(result.stdout, changed)];
      if (errors.length) {
        failed = true;
        report(revision, errors);
      }
    }
    return failed ? 1 : 0;
  }
  throw new Error("用法：node scripts/check-commit-message.cjs <提交消息文件>，或 --range <base>..<head>；不提供跳过校验的参数。");
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    console.error(`提交说明校验无法运行：${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = { EXAMPLE, main, validateCommitMessage, validateScopePaths };
