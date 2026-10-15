"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { CHECKS, runQualityChecks } = require("../run-quality-checks.cjs");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { findBash } = require("../run-desktop-tests.cjs");

test("提交前完整执行前端与 Python 检查，即使早期检查失败也报告全部门禁", () => {
  const commands = [];
  const output = [];
  const status = runQualityChecks((command) => {
    commands.push(command);
    return { status: command.includes("typecheck") ? 1 : 0 };
  }, (line) => output.push(line));
  assert.equal(status, 1);
  assert.deepEqual(commands, CHECKS);
  assert.ok(commands.includes("uv run --extra dev pyright"));
  assert.ok(commands.includes("uv run --extra dev ruff check ."));
  assert.ok(commands.includes("uv run --extra dev ruff format --check ."));
  assert.match(output.join("\n"), /ruff check --fix \\?\./u);
  assert.match(output.join("\n"), /不会自动暂存/u);
  assert.ok(commands.every((command) => !command.includes("git add")));
});

test("全部检查成功时才能放行提交", () => {
  assert.equal(runQualityChecks(() => ({ status: 0 }), () => {}), 0);
  assert.equal(runQualityChecks(() => ({ status: null }), () => {}), 1);
});

test("桌面构建在 Windows 查找 Git Bash，缺失时明确拒绝而非误用 WSL", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "desktop-bash-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, "bin"));
  const bash = path.join(directory, "bin/bash.exe");
  fs.writeFileSync(bash, "fixture");
  const locate = () => ({ stdout: path.join(directory, "cmd/git.exe") + "\r\n" });
  assert.equal(findBash("win32", locate), bash);
  assert.equal(findBash("linux"), "bash");
  assert.throws(() => findBash("win32", () => ({ stdout: "" })), /Git Bash/u);
});

test("真实 Lefthook script 配置保留 Git pre-push stdin 的全部引用", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "lefthook-stdin-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  assert.equal(spawnSync("git", ["init"], { cwd: directory }).status, 0);
  fs.mkdirSync(path.join(directory, "scripts/hooks/pre-push"), { recursive: true });
  fs.writeFileSync(path.join(directory, "lefthook.yml"),
    "source_dir: scripts/hooks\npre-push:\n  scripts:\n    full-tests.cjs:\n      runner: node\n      use_stdin: true\n");
  fs.writeFileSync(path.join(directory, "scripts/hooks/pre-push/full-tests.cjs"),
    "const fs = require('node:fs'); fs.writeFileSync('captured.txt', fs.readFileSync(0));\n");
  const refs = `refs/heads/custom-base ${"1".repeat(40)} refs/heads/custom-base ${"2".repeat(40)}\n`
    + `(delete) ${"0".repeat(40)} refs/heads/old ${"3".repeat(40)}\n`;
  const result = spawnSync(process.execPath, [path.resolve(__dirname, "../../node_modules/lefthook/bin/index.js"), "run", "pre-push"],
    { cwd: directory, input: refs, encoding: "utf8", timeout: 15000 });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.equal(fs.readFileSync(path.join(directory, "captured.txt"), "utf8"), refs);
});
