const test = require("node:test");
const assert = require("node:assert/strict");
const skipMarkdownBuild = require("./markdown-update.cjs");

const pull = { number: 14, head: { sha: "new", ref: "feature", repo: { id: 1 } }, base: { sha: "main" } };
const green = {
  display_title: "PR #14 · base main", status: "completed", conclusion: "success",
  head_branch: "feature", head_repository: { id: 1 }, html_url: "previous-run",
};

async function check({
  files = [{ filename: "app/guide.md" }], status = "ahead", runs = [green],
  action = "synchronize", workflow = "rust.yml", unavailable = false,
} = {}) {
  const github = { rest: {
    repos: { compareCommitsWithBasehead: async ({ basehead }) => {
      assert.equal(basehead, "old...new");
      if (unavailable) throw new Error("compare unavailable");
      return { data: { files, status } };
    } },
    actions: { listWorkflowRuns: async ({ head_sha, workflow_id }) => {
      assert.equal(head_sha, "old");
      assert.equal(workflow_id, workflow);
      return { data: { workflow_runs: runs } };
    } },
  } };
  const context = { repo: { owner: "owner", repo: "repo" }, payload: { action, before: "old", pull_request: pull } };
  return skipMarkdownBuild({ github, context, core: { notice() {}, warning() {} } }, workflow);
}

test("ordinary Markdown can reuse a successful check on the same PR and base", async () => {
  assert.equal(await check({ files: [{ filename: "README.md" }, { filename: "crates/guide.md" }] }), true);
  assert.equal(await check({ files: [{ status: "renamed", filename: "new.md", previous_filename: "old.md" }] }), true);
});

test("mixed updates, packaged files and renames from code need a build", async () => {
  for (const name of ["app/lib/main.dart", "assets/licenses/FONT-LICENSES.md", "assets/font_assets/info.md",
    "crates/handwriting-core/licenses/OFL.md", "deploy/rust/README.md"]) {
    assert.equal(await check({ files: [{ filename: "guide.md" }, { filename: name }] }), false, name);
  }
  assert.equal(await check({ files: [{ status: "renamed", filename: "guide.md", previous_filename: "src/code.rs" }] }), false);
  assert.equal(await check({ files: [{ status: "renamed", filename: "guide.md", previous_filename: "deploy/rust/README.md" }] }), false);
  assert.equal(await check({ files: [{ filename: "deploy/rust/README.md" }], workflow: "flutter.yml" }), true);
});

test("only proven checks can be reused", async () => {
  for (const options of [
    { action: "opened" }, { status: "diverged" }, { files: [] }, { unavailable: true },
    { files: Array(300).fill({ filename: "guide.md" }) }, { runs: [] },
    { runs: [{ ...green, display_title: "PR #14 · base another-base" }] },
    { runs: [{ ...green, conclusion: "cancelled" }, green] },
    { runs: [{ ...green, status: "in_progress", conclusion: null }] },
    { runs: [{ ...green, head_repository: { id: 2 } }] },
  ]) assert.equal(await check(options), false);
});
