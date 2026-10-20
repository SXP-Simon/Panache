"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const { FLAGS, planChanges } = require("../change-impact.cjs");

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const workflowRoot = path.resolve(__dirname, "../../.github/workflows");

function source(name) {
  return fs.readFileSync(path.join(workflowRoot, `${name}.yml`), "utf8").replaceAll("\r\n", "\n");
}

// Execute the JavaScript actually embedded in each workflow, without invoking actions, Git or publishing.
function snippets(name) {
  const lines = source(name).split("\n");
  const result = [];
  for (let index = 0; index < lines.length; index++) {
    const match = /^(\s*)run: \|$/u.exec(lines[index]);
    if (!match) continue;
    const indent = match[1].length;
    const block = [];
    for (index++; index < lines.length; index++) {
      if (lines[index].trim() && lines[index].search(/\S/u) <= indent) {
        index--;
        break;
      }
      block.push(lines[index].slice(indent + 2));
    }
    const node = /node(?: --input-type=module)? <<'NODE'\n([\s\S]*?)\nNODE/u.exec(block.join("\n"));
    if (node) result.push(node[1]);
  }
  return result;
}

function evaluate(code, { plan, environment = {}, checks, readError } = {}) {
  const reads = [];
  let output = "";
  const mockFs = {
    readFileSync(file) {
      reads.push(file);
      if (readError) throw readError;
      return JSON.stringify(plan);
    },
    appendFileSync(_file, value) { output += value; },
  };
  vm.runInNewContext(code, {
    require(name) {
      assert.equal(name, "node:fs");
      return mockFs;
    },
    process: {
      env: { GITHUB_OUTPUT: "output", CHECK_RESULTS: JSON.stringify(checks), ...environment },
      stdout: { write(value) { output += value; } },
    },
    console: { log() {} },
  });
  return { output, reads };
}

function gateChecks(selected) {
  const checks = {
    changes: {
      result: "success",
      outputs: { has_quality: selected, docker: selected, docs: selected, desktop_e2e: selected, unit_desktop: selected },
    },
  };
  for (const name of ["quality", "docker", "docs", "desktop", "desktop_macos"]) {
    checks[name] = { result: selected === "true" ? "success" : "skipped" };
  }
  return checks;
}

test("Engineering 读取共享计划全部检查开关，文档不创建代码 runner，实际需要才用双平台", () => {
  const workflow = source("engineering-quality");
  const [matrix] = snippets("engineering-quality");
  assert.ok(matrix);
  for (const flag of FLAGS.filter((flag) => !["frontend_image", "backend_image", "release"].includes(flag))) {
    assert.ok(workflow.includes(`${flag}: \${{ steps.plan.outputs.${flag} }}`), flag);
  }
  assert.match(workflow, /node scripts\/plan-checks\.cjs --ci --output preview_outputs\/change-plan\.json/u);
  for (const paths of [["README.md"], ["docs/architecture.md"]]) {
    const { output } = evaluate(matrix, { plan: planChanges(paths) });
    assert.match(output, /has_quality=false/u);
    assert.doesNotMatch(output, /windows-latest/u);
  }
  for (const paths of [["frontend/src/App.tsx"], ["backend/app.py"], ["scripts/install-hooks.cjs"]]) {
    const { output } = evaluate(matrix, { plan: planChanges(paths) });
    assert.match(output, /has_quality=true/u);
    assert.match(output, /windows-latest/u);
  }
  const { output } = evaluate(matrix, { plan: planChanges(["e2e/tests/generation.spec.js"]) });
  assert.match(output, /has_quality=true/u);
  assert.doesNotMatch(output, /windows-latest/u);
});

test("稳定 gate 始终执行，所有选中检查都必须成功，缺失选择与失败不能伪装为跳过", () => {
  const workflow = source("engineering-quality");
  const gate = snippets("engineering-quality")[1];
  assert.match(workflow, /name: Engineering quality gate\n\s+needs: \[changes, quality, docker, docs, desktop, desktop_macos\]\n\s+if: always\(\)/u);
  evaluate(gate, { checks: gateChecks("true") });
  evaluate(gate, { checks: gateChecks("false") });
  for (const name of ["quality", "docker", "docs", "desktop", "desktop_macos"]) {
    for (const result of ["skipped", "failure", "cancelled"]) {
      const checks = gateChecks("true");
      checks[name].result = result;
      assert.throws(() => evaluate(gate, { checks }), /did not succeed|failed or was cancelled/u, `${name}: ${result}`);
    }
    const checks = gateChecks("true");
    delete checks.changes.outputs[name === "quality" ? "has_quality" : name === "desktop" ? "desktop_e2e" : name === "desktop_macos" ? "unit_desktop" : name];
    assert.throws(() => evaluate(gate, { checks }), /Missing check selection/u);
  }
  const failedPlanning = gateChecks("false");
  failedPlanning.changes.result = "failure";
  assert.throws(() => evaluate(gate, { checks: failedPlanning }), /planning or commit-message validation failed/u);
  const unexpectedFailure = gateChecks("false");
  unexpectedFailure.docker.result = "failure";
  assert.throws(() => evaluate(gate, { checks: unexpectedFailure }), /failed or was cancelled/u);
});

test("桌面单测要求 macOS 原生回归，其他检查跳过不能替代它", () => {
  const workflow = source("engineering-quality");
  const gate = snippets("engineering-quality")[1];
  const job = workflow.split("\n  desktop_macos:\n")[1].split("\n  gate:\n")[0];
  assert.match(job, /if: needs\.changes\.outputs\.unit_desktop == 'true'/u);
  assert.match(job, /runs-on: macos-14/u);
  assert.match(job, /pnpm run test:desktop-storage/u);
  const checks = gateChecks("false");
  checks.changes.outputs.unit_desktop = "true";
  checks.desktop_macos.result = "success";
  evaluate(gate, { checks });
  for (const result of ["failure", "cancelled", "skipped"]) {
    checks.desktop_macos.result = result;
    assert.throws(() => evaluate(gate, { checks }), /did not succeed|failed or was cancelled/u);
  }
});

for (const [name, flag, outputKey] of [
  ["frontend", "frontend_image", "build"],
  ["backend", "backend_image", "build"],
  ["semantic_release", "release", "release"],
]) {
  test(`${name} 只消费同一次成功 push 的计划，核对 SHA 和布尔开关，缺失 artifact 失败关闭`, () => {
    const workflow = source(name);
    const code = snippets(name)[0];
    assert.match(workflow, /workflows: \["Engineering quality"\]/u);
    assert.match(workflow, /branches: \[custom-base\]/u);
    assert.match(workflow, /workflow_run\.conclusion == 'success'/u);
    assert.match(workflow, /workflow_run\.event == 'push'/u);
    assert.match(workflow, /workflow_run\.head_branch == 'custom-base'/u);
    assert.match(workflow, /workflow_run\.head_repository\.full_name == github\.repository/u);
    assert.match(workflow, /name: changed-path-plan/u);
    assert.match(workflow, /run-id: \$\{\{ github\.event\.workflow_run\.id \}\}/u);
    assert.match(workflow, /ref: \$\{\{ github\.event\.workflow_run\.head_sha \|\| 'custom-base' \}\}/u);
    const environment = { EVENT_NAME: "workflow_run", EXPECTED_SHA: "checked-sha" };
    for (const selected of [true, false]) {
      const { output } = evaluate(code, { plan: { head_sha: "checked-sha", [flag]: selected }, environment });
      assert.equal(output, `${outputKey}=${selected}\n`);
    }
    for (const plan of [
      { head_sha: "another-sha", [flag]: true },
      { head_sha: "checked-sha", [flag]: "true" },
      { head_sha: "checked-sha" },
    ]) {
      assert.throws(() => evaluate(code, { plan, environment }), /does not match/u);
    }
    assert.throws(() => evaluate(code, { environment, readError: new Error("artifact missing") }), /artifact missing/u);
    const manual = evaluate(code, { environment: { EVENT_NAME: "workflow_dispatch" }, readError: new Error("manual should not read") });
    assert.equal(manual.output, `${outputKey}=true\n`);
    assert.deepEqual(manual.reads, []);
    if (name !== "semantic_release") {
      const variable = `${name.toUpperCase()}_IMAGE`;
      assert.ok(workflow.includes(`vars.${variable} != ''`));
      assert.ok(workflow.includes(`tags: \${{ vars.${variable} }}`));
      assert.doesNotMatch(workflow, /14790897/u);
    }
  });
}

test("Desktop 只接受源运行自己的发布结果，空版本跳过，非法 tag 或错 run 必须拒绝", () => {
  const workflow = source("desktop_release");
  const code = snippets("desktop_release")[0];
  assert.match(workflow, /workflows: \["Semantic Release"\]/u);
  assert.match(workflow, /run-id: \$\{\{ github\.event\.workflow_run\.id \}\}/u);
  assert.match(workflow, /actions\/runs\/\$\{SOURCE_RUN_ID\}\/artifacts/u);
  assert.doesNotMatch(workflow, /published_at|releases\?per_page/u);
  assert.match(workflow, /if: needs\.resolve-tag\.outputs\.tag != ''/u);
  assert.match(workflow, /upload-release-assets\.sh/u);
  const environment = { SOURCE_RUN_ID: "123" };
  assert.equal(evaluate(code, { plan: { version: 1, run_id: "123", tag: "v1.2.3" }, environment }).output, "v1.2.3");
  assert.equal(evaluate(code, { plan: { version: 1, run_id: "123", tag: null }, environment }).output, "");
  for (const plan of [
    { version: 1, run_id: "another", tag: "v1.2.3" },
    { version: 2, run_id: "123", tag: "v1.2.3" },
    { version: 1, run_id: "123", tag: "v1.2.3\nmalicious" },
    { version: 1, run_id: "123" },
  ]) {
    assert.throws(() => evaluate(code, { plan, environment }));
  }
  // A failed GitHub API call is not an empty artifact list: set -e must propagate the failure.
  assert.match(workflow, /set -euo pipefail\n\s+COUNT="\$\(gh api/u);
});

test("Semantic API 显式使用已检出的 custom-base SHA，按真实返回值记录本次发布，未发布保留 null", async () => {
  const code = snippets("semantic_release")[1].replace(/^import .*;\n/gmu, "");
  assert.ok(code);
  for (const result of [false, { nextRelease: { gitTag: "v1.2.3" } }]) {
    let saved;
    const mockFs = {
      mkdirSync() {},
      writeFileSync(_file, value) { saved = JSON.parse(value); },
    };
    await new AsyncFunction("fs", "execFileSync", "semanticRelease", "process", code)(
      mockFs,
      (_command, args) => args[0] === "rev-parse" ? "checked-sha\n" : "1.2.3\n",
      async (_options, context) => {
        assert.equal(context.env.GITHUB_REF, "refs/heads/custom-base");
        assert.equal(context.env.GITHUB_SHA, "checked-sha");
        assert.equal(context.env.GITHUB_TOKEN, "retained-token");
        return result;
      },
      { env: { GITHUB_RUN_ID: "456", GITHUB_REF: "refs/heads/main", GITHUB_TOKEN: "retained-token" } },
    );
    assert.deepEqual(saved, { version: 1, run_id: "456", tag: result ? "v1.2.3" : null });
  }
  await assert.rejects(new AsyncFunction("fs", "execFileSync", "semanticRelease", "process", code)(
    { mkdirSync() {}, writeFileSync() { assert.fail("版本不符不能记录发布成功"); } },
    (_command, args) => args[0] === "rev-parse" ? "checked-sha" : "9.9.9",
    async () => ({ nextRelease: { gitTag: "v1.2.3" } }),
    { env: { GITHUB_RUN_ID: "456" } },
  ), /version do not match/u);
});

test("Python 与桌面打包使用独立 job，打包后不再执行会移除 build extra 的 uv 同步", () => {
  const workflow = source("engineering-quality");
  const quality = workflow.split("\n  quality:\n")[1].split("\n  docker:\n")[0];
  const desktop = workflow.split("\n  desktop:\n")[1].split("\n  desktop_macos:\n")[0];
  assert.match(quality, /NEEDS_PYTHON: .*outputs\.python == 'true'.*outputs\.unit_python == 'true'.*matrix\.os == 'ubuntu-latest'.*outputs\.e2e == 'true'/u);
  assert.match(quality, /if: env\.NEEDS_PYTHON == 'true'/u);
  assert.match(quality, /uv sync --locked --extra dev/u);
  assert.doesNotMatch(quality, /extra build|PyInstaller/u);
  assert.match(desktop, /runs-on: windows-latest/u);
  assert.match(desktop, /uv sync --locked --extra dev --extra build/u);
  assert.match(desktop, /bash desktop\/build\.sh --app-only --skip-deps/u);
  assert.doesNotMatch(desktop.split("run: bash desktop/build.sh --app-only --skip-deps")[1], /\buv (?:run|sync)\b/u);
  assert.match(desktop, /run: pnpm --filter handwriting-web-e2e run test:desktop/u);
});

// Included in the existing hook/CI policy entry point; no platform builds or
// GitHub mutations are performed by these isolated controller tests.
require("./flutter-release.test.cjs");

test("Flutter assets pin source and keep write permission out of build jobs", () => {
  const workflow = source("flutter_release");
  assert.match(workflow, /workflows: \["Semantic Release"\]/u);
  assert.match(workflow, /branches: \[custom-base\]/u);
  assert.match(workflow, /run-id: \$\{\{ github\.event\.workflow_run\.id \}\}/u);
  assert.match(workflow, /ref: \$\{\{ needs\.resolve\.outputs\.flutter_sha \}\}/u);
  assert.match(workflow, /ref: \$\{\{ github\.workflow_sha \}\}/u);
  assert.match(workflow, /node scripts\/flutter-release\.cjs resolve/u);
  assert.match(workflow, /upload-release-assets\.sh/u);
  assert.match(workflow, /EXPECTED_APP_VERSION=\$HANDWRITING_BUILD_VERSION/u);
  const desktop = workflow.split("\n  desktop:\n")[1].split("\n  android:\n")[0];
  const android = workflow.split("\n  android:\n")[1].split("\n  publish:\n")[0];
  assert.doesNotMatch(desktop + android, /contents: write|GH_TOKEN:/u);
  assert.match(android, /outputs\.android == 'true'/u);
  for (const secret of ["KEYSTORE_BASE64", "STORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD"]) {
    assert.ok(workflow.includes(`secrets.HANDWRITING_ANDROID_${secret} != ''`));
  }
  assert.match(android, /apksigner.*verify/u);
  assert.match(android, /aapt2.*dump badging/u);
  assert.match(android, /flutter-release\.cjs verify-apk/u);
  assert.match(android, /flutter build apk .*--split-per-abi .*--target-platform "\$TARGET_PLATFORM"/u);
  assert.match(android, /for ABI in arm64-v8a x86_64/u);
  assert.match(android, /native != \{sys.argv\[2\]\}/u);
  assert.match(android, /libhandwriting_bridge.so/u);
  assert.match(android, /cp scripts\/android-release-compat.gradle/u);
  const compatibility = fs.readFileSync(path.join(__dirname, "../android-release-compat.gradle"), "utf8");
  assert.match(compatibility, /finalizeDsl/u);
  assert.match(compatibility, /findProperty\('split-per-abi'\).*== 'true'/u);
  assert.match(compatibility, /defaultConfig.ndk.abiFilters.clear\(\)/u);
  assert.match(android, /CN=Android Debug/u);
  assert.doesNotMatch(workflow, /flutter build ipa|--clobber/u);
  const plan = planChanges([".github/workflows/flutter_release.yml"]);
  assert.equal(plan.hooks, true);
  assert.equal(plan.frontend, false);
  assert.equal(plan.desktop_e2e, false);
  assert.equal(plan.release, false);
});
