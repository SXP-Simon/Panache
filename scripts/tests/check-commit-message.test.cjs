"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { EXAMPLE, validateCommitMessage, validateScopePaths } = require("../check-commit-message.cjs");

test("fe/be scope 映射真实变更路径，并保留旧 scope 兼容", () => {
  const message = (scope) => EXAMPLE.replace("fix(math)", `fix(${scope})`);
  assert.deepEqual(validateScopePaths(message("fe/src/components"), ["frontend/src/components/Editor.tsx"]), []);
  assert.deepEqual(validateScopePaths(message("be/app.py"), ["backend/app.py"]), []);
  assert.deepEqual(validateScopePaths(message("be"), ["backend/app.py"]), []);
  assert.deepEqual(validateScopePaths(EXAMPLE, []), []);
  for (const scope of ["fe/src/components", "be/app.py", "fe/../backend", "fe/src//components", "be/"]) {
    assert.ok(validateScopePaths(message(scope), ["frontend/src/components-old/Editor.tsx"]).length > 0, scope);
  }
});

test("完整三段、Markdown 标题、CRLF 与 breaking 标记通过", () => {
  for (const message of [EXAMPLE, EXAMPLE.replace(/\n/g, "\r\n"), EXAMPLE.replace("fix(math):", "feat(api)!:"),
    EXAMPLE.replaceAll("背景：", "## 背景").replaceAll("解决手段：", "## 解决手段").replaceAll("收益：", "## 收益"),
    "docs: 更新开发入口\n\n背景：入口变更。\n\n解决手段：更新命令。\n\n收益：入口一致。\n"]) {
    assert.deepEqual(validateCommitMessage(message), [], message);
  }
});

test("缺段、空段、重复、段落粘连和普通标题必须拒绝", () => {
  for (const message of ["更新代码", "fix: 修复问题", EXAMPLE.replace("\n\n背景", "\n背景"),
    EXAMPLE.replace(/收益：[\s\S]*/u, "收益：\n\n  "), EXAMPLE.replace("背景：", "背景：\n\n背景："),
    EXAMPLE.replace("\n\n解决手段", "\n解决手段"), EXAMPLE.replace("解决手段：", "实现："),
    EXAMPLE.replace("fix(math):", "fix(math)"), ` ${EXAMPLE}`, EXAMPLE.replace("收益：", "收益：\n---\n")
      .replace("保留完整公式结构，12 个新增回归样例通过。", "")]) {
    assert.ok(validateCommitMessage(message).length > 0, message);
  }
});

test("仅精确 semantic-release 机器消息可省略正文", () => {
  for (const version of ["1.2.3", "0.0.0", "2.0.0-beta.1", "1.2.3+build.01"]) {
    assert.deepEqual(validateCommitMessage(`chore(release): ${version} [skip ci]\n`), []);
  }
  for (const message of ["chore(release): 1.2.3", "chore(release): latest [skip ci]", "chore(release): 01.2.3 [skip ci]",
    "chore(release): 1.2.3-01 [skip ci]", "fix(release): 1.2.3 [skip ci]", "chore(release): 1.2.3 [skip ci]\n\n任意正文",
    `${EXAMPLE}\n\n[skip ci]`, EXAMPLE.replace("fix(math):", "fix(math): [ci skip]"), `${EXAMPLE}\n\nskip-checks: true`]) {
    assert.ok(validateCommitMessage(message).length > 0, message);
  }
});

test("CLI 中文错误给可复制示例，环境或 skip 参数不能放行", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "commit-message-"));
  try {
    const file = path.join(directory, "message with spaces.txt");
    fs.writeFileSync(file, "fix: 无正文");
    const script = path.resolve(__dirname, "../check-commit-message.cjs");
    const result = spawnSync(process.execPath, [script, file], { encoding: "utf8", env: { ...process.env, CI: "true", SKIP: "1", LEFTHOOK: "0" } });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /背景|解决手段|收益/u);
    assert.match(result.stderr, /可复制的完整示例/u);
    assert.match(result.stderr, /原子提交建议/u);
    assert.equal(spawnSync(process.execPath, [script, "--skip", file]).status, 1);
    fs.writeFileSync(file, EXAMPLE);
    assert.equal(spawnSync(process.execPath, [script, file]).status, 0);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("范围检查不追溯旧提交，但规则首提交及之后删除规则仍强制", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "commit-range-"));
  function git(...args) {
    const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  }
  try {
    git("init");
    git("config", "user.name", "Hook test");
    git("config", "user.email", "hook@example.invalid");
    fs.writeFileSync(path.join(directory, "old.txt"), "old");
    git("add", ".");
    git("commit", "-m", "legacy message");
    fs.appendFileSync(path.join(directory, "old.txt"), "another old change");
    git("add", ".");
    git("commit", "-m", "another legacy message");
    fs.mkdirSync(path.join(directory, "scripts"));
    fs.writeFileSync(path.join(directory, "scripts/check-commit-message.cjs"), "// rule exists\n");
    git("add", ".");
    git("commit", "-m", EXAMPLE);
    const script = path.resolve(__dirname, "../check-commit-message.cjs");
    let result = spawnSync(process.execPath, [script, "--range", "HEAD~2..HEAD"], { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /规则生效前/u);
    git("commit", "--allow-empty", "-m", "fix: 新规则后仍缺正文");
    result = spawnSync(process.execPath, [script, "--range", "HEAD~1..HEAD"], { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 1);
    git("rm", "scripts/check-commit-message.cjs");
    git("commit", "-m", "chore: 删除规则不能绕过正文");
    result = spawnSync(process.execPath, [script, "--range", "HEAD~1..HEAD"], { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 1);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("CLI 对暂存区与提交范围都核对 fe/be 的真实路径", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "commit-scope-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const git = (...args) => {
    const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  };
  git("init");
  git("config", "user.name", "Scope fixture");
  git("config", "user.email", "scope@example.invalid");
  git("config", "commit.gpgsign", "false");
  fs.mkdirSync(path.join(directory, "scripts"));
  fs.writeFileSync(path.join(directory, "scripts/check-commit-message.cjs"), "// rule exists\n");
  git("add", "scripts");
  git("commit", "-m", EXAMPLE);
  fs.mkdirSync(path.join(directory, "frontend/src"), { recursive: true });
  fs.writeFileSync(path.join(directory, "frontend/src/App.tsx"), "// changed\n");
  git("add", "frontend");
  const script = path.resolve(__dirname, "../check-commit-message.cjs");
  const message = path.join(directory, "message.txt");
  const run = (...args) => spawnSync(process.execPath, [script, ...args], { cwd: directory, encoding: "utf8" });
  fs.writeFileSync(message, EXAMPLE.replace("fix(math)", "fix(fe/src/App.tsx)"));
  assert.equal(run(message).status, 0);
  fs.writeFileSync(message, EXAMPLE.replace("fix(math)", "fix(be/app.py)"));
  assert.equal(run(message).status, 1);
  git("commit", "-F", message);
  assert.equal(run("--range", "HEAD~1..HEAD").status, 1);
});
