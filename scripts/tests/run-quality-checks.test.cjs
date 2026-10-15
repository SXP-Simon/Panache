"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { CHECKS, runQualityChecks } = require("../run-quality-checks.cjs");

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
