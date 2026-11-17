#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const { readPlan } = require("./plan-checks.cjs");
const { dirtyPaths } = require("./git-change-set.cjs");
const { runQualityChecks, qualityCommands, assertCleanInputs } = require("./run-quality-checks.cjs");

function testCommands(plan, { unitOnly = false } = {}) {
  const units = [
    ...(plan.hooks ? ["pnpm run test:hooks"] : []),
    ...(plan.unit_frontend ? ["pnpm run test:frontend"] : []),
    ...(plan.unit_python ? ["uv run --extra dev python -m pytest backend/tests"] : []),
    ...(plan.unit_desktop ? ["pnpm run test:desktop-storage", "pnpm run test:desktop-updater"] : []),
  ];
  if (unitOnly) return units;
  return [
    ...units,
    ...(plan.build || plan.sw_upgrade || plan.e2e ? ["pnpm --filter handwrite run build"] : []),
    ...(plan.sw_upgrade ? ["pnpm run test:sw-upgrade"] : []),
    ...(plan.e2e ? ["pnpm --filter handwriting-web-e2e run test"] : []),
    ...(plan.docs ? ["uv tool run --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict"] : []),
    // Packaging synchronizes the build extra, so keep it after checks using the dev environment.
    ...(plan.desktop_e2e ? ["node scripts/run-desktop-tests.cjs"] : []),
  ];
}
function prePushChecks(plan) {
  const quick = !plan.full && !plan.scopes.includes("shared");
  const commands = [...new Set([...qualityCommands(plan), ...testCommands(plan, { unitOnly: quick })])];
  const inputs = quick
    ? ["frontend", "python", "hooks", "unit_frontend", "unit_python", "unit_desktop"]
    : undefined;
  return { commands, inputs };
}

function main(args, input = "", { fromHook = false } = {}) {
  const plan = readPlan(args, process.env, process.cwd(), input);
  const { commands, inputs } = fromHook ? prePushChecks(plan) : { commands: testCommands(plan) };
  if (commands.length && (args.includes("--push") || args.includes("--staged"))) {
    assertCleanInputs(plan, dirtyPaths(undefined, { includeStaged: args.includes("--push") }), inputs);
  }
  console.log(`变更范围：${plan.scopes.join(", ") || "无文件变化"}；${plan.reason}；选择 ${commands.length} 项验证。`);
  return runQualityChecks(undefined, undefined, commands);
}
if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    process.exitCode = main(args, args.includes("--push") ? fs.readFileSync(0, "utf8") : "");
  } catch (error) { console.error(`按需测试失败：${error.message}`); process.exitCode = 1; }
}
module.exports = { testCommands, prePushChecks, main };
