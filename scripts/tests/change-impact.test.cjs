"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { FLAGS, planChanges } = require("../change-impact.cjs");
const { qualityCommands, assertCleanInputs } = require("../run-quality-checks.cjs");
const { testCommands } = require("../run-affected-tests.cjs");

function selected(plan) {
  return FLAGS.filter((flag) => plan[flag]).sort();
}

test("仓库说明不启动应用工具链，文档站输入只选择文档构建", () => {
  for (const file of ["README.md", "AGENTS.md", "backend/README.md", "frontend/README.md", "LICENSE"]) {
    const plan = planChanges([file]);
    assert.deepEqual(selected(plan), [], file);
    assert.deepEqual(qualityCommands(plan), []);
    assert.deepEqual(testCommands(plan), []);
  }
  for (const file of ["docs/development.md", "docs/assets/example.png", "mkdocs.yml"]) {
    const plan = planChanges([file]);
    assert.deepEqual(selected(plan), ["docs"], file);
    assert.deepEqual(qualityCommands(plan), []);
    assert.equal(testCommands(plan).length, 1);
    assert.match(testCommands(plan)[0], /mkdocs build --strict$/);
  }
});

test("前端业务改动验证 Web 和离线升级，不启动 Python 检查", () => {
  const plan = planChanges(["frontend/src/components/Editor.tsx"]);
  for (const flag of ["frontend", "unit_frontend", "build", "e2e", "sw_upgrade", "docker", "frontend_image", "release"]) {
    assert.equal(plan[flag], true, flag);
  }
  for (const flag of ["python", "unit_python", "backend_image", "desktop_e2e", "docs"]) {
    assert.equal(plan[flag], false, flag);
  }
  assert.ok(qualityCommands(plan).every((command) => command.startsWith("pnpm --filter handwrite")));
  assert.equal(testCommands(plan).filter((command) => command.endsWith(" run build")).length, 1);
  assert.ok(!testCommands(plan).some((command) => /pytest|mkdocs|desktop-tests/.test(command)));
});

test("后端运行时需要 Python 与生成集成检查，后端测试不触发镜像发布", () => {
  const runtime = planChanges(["backend/app.py"]);
  for (const flag of ["python", "unit_python", "e2e", "docker", "backend_image", "release"]) {
    assert.equal(runtime[flag], true, flag);
  }
  assert.equal(runtime.frontend, false);
  assert.equal(runtime.frontend_image, false);
  assert.deepEqual(selected(planChanges(["backend/tests/test_layout.py"])), ["python", "unit_python"]);
  assert.deepEqual(selected(planChanges(["backend/stubs/handrightbeta/__init__.pyi"])), ["python", "unit_python"]);
});

test("测试目录按实际使用环境选择 Web 与打包桌面验证", () => {
  const cases = [
    ["frontend/tests/latex.test.ts", ["unit_frontend"]],
    ["desktop/tests/studio-storage.test.cjs", ["unit_desktop"]],
    ["e2e/tests/generate.spec.js", ["e2e"]],
    ["e2e/desktop-tests/storage.spec.js", ["desktop_e2e", "unit_desktop"]],
    ["e2e/fixtures/letter.txt", ["desktop_e2e", "e2e", "unit_desktop"]],
  ];
  for (const [file, flags] of cases) assert.deepEqual(selected(planChanges([file])), flags.sort(), file);
});

test("桌面运行时与前端存储桥覆盖真实打包验证", () => {
  for (const file of ["desktop/main.js", "backend/desktop_main.py", "frontend/src/persistence/desktopStorage.ts", "frontend/src/env.d.ts"]) {
    const plan = planChanges([file]);
    assert.equal(plan.desktop_e2e, true, file);
    assert.equal(plan.unit_desktop, true, file);
    const commands = testCommands(plan);
    assert.equal(commands.at(-1), "node scripts/run-desktop-tests.cjs");
  }
  assert.equal(planChanges(["desktop/backend.spec"]).python, true);
});

test("共享依赖覆盖其消费者，多个路径合并检查且只构建一次", () => {
  const python = planChanges(["uv.lock"]);
  for (const flag of ["python", "unit_python", "desktop_e2e", "backend_image"]) assert.equal(python[flag], true, flag);
  assert.equal(python.frontend, false);
  const workspace = planChanges(["pnpm-lock.yaml"]);
  for (const flag of ["frontend", "unit_frontend", "unit_desktop", "desktop_e2e", "hooks", "frontend_image"]) {
    assert.equal(workspace[flag], true, flag);
  }
  const combined = planChanges(["backend/app.py", "frontend/src/App.tsx", "frontend/src/App.tsx"]);
  const front = planChanges(["frontend/src/App.tsx"]);
  const back = planChanges(["backend/app.py"]);
  for (const flag of FLAGS) assert.equal(combined[flag], front[flag] || back[flag], flag);
  assert.deepEqual(combined.paths, ["backend/app.py", "frontend/src/App.tsx"]);
  assert.deepEqual(combined.scopes, ["be", "fe"]);
  assert.equal(testCommands(combined).filter((command) => command.endsWith(" run build")).length, 1);
});

test("未知输入和显式完整验证保守覆盖全部门禁", () => {
  for (const plan of [planChanges(["new-runtime/config.toml"]), planChanges([], { full: true, reason: "missing history" })]) {
    assert.deepEqual(selected(plan), [...FLAGS].sort());
  }
  assert.deepEqual(selected(planChanges([])), []);
  assert.equal(planChanges([], { full: true, head_sha: "abc", reason: "manual" }).head_sha, "abc");
});

test("镜像配置和工作流不误报为业务发布，仓库外 Python 也参与质量检查", () => {
  for (const file of ["frontend/nginx.conf", "frontend/dockerfile.frontend"]) {
    const plan = planChanges([file]);
    assert.equal(plan.frontend_image, true, file);
    assert.equal(plan.python, false, file);
    assert.equal(plan.release, false, file);
  }
  const script = planChanges(["scripts/render_preview.py"]);
  assert.equal(script.python, true);
  assert.equal(script.hooks, true);
  assert.equal(script.release, false);
  const workflow = planChanges([".github/workflows/frontend.yml"]);
  assert.equal(workflow.frontend_image, true);
  assert.equal(workflow.release, false);
  const backendTests = planChanges([".github/workflows/test_backend.yml"]);
  assert.equal(backendTests.unit_python, true);
  assert.equal(backendTests.backend_image, false);
  assert.deepEqual(selected(planChanges(["frontend/.oxlintrc.json"])), ["frontend"]);
});

test("保留 Git 原始路径，POSIX 合法反斜线不会被解释为目录分隔符", () => {
  const file = "frontend/src/back\\slash.tsx";
  const plan = planChanges([file]);
  assert.deepEqual(plan.paths, [file]);
  assert.equal(plan.frontend, true);
  assert.equal(plan.desktop_e2e, false);
});

test("拒绝检查相关未暂存输入，允许不影响所选门禁的文档变化", () => {
  const front = planChanges(["frontend/src/App.tsx"]);
  assert.throws(() => assertCleanInputs(front, ["frontend/src/components/Editor.tsx"]), /未提交|未暂存/u);
  assert.throws(() => assertCleanInputs(front, ["pnpm-lock.yaml"]), /未提交|未暂存/u);
  assert.doesNotThrow(() => assertCleanInputs(front, ["README.md"]));
  assert.doesNotThrow(() => assertCleanInputs(planChanges(["backend/tests/test_layout.py"]), ["frontend/README.md"]));
  assert.throws(() => assertCleanInputs(planChanges(["desktop/main.js"]), ["desktop/preload.js"]), /未提交|未暂存/u);
  assert.doesNotThrow(() => assertCleanInputs(planChanges([], { full: true }), ["docs/development.md"],
    ["frontend", "python", "hooks", "unit_desktop"]));
});
