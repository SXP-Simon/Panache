"use strict";

const fs = require("node:fs");
const { execFileSync, spawnSync } = require("node:child_process");
const { MANIFEST, REQUIRED_WORKFLOWS, approvedRun, releaseVersion, sourceSha, validateManifest, waitForWorkflow } = require("./flutter-release.cjs");
const { releaseNotes } = require("./prepare-release.cjs");

function readReleaseCommit(sha, tag) {
  const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trimEnd();
  const changed = git("diff", "--name-only", sha + "^", sha).split("\n").sort();
  if (git("show", "-s", "--format=%s", sha) !== "chore(release): " + tag ||
      git("show", sha + ":VERSION") !== tag.slice(1) ||
      changed.join("\n") !== "CHANGELOG.md\nVERSION") {
    throw new Error("Expected a matching version commit updating VERSION and CHANGELOG.md.");
  }
  return releaseNotes(git("show", sha + ":CHANGELOG.md"), tag);
}

async function planRelease({ repository, sha, tag, signing }, io) {
  sourceSha(sha);
  const version = releaseVersion(tag);
  if (!await io.isAncestor(sha, "refs/remotes/origin/main")) {
    throw new Error("The tagged commit must be on main.");
  }
  const previous = await io.latest();
  const pin = previous.assets.find((asset) => asset.name === MANIFEST);
  if (!pin) throw new Error("The latest stable release has no Flutter source manifest.");
  const baseline = validateManifest(await io.manifest(pin.id), repository, previous.tag_name);
  if (sha === baseline.flutter_sha) {
    throw new Error("This Flutter commit was already released.");
  }
  if (!await io.isAncestor(baseline.flutter_sha, sha)) throw new Error("The tag must descend from the previous release.");
  if (version.build_number <= baseline.build_number) throw new Error("Release versions must increase.");

  const notes = io.notes(sha, tag);
  const qualityRuns = {};
  for (const workflow of REQUIRED_WORKFLOWS) {
    qualityRuns[workflow] = approvedRun(await io.runs(workflow, sha), sha, repository);
  }
  return {
    manifest: {
      schema_version: 1,
      repository,
      product_name: "Panache",
      release_tag: tag,
      ...version,
      flutter_sha: sha,
      quality_runs: qualityRuns,
      android_initial_status: signing ? "release-signing-configured" : "skipped-missing-release-signing-secrets",
      android_policy: "Release-signed APKs only.",
      ios_policy: "No IPA without distribution signing and provisioning.",
    },
    notes,
  };
}

function github(repository) {
  if (!/^[\w.-]+\/[\w.-]+$/u.test(repository ?? "")) throw new Error("Explicit GitHub repository is required.");
  const api = (route, ...args) => JSON.parse(execFileSync(
    "gh", ["api", "repos/" + repository + "/" + route, ...args], { encoding: "utf8" },
  ));
  const deadline = Date.now() + 30 * 60 * 1000;
  return {
    latest: () => api("releases/latest"),
    isAncestor: (base, head) => spawnSync("git", ["merge-base", "--is-ancestor", base, head]).status === 0,
    notes: readReleaseCommit,
    manifest: (id) => {
      if (!Number.isSafeInteger(id) || id < 1) throw new Error("Invalid manifest asset ID.");
      return api("releases/assets/" + id, "-H", "Accept: application/octet-stream");
    },
    runs: (workflow, sha) => waitForWorkflow({
      workflow, sha, repository, deadline,
      fetchRuns: () => api("actions/workflows/" + workflow + "/runs?head_sha=" + sha + "&per_page=100").workflow_runs,
      onWait: ({ status }) => console.log("Waiting for " + workflow + " at " + sha + ": " + status),
    }),
  };
}

async function main() {
  const repository = process.env.GITHUB_REPOSITORY;
  const signing = process.env.ANDROID_SIGNING_READY === "true";
  const plan = await planRelease({
    repository, sha: execFileSync("git", ["rev-parse", "HEAD^{commit}"], { encoding: "utf8" }).trim(),
    tag: process.env.RELEASE_TAG, signing,
  }, github(repository));
  const manifest = plan.manifest;
  fs.mkdirSync("release-plan", { recursive: true });
  fs.writeFileSync("release-plan/" + MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
  fs.writeFileSync("release-plan/notes.md", [
    "## Flutter / Rust", "",
    plan.notes, "",
    "Windows x64 · Linux x64 · macOS arm64" + (signing ? " · Android arm64 / x86_64" : ""),
    "",
    "Source: " + manifest.flutter_sha,
  ].join("\n") + "\n");
  fs.appendFileSync(process.env.GITHUB_OUTPUT, [
    "tag=" + manifest.release_tag,
    "version=" + manifest.version,
    "build_number=" + manifest.build_number,
    "flutter_sha=" + manifest.flutter_sha,
    "android=" + signing,
    "",
  ].join("\n"));
}

module.exports = { planRelease, readReleaseCommit };
if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
