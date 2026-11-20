"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { nextTag, planRelease } = require("../release-plan.cjs");
const { REQUIRED_WORKFLOWS, androidVersionCode, verifyAndroidPackage } = require("../flutter-release.cjs");

const repository = "SXP-Simon/Panache";
const oldSha = "a".repeat(40);
const sha = "b".repeat(40);
const stableTag = "v1.15.0";
const input = { repository, sha, signing: true };

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
    mainSha: () => sha,
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
    history: (from, to) => {
      assert.deepEqual([from, to], [oldSha, sha]);
      return [{ subject: "feat(app): add tool", body: "" }];
    },
    runs: (workflow, target) => {
      assert.ok(REQUIRED_WORKFLOWS.includes(workflow));
      assert.equal(target, sha);
      return [run()];
    },
  };
}

test("versions continue from the shipped Flutter manifest and follow conventional commits", () => {
  const commit = (subject, body = "") => ({ subject, body });
  assert.equal(nextTag(stableTag, [commit("ci: migrate branches")]), null);
  assert.equal(nextTag(stableTag, [commit("fix(app): restore preview")]), "v1.15.1");
  assert.equal(nextTag(stableTag, [commit("feat(app): improve preview")]), "v1.16.0");
  assert.equal(nextTag(stableTag, [commit("feat!: change format")]), "v2.0.0");
  assert.equal(nextTag(stableTag, [commit("feat: change format", "BREAKING CHANGE: format")]), "v2.0.0");
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

test("migration-only or superseded pushes skip automatic releases and manual tags must increase", async () => {
  const io = { ...fixture(), history: () => [{ subject: "ci: migrate release", body: "" }] };
  assert.equal(await planRelease(input, io), null);
  assert.equal(await planRelease(input, { ...fixture(), mainSha: () => oldSha }), null);
  await assert.rejects(planRelease({ ...input, manualTag: stableTag }, io), /must increase/);
  const { manifest } = await planRelease({ ...input, signing: false, manualTag: "v1.15.1" }, io);
  assert.equal(manifest.release_tag, "v1.15.1");
  assert.equal(manifest.android_initial_status, "skipped-missing-release-signing-secrets");
});
