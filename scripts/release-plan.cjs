"use strict";

const fs = require("node:fs");
const { execFileSync, spawnSync } = require("node:child_process");
const { MANIFEST, REQUIRED_WORKFLOWS, approvedRun, releaseVersion, sourceSha, validateManifest, waitForWorkflow } = require("./flutter-release.cjs");

async function planRelease({ repository, sha, manualTag, signing }, io) {
  sourceSha(sha);
  const version = releaseVersion(manualTag);
  if (await io.mainSha() !== sha) {
    throw new Error("Manual releases require the current main commit.");
  }
  const previous = await io.latest();
  const pin = previous.assets.find((asset) => asset.name === MANIFEST);
  if (!pin) throw new Error("The latest stable release has no Flutter source manifest.");
  const baseline = validateManifest(await io.manifest(pin.id), repository, previous.tag_name);
  if (sha === baseline.flutter_sha) {
    throw new Error("This Flutter commit was already released.");
  }
  const commits = await io.history(baseline.flutter_sha, sha);
  if (version.build_number <= baseline.build_number) throw new Error("Release versions must increase.");

  const qualityRuns = {};
  for (const workflow of REQUIRED_WORKFLOWS) {
    qualityRuns[workflow] = approvedRun(await io.runs(workflow, sha), sha, repository);
  }
  return {
    manifest: {
      schema_version: 1,
      repository,
      product_name: "Panache",
      release_tag: manualTag,
      ...version,
      flutter_sha: sha,
      quality_runs: qualityRuns,
      android_initial_status: signing ? "release-signing-configured" : "skipped-missing-release-signing-secrets",
      android_policy: "Release-signed APKs only.",
      ios_policy: "No IPA without distribution signing and provisioning.",
    },
    previousTag: previous.tag_name,
    commits,
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
    mainSha: () => api("git/ref/heads/main").object.sha,
    manifest: (id) => {
      if (!Number.isSafeInteger(id) || id < 1) throw new Error("Invalid manifest asset ID.");
      return api("releases/assets/" + id, "-H", "Accept: application/octet-stream");
    },
    history: (base, sha) => {
      if (spawnSync("git", ["merge-base", "--is-ancestor", base, sha]).status !== 0) {
        throw new Error("The previous Flutter release is not in main history.");
      }
      const fields = execFileSync("git", [
        "log", "--format=%s%x00%b%x00", base + ".." + sha, "--",
        "app", "crates", "assets", "vendor", "Cargo.toml", "Cargo.lock",
      ], { encoding: "utf8" }).split("\0");
      const commits = [];
      for (let i = 0; i + 1 < fields.length; i += 2) {
        commits.push({ subject: fields[i].trim(), body: fields[i + 1] });
      }
      return commits;
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
    repository, sha: process.env.SOURCE_SHA, manualTag: process.env.MANUAL_TAG, signing,
  }, github(repository));
  const manifest = plan.manifest;
  fs.mkdirSync("release-plan", { recursive: true });
  fs.writeFileSync("release-plan/" + MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
  const changes = plan.commits.map(({ subject }) => "- " + subject);
  fs.writeFileSync("release-plan/notes.md", [
    "## Flutter / Rust", "",
    ...changes, "",
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

module.exports = { planRelease };
if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
