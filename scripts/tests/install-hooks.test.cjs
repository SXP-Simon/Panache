"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { installHooks } = require("../install-hooks.cjs");

function repository(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "install-hooks-"));
  try {
    assert.equal(spawnSync("git", ["init"], { cwd: directory }).status, 0);
    run(directory, path.join(directory, ".git/hooks"));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test("本地 prepare 安装，不使用 force，CI 由 workflow 直接校验", () => {
  repository((directory) => {
    const calls = [];
    assert.equal(installHooks(directory, { ...process.env, CI: "false" }, (...args) => {
      calls.push(args);
      return { status: 0 };
    }), "installed");
    assert.deepEqual(calls[0][1], [path.join(directory, "node_modules/lefthook/bin/index.js"), "install"]);
    assert.equal(installHooks(directory, { CI: "true" }, () => { throw new Error("CI must not install hooks"); }), "ci");
  });
});

test("未知现有 hooks 必须保留，安装失败不静默绕过", () => {
  repository((directory, hooks) => {
    const hook = path.join(hooks, "pre-commit");
    fs.writeFileSync(hook, "#!/bin/sh\nrun-existing-checks\n");
    assert.throws(() => installHooks(directory, {}), /已有检查/u);
    assert.equal(fs.readFileSync(hook, "utf8"), "#!/bin/sh\nrun-existing-checks\n");
  });
});

test("npm 自动迁移的 .old 检查恢复活跃 hook 后拒绝覆盖", () => {
  repository((directory, hooks) => {
    const hook = path.join(hooks, "pre-commit");
    fs.writeFileSync(hook, "#!/bin/sh\n# lefthook managed\n");
    fs.writeFileSync(`${hook}.old`, "#!/bin/sh\nrun-existing-checks\n");
    assert.throws(() => installHooks(directory, {}), /人工整合/u);
    assert.equal(fs.readFileSync(hook, "utf8"), "#!/bin/sh\nrun-existing-checks\n");
  });
});

test("自定义 hooksPath 或安装失败均明确失败", () => {
  repository((directory) => {
    assert.throws(() => installHooks(directory, {}, () => ({ status: 1 })), /安装失败/u);
    assert.equal(spawnSync("git", ["config", "core.hooksPath", "custom-hooks"], { cwd: directory }).status, 0);
    assert.throws(() => installHooks(directory, {}), /core.hooksPath/u);
  });
});
