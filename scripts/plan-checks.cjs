#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { FLAGS, planChanges } = require("./change-impact.cjs");
const { head, staged, ciChanges, pushChanges } = require("./git-change-set.cjs");

function readPlan(args, environment = process.env, cwd = process.cwd(), input = "") {
  if (args.length !== 1 || !["--all", "--staged", "--ci", "--push"].includes(args[0]))
    throw new Error("Choose exactly one of --all / --staged / --ci / --push");
  const mode = args[0];
  const changes = mode === "--staged" ? staged(cwd) : mode === "--ci" ? ciChanges(environment, cwd)
    : mode === "--push" ? pushChanges(input, cwd)
      : { paths: [], full: true, reason: "explicit full validation", head_sha: head(cwd) };
  return planChanges(changes.paths, changes);
}
function main(args, environment = process.env) {
  const allowed = new Set(["--all", "--staged", "--ci", "--push"]);
  let output;
  const modes = [];
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === "--output") {
      output = args[++index];
      if (!output) throw new Error("Missing --output path");
    } else if (allowed.has(arg)) modes.push(arg);
    else throw new Error(`Unknown planner argument: ${arg}`);
  }
  const plan = readPlan(modes, environment, process.cwd(), modes.includes("--push") ? fs.readFileSync(0, "utf8") : "");
  const serialized = JSON.stringify(plan, null, 2) + "\n";
  if (output) {
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, serialized);
  }
  if (environment.GITHUB_OUTPUT) fs.appendFileSync(environment.GITHUB_OUTPUT,
    [...FLAGS.map((key) => `${key}=${plan[key]}`), `head_sha=${plan.head_sha}`, ""].join("\n"));
  process.stdout.write(serialized);
  return 0;
}
if (require.main === module) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { console.error(`检查范围规划失败：${error.message}`); process.exitCode = 1; }
}
module.exports = { FLAGS, planChanges, readPlan, main };
