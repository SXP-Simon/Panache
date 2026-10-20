"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const TEST_FILE = "e2e/desktop-tests/updates.spec.js";
const SHA = /^[0-9a-f]{40}$/u;

function applyHarness({ directory = process.cwd(), tag, harnessSha, workflowSha }) {
  if (!/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(tag || "")) throw new Error("Invalid release tag");
  if (!SHA.test(harnessSha || "") || !SHA.test(workflowSha || "")) throw new Error("Expected full 40-character commit SHAs");
  const git = (...arguments_) => execFileSync("git", arguments_, { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  const sourceSha = git("rev-parse", "--verify", `${tag}^{commit}`);
  if (git("rev-parse", "HEAD") !== sourceSha) throw new Error("Application checkout must remain at the release tag");
  for (const revision of [harnessSha, workflowSha]) {
    if (git("cat-file", "-t", revision) !== "commit") throw new Error("Harness references must identify commits");
  }
  // The dispatch workflow commit is the trust anchor; arbitrary branches cannot supply tests.
  git("merge-base", "--is-ancestor", harnessSha, workflowSha);
  const root = fs.realpathSync(directory);
  const target = path.join(root, TEST_FILE);
  for (const relative of ["e2e", "e2e/desktop-tests", TEST_FILE]) {
    if (fs.lstatSync(path.join(root, relative)).isSymbolicLink()) throw new Error("Harness destination cannot be a symbolic link");
  }
  const content = execFileSync("git", ["show", `${harnessSha}:${TEST_FILE}`], { cwd: root, maxBuffer: 1024 * 1024 });
  fs.writeFileSync(target, content);
  return { sourceSha, harnessSha, testFile: TEST_FILE };
}

if (require.main === module) {
  const [tag, harnessSha, workflowSha] = process.argv.slice(2);
  console.log(JSON.stringify(applyHarness({ tag, harnessSha, workflowSha })));
}
module.exports = { applyHarness, TEST_FILE };
