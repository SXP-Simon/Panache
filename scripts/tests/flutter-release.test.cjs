"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { REQUIRED_WORKFLOWS, releaseVersion, sourceSha, targetTag, validateManifest, validatePinnedManifest, approvedRun, resolveRelease, stagePackage, verifyPackages, waitForWorkflow } = require("../flutter-release.cjs");

const repository = "owner/fork";
const sha = "a".repeat(40);
const anotherSha = "b".repeat(40);
const tag = "v1.2.3";
const input = { event: "workflow_run", result: { version: 1, run_id: "42", tag }, sourceRunId: "42", repository };
function run(overrides = {}) {
  return { id: 123, head_sha: sha, head_branch: "flutter", event: "push", status: "completed", conclusion: "success", head_repository: { full_name: repository }, html_url: "https://example.invalid/run/123", ...overrides };
}
function ioFixture() {
  const writes = [];
  const refs = [];
  const files = {
    "backend/VERSION": "1.2.3\n",
    "desktop/package.json": JSON.stringify({ build: { productName: "HandwritingWeb" } }),
    "scripts/build-flutter-desktop.py": "--version --build-number HANDWRITING_BUILD_VERSION",
    "crates/handwriting-core/src/lib.rs": "pub fn app_version() HANDWRITING_BUILD_VERSION",
    "crates/handwriting-bridge/src/api.rs": "handwriting_core::app_version()",
    "crates/handwriting-server/src/lib.rs": "handwriting_core::app_version()",
    "scripts/embed-macos-backend.sh": "HANDWRITING_BUILD_VERSION",
    "app/android/app/build.gradle.kts": "HANDWRITING_ANDROID_KEYSTORE_PATH HANDWRITING_ANDROID_STORE_PASSWORD HANDWRITING_ANDROID_KEY_ALIAS HANDWRITING_ANDROID_KEY_PASSWORD",
  };
  return {
    writes, refs, files,
    release: async () => ({ tag_name: tag, draft: false, assets: [] }),
    file: async (name, ref) => { refs.push([name, ref]); return files[name]; },
    branchSha: async () => sha,
    runs: async () => [run()],
    publishManifest: async (target, manifest) => writes.push([target, manifest]),
  };
}

function manifest() {
  return {
    schema_version: 1, repository, release_tag: tag, version: "1.2.3", build_number: 1_002_003,
    flutter_sha: sha, quality_runs: Object.fromEntries(REQUIRED_WORKFLOWS.map((name) => [name, { id: 123, head_sha: sha }])),
  };
}

test("stable release versions produce reproducible bounded Android build numbers", () => {
  assert.deepEqual(releaseVersion(tag), { version: "1.2.3", build_number: 1_002_003 });
  assert.deepEqual(releaseVersion("v0.0.1"), { version: "0.0.1", build_number: 1 });
  for (const invalid of ["v0.0.0", "v1.1000.0", "v1.2.1000", "v2101.0.0", "v1.2.3-rc.1", "v01.2.3", "v1.2.3\n"]) assert.throws(() => releaseVersion(invalid));
  for (const invalid of ["flutter", "main", "abc", "A".repeat(40), `${sha}\n`]) assert.throws(() => sourceSha(invalid));
});

test("only exact Semantic Release artifacts select an automatic tag; null does no network work", async () => {
  for (const result of [{ version: 1, run_id: "other", tag }, { version: 2, run_id: "42", tag }, { version: 1, run_id: "42" }]) {
    assert.throws(() => targetTag({ ...input, result }));
  }
  assert.equal(await resolveRelease({ ...input, result: { version: 1, run_id: "42", tag: null } }, {}), null);
});

test("first automatic build pins exact source and all three passing push runs before any build", async () => {
  const io = ioFixture();
  const result = await resolveRelease(input, io);
  assert.equal(result.flutter_sha, sha);
  assert.equal(result.android_initial_status, "skipped-missing-release-signing-secrets");
  assert.equal(io.writes.length, 1);
  assert.deepEqual(Object.keys(result.quality_runs), REQUIRED_WORKFLOWS);
  assert.ok(io.refs.filter(([name]) => !["backend/VERSION", "desktop/package.json"].includes(name)).every(([, ref]) => ref === sha));
  validateManifest(result, repository, tag);
});

test("missing, pending, failed, fork, PR and older passing checks cannot authorize source", async () => {
  for (const overrides of [{ status: "in_progress" }, { conclusion: "failure" }, { event: "pull_request" }, { head_branch: "custom-base" }, { head_sha: anotherSha }, { head_repository: { full_name: "untrusted/fork" } }, { id: 0 }]) {
    assert.throws(() => approvedRun([run(overrides)], sha, repository));
  }
  assert.throws(() => approvedRun([run(), run({ id: 124, conclusion: "failure" })], sha, repository));
  for (const missing of REQUIRED_WORKFLOWS) {
    const io = ioFixture();
    io.runs = async (workflow) => workflow === missing ? [] : [run()];
    await assert.rejects(resolveRelease(input, io));
    assert.equal(io.writes.length, 0);
  }
});

test("manual first build requires full SHA and retries reuse immutable manifest without reading branch", async () => {
  const io = ioFixture();
  await assert.rejects(resolveRelease({ ...input, event: "workflow_dispatch", manualTag: tag }, io), /explicit full/);
  const first = await resolveRelease({ ...input, event: "workflow_dispatch", manualTag: tag, manualSha: sha }, io);
  io.release = async () => ({ tag_name: tag, draft: false, assets: [{ name: "Flutter-source.json", id: 10 }] });
  io.manifest = async () => first;
  io.branchSha = () => { throw new Error("retry cannot read latest branch"); };
  io.publishManifest = () => { throw new Error("retry cannot rewrite source manifest"); };
  assert.equal((await resolveRelease({ ...input, event: "workflow_dispatch", manualTag: tag }, io)).flutter_sha, sha);
  await assert.rejects(resolveRelease({ ...input, manualSha: anotherSha }, io), /cannot be replaced/);
});

test("invalid target/version/source contract or provenance must fail before writing a manifest", async () => {
  for (const mutate of [
    (io) => { io.release = async () => ({ tag_name: tag, draft: true, assets: [] }); },
    (io) => { io.files["backend/VERSION"] = "9.9.9"; },
    (io) => { io.files["scripts/build-flutter-desktop.py"] = "old script"; },
    (io) => { io.files["crates/handwriting-core/src/lib.rs"] = "old core"; },
    (io) => { io.files["app/android/app/build.gradle.kts"] = "debug signing"; },
    (io) => { io.files["crates/handwriting-bridge/src/api.rs"] = "old bridge version"; },
    (io) => { io.files["crates/handwriting-server/src/lib.rs"] = "old server version"; },
    (io) => { io.files["scripts/embed-macos-backend.sh"] = "old mac embed version"; },
  ]) {
    const io = ioFixture(); mutate(io);
    await assert.rejects(resolveRelease(input, io));
    assert.equal(io.writes.length, 0);
  }
  for (const changes of [{ flutter_sha: "flutter" }, { release_tag: "v9.9.9" }, { repository: "another/fork" }, { build_number: 7 }, { quality_runs: {} }]) assert.throws(() => validateManifest({ ...manifest(), ...changes }, repository, tag));
});

test("all three platform archives have pinned provenance and tampering fails closed", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "flutter-release-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, "staged");
  const platforms = [["windows-x64", ".zip"], ["linux-x64", ".tar.gz"], ["macos-arm64", ".zip"]];
  for (const [platform, extension] of platforms) {
    const file = path.join(root, `${platform}${extension}`);
    fs.writeFileSync(file, `package for ${platform}`);
    stagePackage(file, output, platform, manifest());
  }
  assert.equal(verifyPackages(output, manifest(), false).length, 6);
  assert.throws(() => verifyPackages(output, manifest(), true), /complete expected/);
  const archive = fs.readdirSync(output).find((file) => file.endsWith(".zip"));
  fs.appendFileSync(path.join(output, archive), "tampered");
  assert.throws(() => verifyPackages(output, manifest(), false), /checksum/);
});

test("signed APK set is distinct and cannot be silently added to unsigned release plan", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "flutter-release-apk-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const output = path.join(root, "staged");
  for (const [platform, extension] of [["windows-x64", ".zip"], ["linux-x64", ".tar.gz"], ["macos-arm64", ".zip"], ["android-arm64-v8a", ".apk"], ["android-x86_64", ".apk"]]) {
    const file = path.join(root, `${platform}${extension}`);
    fs.writeFileSync(file, "package");
    stagePackage(file, output, platform, manifest());
  }
  assert.equal(verifyPackages(output, manifest(), true).length, 10);
  const x86 = `Flutter-HandwritingWeb-${manifest().version}-android-x86_64.apk`;
  const saved = fs.readFileSync(path.join(output, x86 + '.json'));
  fs.unlinkSync(path.join(output, x86 + '.json'));
  assert.throws(() => verifyPackages(output, manifest(), true), /complete expected/);
  fs.writeFileSync(path.join(output, x86 + '.json'), saved);
  assert.throws(() => stagePackage(path.join(root, 'android-arm64-v8a.apk'), output, 'android-arm64-x64', manifest()), /Unsupported/);

  assert.throws(() => verifyPackages(output, manifest(), false), /complete expected/);
});


test("pending exact-SHA checks wait with injected time while terminal failures return immediately", async () => {
  let now = 0;
  const states = ["queued", "in_progress", "completed"];
  const waits = [];
  const announcements = [];
  const runs = await waitForWorkflow({
    workflow: "flutter_mobile.yml", sha, repository,
    now: () => now,
    fetchRuns: async () => [run({ status: states.shift() })],
    sleep: async (ms) => { waits.push(ms); now += ms; },
    onWait: (event) => announcements.push(event),
  });
  assert.equal(approvedRun(runs, sha, repository).head_sha, sha);
  assert.deepEqual(waits, [30_000, 30_000]);
  assert.deepEqual(announcements.map((event) => event.status), ["queued", "in_progress"]);
  for (const conclusion of ["failure", "cancelled", "timed_out"]) {
    const terminal = await waitForWorkflow({
      workflow: "flutter_mobile.yml", sha, repository,
      fetchRuns: async () => [run({ conclusion })],
      sleep: () => assert.fail("terminal failure must never wait"),
    });
    assert.throws(() => approvedRun(terminal, sha, repository));
  }
});

test("missing checks receive 90-second scheduling grace and pending checks share a bounded deadline", async () => {
  for (const missing of [true, false]) {
    let now = 0;
    let sleeps = 0;
    await assert.rejects(waitForWorkflow({
      workflow: "rust.yml", sha, repository,
      now: () => now,
      deadline: 30 * 60 * 1000,
      fetchRuns: async () => missing ? [] : [run({ status: "in_progress" })],
      sleep: async (ms) => { now += ms; sleeps++; },
    }), missing ? /scheduling grace/ : /Timed out/);
    assert.equal(now, missing ? 90_000 : 1_800_000);
    assert.equal(sleeps, missing ? 3 : 60);
  }
});

test("waiting never re-resolves a moving branch or swallows a GitHub API failure", async () => {
  const io = ioFixture();
  let branchReads = 0;
  let clock = 0;
  let polls = 0;
  io.branchSha = async () => { branchReads++; return branchReads === 1 ? sha : anotherSha; };
  io.runs = (workflow, fixedSha) => waitForWorkflow({
    workflow, sha: fixedSha, repository,
    now: () => clock,
    fetchRuns: async () => [run({ status: ++polls === 1 ? "in_progress" : "completed" })],
    sleep: async (ms) => { clock += ms; },
  });
  assert.equal((await resolveRelease(input, io)).flutter_sha, sha);
  assert.equal(branchReads, 1);
  assert.equal(clock, 30_000);
  await assert.rejects(waitForWorkflow({
    workflow: "rust.yml", sha, repository,
    fetchRuns: () => { throw new Error("GitHub API unavailable"); },
    sleep: () => assert.fail("API failures are not missing workflow runs"),
  }), /API unavailable/);
});


test("exact same-repository manual checks can satisfy path-filtered workflows without hiding newer failures", () => {
  const manual = run({ id: 124, event: "workflow_dispatch" });
  assert.equal(approvedRun([run(), manual], sha, repository).event, "workflow_dispatch");
  assert.throws(() => approvedRun([run(), { ...manual, conclusion: "failure" }], sha, repository));
  assert.throws(() => approvedRun([run(), { ...manual, status: "in_progress" }], sha, repository));
  assert.throws(() => approvedRun([{ ...manual, head_repository: { full_name: "external/fork" } }], sha, repository));
});


test("automatic retries without a manifest cannot drift to a newly advanced source branch", async () => {
  const io = ioFixture();
  io.branchSha = () => assert.fail("retry must not resolve latest Flutter branch");
  await assert.rejects(resolveRelease({ ...input, runAttempt: "2" }, io), /original full Flutter SHA/);
  assert.equal(io.writes.length, 0);
});


test("Panache source manifests freeze download names while legacy manifests retain their names", async (t) => {
  const io = ioFixture();
  io.files["desktop/package.json"] = JSON.stringify({ build: { productName: "Panache" } });
  const modern = await resolveRelease(input, io);
  assert.equal(modern.product_name, "Panache");
  validateManifest(modern, repository, tag);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "panache-release-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, "input.zip");
  fs.writeFileSync(file, "archive");
  assert.equal(path.basename(stagePackage(file, path.join(root, "modern"), "windows-x64", modern)), "Flutter-Panache-1.2.3-windows-x64.zip");
  assert.equal(path.basename(stagePackage(file, path.join(root, "legacy"), "windows-x64", manifest())), "Flutter-HandwritingWeb-1.2.3-windows-x64.zip");
  assert.throws(() => validateManifest({ ...modern, product_name: "../bad" }, repository, tag), /product name/);
  const guide = require("../append-release-notes.js").downloadGuide;
  const packageJson = require("../../desktop/package.json");
  const notes = guide(packageJson.build.productName, "1.2.3");
  assert.equal(packageJson.build.productName, "Panache");
  assert.equal(packageJson.build.appId, "io.github.sxp-simon.handwriting");
  assert.ok(notes.includes(packageJson.build.nsis.artifactName.replace("${version}", "1.2.3")));
  assert.ok(notes.includes("Flutter-Panache-1.2.3-android-arm64-v8a.apk"));
  assert.ok(notes.includes("/Applications/Panache.app"));
  assert.ok(guide("HandwritingWeb", "1.2.3").includes("HandwritingWeb-Setup-1.2.3.exe"));
});


test("historical names require matching live GitHub repository IDs, never an alias allowlist", async () => {
  const old = { ...manifest(), repository: "owner/old-name" };
  const canonical = { id: 123456, full_name: repository };
  const lookups = [];
  const io = { repositoryInfo: async (name) => { lookups.push(name); return canonical; } };
  assert.equal(await validatePinnedManifest(old, repository, tag, io), old);
  assert.deepEqual(lookups.sort(), [repository, old.repository].sort());
  assert.equal(old.repository, "owner/old-name");
  await assert.rejects(validatePinnedManifest(old, repository, tag, {}), /does not match/);
  await assert.rejects(validatePinnedManifest(old, repository, tag, { repositoryInfo: async (name) => ({ ...canonical, id: name === repository ? 123456 : 654321 }) }), /identity/);
  await assert.rejects(validatePinnedManifest(old, repository, tag, { repositoryInfo: async (name) => ({ ...canonical, full_name: name }) }), /identity/);
  await assert.rejects(validatePinnedManifest(old, repository, tag, { repositoryInfo: async () => { throw new Error("GitHub unavailable"); } }), /GitHub unavailable/);
  await assert.rejects(validatePinnedManifest({ ...old, repository: "../invalid" }, repository, tag, io), /does not match/);
  const pin = ioFixture();
  pin.release = async () => ({ tag_name: tag, draft: false, assets: [{ name: "Flutter-source.json", id: 10 }] });
  pin.manifest = async () => old;
  pin.repositoryInfo = io.repositoryInfo;
  pin.branchSha = () => { throw new Error("cannot re-resolve source after rename"); };
  assert.equal((await resolveRelease(input, pin)).repository, old.repository);
  assert.equal(pin.writes.length, 0);
});
