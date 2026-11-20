"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const MANIFEST = "Flutter-source.json";
const REQUIRED_WORKFLOWS = ["flutter.yml", "rust.yml", "flutter_mobile.yml"];
const PLATFORMS = ["windows-x64", "linux-x64", "macos-arm64", "android-arm64-v8a", "android-x86_64"];

function releaseVersion(tag) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u.exec(tag ?? "");
  if (!match) throw new Error("Flutter assets require a stable semantic release tag.");
  const [major, minor, patch] = match.slice(1).map(Number);
  const buildNumber = major * 1_000_000 + minor * 1_000 + patch;
  if (minor >= 1000 || patch >= 1000 || !Number.isSafeInteger(buildNumber) || buildNumber < 1 || buildNumber > 2_100_000_000) {
    throw new Error("Release version exceeds the supported Android version-code range.");
  }
  return { version: tag.slice(1), build_number: buildNumber };
}

// Flutter ABI splits retain their historical version-code offsets so installed APKs can upgrade.
function androidVersionCode(buildNumber, platform) {
  const offset = { "android-arm64-v8a": 2000, "android-x86_64": 4000 }[platform];
  if (offset === undefined || !Number.isSafeInteger(buildNumber) || buildNumber < 1 || buildNumber + offset > 2_100_000_000) {
    throw new Error("Invalid Android ABI version code.");
  }
  return buildNumber + offset;
}

function verifyAndroidPackage(badging, platform, manifest) {
  const header = /^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'(?: |$)/u.exec(badging);
  if (!header || header[1] !== "io.github.sxpsimon.handwriting" || header[3] !== manifest.version || Number(header[2]) !== androidVersionCode(manifest.build_number, platform)) {
    throw new Error("APK identity or version code does not match the update contract.");
  }
  return Number(header[2]);
}

function sourceSha(value) {
  if (!/^[a-f0-9]{40}$/u.test(value ?? "")) throw new Error("Flutter source must be a full lowercase 40-character commit SHA.");
  return value;
}

function productName(manifest) {
  const name = manifest.product_name;
  if (!["Panache", "HandwritingWeb"].includes(name)) throw new Error("Unsupported immutable release product name.");
  return name;
}

function validateManifest(manifest, repository, tag) {
  const version = releaseVersion(tag);
  if (manifest?.schema_version !== 1 || manifest.repository !== repository || manifest.release_tag !== tag || manifest.version !== version.version || manifest.build_number !== version.build_number) {
    throw new Error("The immutable Flutter source manifest does not match this release.");
  }
  productName(manifest);
  sourceSha(manifest.flutter_sha);
  for (const workflow of REQUIRED_WORKFLOWS) {
    const run = manifest.quality_runs?.[workflow];
    if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || run.head_sha !== manifest.flutter_sha) {
      throw new Error("The source manifest is missing exact successful workflow provenance.");
    }
  }
  return manifest;
}

function latestRun(runs, sha, repository) {
  const matching = runs.filter((run) => run.head_sha === sha && run.head_branch === "main" && ["push", "workflow_dispatch"].includes(run.event) && run.head_repository?.full_name === repository);
  matching.sort((a, b) => b.id - a.id);
  return matching[0];
}

function approvedRun(runs, sha, repository) {
  const run = latestRun(runs, sha, repository);
  if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || run.status !== "completed" || run.conclusion !== "success") {
    throw new Error(`Exact Flutter source ${sha} has a missing, pending or unsuccessful required trusted workflow.`);
  }
  return { id: run.id, head_sha: sha, event: run.event, url: run.html_url };
}

async function waitForWorkflow({ workflow, sha, repository, fetchRuns, deadline, now = Date.now, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)), onWait = () => {} }) {
  let missingSince;
  let lastStatus;
  const until = deadline ?? now() + 30 * 60 * 1000;
  while (true) {
    const runs = await fetchRuns();
    const run = latestRun(runs, sha, repository);
    // Terminal failures return immediately; approvedRun rejects their result.
    if (run?.status === "completed") return runs;
    const at = now();
    if (at >= until) throw new Error(`Timed out waiting for ${workflow} at fixed Flutter SHA ${sha}.`);
    if (!run) {
      missingSince ??= at;
      if (at - missingSince >= 90 * 1000) throw new Error(`Missing required ${workflow} run for fixed Flutter SHA ${sha} after scheduling grace period.`);
    } else {
      missingSince = undefined;
    }
    const status = run?.status ?? "awaiting scheduling";
    if (status !== lastStatus) {
      onWait({ workflow, sha, status });
      lastStatus = status;
    }
    await sleep(Math.min(30 * 1000, until - at));
  }
}

function digest(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function stagePackage(input, output, platform, manifest) {
  if (!PLATFORMS.includes(platform)) throw new Error("Unsupported Flutter release platform.");
  const extension = platform.startsWith("android") ? ".apk" : platform.startsWith("linux") ? ".tar.gz" : ".zip";
  if (!input.endsWith(extension) || !fs.statSync(input).isFile()) throw new Error("Unexpected package format.");
  fs.mkdirSync(output, { recursive: true });
  const name = `Flutter-${productName(manifest)}-${manifest.version}-${platform}${extension}`;
  const destination = path.join(output, name);
  fs.copyFileSync(input, destination);
  fs.writeFileSync(path.join(output, `${name}.json`), `${JSON.stringify({
    schema_version: 1, product_name: productName(manifest), repository: manifest.repository, release_tag: manifest.release_tag,
    version: manifest.version, build_number: manifest.build_number,
    flutter_sha: manifest.flutter_sha, platform, file: name, sha256: digest(destination),
    ...(platform.startsWith("android") ? { android_version_code: androidVersionCode(manifest.build_number, platform) } : {}),
  }, null, 2)}\n`);
  return destination;
}

function verifyPackages(directory, manifest, android) {
  const files = fs.readdirSync(directory);
  const packages = [];
  const platforms = new Set();
  for (const file of files.filter((name) => name.endsWith(".json"))) {
    const info = JSON.parse(fs.readFileSync(path.join(directory, file), "utf8"));
    if (productName(info) !== productName(manifest) || info.schema_version !== 1 || info.repository !== manifest.repository || info.release_tag !== manifest.release_tag || info.version !== manifest.version || info.build_number !== manifest.build_number || info.flutter_sha !== manifest.flutter_sha || !PLATFORMS.includes(info.platform) || platforms.has(info.platform)) throw new Error("Package provenance does not match pinned release source.");
    const extension = info.platform.startsWith("android") ? ".apk" : info.platform.startsWith("linux") ? ".tar.gz" : ".zip";
    const expected = `Flutter-${productName(manifest)}-${manifest.version}-${info.platform}${extension}`;
    if (info.file !== expected || file !== `${expected}.json` || digest(path.join(directory, expected)) !== info.sha256) throw new Error("Package name or checksum does not match provenance.");
    if (info.platform.startsWith("android") && info.android_version_code !== undefined && info.android_version_code !== androidVersionCode(manifest.build_number, info.platform)) throw new Error("APK version code does not match the update contract.");
    platforms.add(info.platform);
    packages.push(expected, file);
  }
  const required = android ? PLATFORMS : PLATFORMS.slice(0, 3);
  if (required.some((platform) => !platforms.has(platform)) || platforms.size !== required.length || files.length !== packages.length) throw new Error("The complete expected Flutter platform set is required before publishing.");
  return packages;
}

module.exports = { MANIFEST, REQUIRED_WORKFLOWS, releaseVersion, androidVersionCode, verifyAndroidPackage, sourceSha, validateManifest, approvedRun, stagePackage, verifyPackages, waitForWorkflow };

if (require.main === module) {
  const [command, manifestFile, target, value, input] = process.argv.slice(2);
  try {
    const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
    validateManifest(manifest, process.env.GITHUB_REPOSITORY, manifest.release_tag);
    if (command === "stage") stagePackage(input, target, value, manifest);
    else if (command === "verify") verifyPackages(target, manifest, value === "true");
    else if (command === "verify-apk") verifyAndroidPackage(fs.readFileSync(value, "utf8"), target, manifest);
    else throw new Error("Use flutter-release.cjs stage|verify|verify-apk.");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
