"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { planRelease } = require("../release-plan.cjs");
const { REQUIRED_WORKFLOWS, androidVersionCode, verifyAndroidPackage } = require("../flutter-release.cjs");

const repository = "SXP-Simon/Panache";
const oldSha = "a".repeat(40);
const sha = "b".repeat(40);
const stableTag = "v1.15.0";
const input = { repository, sha, signing: true, tag: "v1.16.0" };

function run(overrides = {}) {
  return {
    id: 2,
    head_sha: sha,
    head_branch: "main",
    event: "push",
    status: "completed",
    conclusion: "success",
    head_repository: { full_name: repository },
    ...overrides,
  };
}

function fixture() {
  return {
    isAncestor: () => true,
    latest: () => ({ tag_name: stableTag, assets: [{ id: 1, name: "Flutter-source.json" }] }),
    manifest: () => ({
      schema_version: 1,
      repository,
      release_tag: stableTag,
      product_name: "Panache",
      version: "1.15.0",
      build_number: 1_015_000,
      flutter_sha: oldSha,
      quality_runs: Object.fromEntries(REQUIRED_WORKFLOWS.map((name) => [name, { id: 1, head_sha: oldSha }])),
    }),
    notes: (target, tag) => {
      assert.equal(target, sha);
      return "Release notes for " + tag;
    },
    runs: (workflow, target) => {
      assert.ok(REQUIRED_WORKFLOWS.includes(workflow));
      assert.equal(target, sha);
      return [run()];
    },
  };
}

test("a release requires an explicitly supplied stable version", async () => {
  for (const tag of [undefined, "", "v1.16.0-beta.1"]) {
    await assert.rejects(planRelease({ ...input, tag }, fixture()), /stable semantic release tag/);
  }
});

test("a release pins exact successful main checks and preserves Android upgrade codes", async () => {
  const { manifest } = await planRelease(input, fixture());
  assert.equal(manifest.release_tag, "v1.16.0");
  assert.equal(manifest.flutter_sha, sha);
  assert.deepEqual(Object.keys(manifest.quality_runs), REQUIRED_WORKFLOWS);
  assert.equal(manifest.android_initial_status, "release-signing-configured");
  const versionCode = androidVersionCode(manifest.build_number, "android-arm64-v8a");
  assert.equal(verifyAndroidPackage(
    "package: name='io.github.sxpsimon.handwriting' versionCode='" + versionCode + "' versionName='1.16.0'",
    "android-arm64-v8a",
    manifest,
  ), versionCode);
});

test("missing, fork, old branch, PR, wrong SHA and unsuccessful checks cannot publish", async () => {
  for (const runs of [
    [],
    [run({ event: "pull_request" })],
    [run({ head_sha: oldSha })],
    [run({ head_branch: "flutter" })],
    [run({ head_repository: { full_name: "other/Panache" } })],
    [run(), run({ id: 3, conclusion: "failure" })],
  ]) {
    await assert.rejects(planRelease(input, { ...fixture(), runs: () => runs }), /required trusted workflow/);
  }
});

test("tag releases require main history, previous release ancestry, and an increasing version", async () => {
  const io = fixture();
  await assert.rejects(planRelease(input, { ...io, isAncestor: () => false }), /must be on main/);
  await assert.rejects(planRelease(input, { ...io, isAncestor: (base) => base !== oldSha }), /previous release/);
  await assert.rejects(planRelease({ ...input, sha: oldSha }, io), /already released/);
  await assert.rejects(planRelease({ ...input, tag: stableTag }, io), /must increase/);
  const { manifest } = await planRelease({ ...input, signing: false, tag: "v1.15.1" }, io);
  assert.equal(manifest.release_tag, "v1.15.1");
  assert.equal(manifest.android_initial_status, "skipped-missing-release-signing-secrets");
});

test("prepare a dedicated version commit and verify the tagged source after main advances", (t) => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "panache-version-test-"));
  t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
  const options = { cwd, encoding: "utf8" };
  const git = (...args) => execFileSync("git", args, options).trim();
  const write = (name, value) => fs.writeFileSync(path.join(cwd, name), value);
  const prepare = require.resolve("../prepare-release.cjs");
  const plan = require.resolve("../release-plan.cjs");
  const verify = (ref, tag) => spawnSync(process.execPath, [
    "-e", "console.log(require(process.argv[1]).readReleaseCommit(process.argv[2], process.argv[3]))",
    plan, ref, tag,
  ], options);
  git("init", "-q", "-b", "main");
  git("config", "user.name", "Release test");
  git("config", "user.email", "release@example.invalid");
  git("config", "commit.gpgsign", "false");
  git("config", "tag.gpgsign", "false");
  git("config", "core.hooksPath", ".unused-hooks");
  write("VERSION", "1.18.0\n");
  write("CHANGELOG.md", "## 未发布\n\n- Fix mobile layout.\n\n## v1.18.0 (2026-11-21)\n\n- Earlier change.\n");
  git("add", "VERSION", "CHANGELOG.md");
  git("commit", "-qm", "Initial version");
  write("another-file", "Independent change");
  git("add", "another-file");
  execFileSync(process.execPath, [prepare, "v1.18.1"], options);
  assert.equal(git("log", "-1", "--format=%s"), "chore(release): v1.18.1");
  assert.equal(git("show", "HEAD:VERSION"), "1.18.1");
  assert.equal(git("diff", "--cached", "--name-only"), "another-file");
  git("tag", "-a", "v1.18.1", "-m", "Panache v1.18.1");
  git("commit", "-qm", "Unrelated follow-up");
  const published = verify("v1.18.1^{commit}", "v1.18.1");
  assert.equal(published.status, 0, published.stderr);
  assert.equal(published.stdout.trim(), "- Fix mobile layout.");
  assert.notEqual(verify("HEAD", "v1.18.1").status, 0);
  assert.notEqual(verify("v1.18.1^{commit}", "v1.18.2").status, 0);
  assert.notEqual(spawnSync(process.execPath, [prepare, "v1.18.2"], options).status, 0);
  assert.equal(git("status", "--porcelain"), "");
});
