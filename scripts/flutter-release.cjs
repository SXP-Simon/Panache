"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { execFileSync } = require("node:child_process");

const MANIFEST = "Flutter-source.json";
const REQUIRED_WORKFLOWS = ["flutter.yml", "rust.yml", "flutter_mobile.yml"];
const PLATFORMS = ["windows-x64", "linux-x64", "macos-arm64", "android-arm64-x64"];

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

function sourceSha(value) {
  if (!/^[a-f0-9]{40}$/u.test(value ?? "")) throw new Error("Flutter source must be a full lowercase 40-character commit SHA.");
  return value;
}

function targetTag({ event, manualTag, result, sourceRunId }) {
  if (event === "workflow_dispatch") return manualTag;
  if (event !== "workflow_run" || result?.version !== 1 || result.run_id !== sourceRunId || !(result.tag === null || typeof result.tag === "string")) {
    throw new Error("Release result does not match the exact Semantic Release source run.");
  }
  return result.tag;
}

function validateManifest(manifest, repository, tag) {
  const version = releaseVersion(tag);
  if (manifest?.schema_version !== 1 || manifest.repository !== repository || manifest.release_tag !== tag || manifest.version !== version.version || manifest.build_number !== version.build_number) {
    throw new Error("The immutable Flutter source manifest does not match this release.");
  }
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
  const matching = runs.filter((run) => run.head_sha === sha && run.head_branch === "flutter" && ["push", "workflow_dispatch"].includes(run.event) && run.head_repository?.full_name === repository);
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

function sourceContract(desktopScript, coreSource, androidScript, bridgeSource, serverSource, macScript) {
  for (const token of ["--version", "--build-number", "HANDWRITING_BUILD_VERSION"]) {
    if (!desktopScript.includes(token)) throw new Error(`Pinned Flutter source lacks release build support: ${token}`);
  }
  if (!coreSource.includes("app_version") || !coreSource.includes("HANDWRITING_BUILD_VERSION")) throw new Error("Pinned Flutter source lacks the shared runtime release version API.");
  if (!bridgeSource.includes("handwriting_core::app_version()") || !serverSource.includes("handwriting_core::app_version()")) throw new Error("Pinned Flutter bridge/server do not consume the shared release version API.");
  if (!macScript.includes("HANDWRITING_BUILD_VERSION")) throw new Error("Pinned macOS embed script cannot preserve the release version.");
  for (const variable of ["HANDWRITING_ANDROID_KEYSTORE_PATH", "HANDWRITING_ANDROID_STORE_PASSWORD", "HANDWRITING_ANDROID_KEY_ALIAS", "HANDWRITING_ANDROID_KEY_PASSWORD"]) {
    if (!androidScript.includes(variable)) throw new Error(`Pinned Flutter source lacks formal signing support: ${variable}`);
  }
}

async function resolveRelease(input, io) {
  const tag = targetTag(input);
  if (tag === null) return null;
  const version = releaseVersion(tag);
  const release = await io.release(tag);
  if (release.tag_name !== tag || release.draft) throw new Error("Target must be an existing published release with the exact tag.");
  if ((await io.file("backend/VERSION", tag)).trim() !== version.version) throw new Error("Target tag and custom-base release version disagree.");
  const assets = release.assets.filter((asset) => asset.name === MANIFEST);
  if (assets.length > 1) throw new Error("Ambiguous Flutter source manifests on the target release.");
  let manifest = assets.length ? validateManifest(await io.manifest(assets[0].id), input.repository, tag) : null;
  let sha;
  if (manifest) {
    sha = manifest.flutter_sha;
    if (input.manualSha && sourceSha(input.manualSha) !== sha) throw new Error("A release's pinned Flutter SHA cannot be replaced during a retry.");
  } else {
    if (input.event === "workflow_run" && Number(input.runAttempt ?? 1) > 1) throw new Error("Automatic retry has no immutable source manifest. Use workflow_dispatch with the original full Flutter SHA; never resolve a newer branch during retry.");
    if (input.event === "workflow_dispatch" && !input.manualSha) throw new Error("First manual build requires an explicit full Flutter SHA; a historical release cannot use the latest branch implicitly.");
    sha = sourceSha(input.manualSha || await io.branchSha());
  }
  const qualityRuns = {};
  for (const workflow of REQUIRED_WORKFLOWS) {
    try {
      qualityRuns[workflow] = approvedRun(await io.runs(workflow, sha), sha, input.repository);
    } catch (error) {
      throw new Error(`Required ${workflow}: ${error.message}`, { cause: error });
    }
  }
  sourceContract(
    await io.file("scripts/build-flutter-desktop.py", sha),
    await io.file("crates/handwriting-core/src/lib.rs", sha),
    await io.file("app/android/app/build.gradle.kts", sha),
    await io.file("crates/handwriting-bridge/src/api.rs", sha),
    await io.file("crates/handwriting-server/src/lib.rs", sha),
    await io.file("scripts/embed-macos-backend.sh", sha),
  );
  if (!manifest) {
    manifest = {
      schema_version: 1,
      repository: input.repository,
      release_tag: tag,
      ...version,
      flutter_sha: sha,
      quality_runs: qualityRuns,
      android_initial_status: input.androidSigningReady ? "release-signing-configured" : "skipped-missing-release-signing-secrets",
      android_policy: "Only externally supplied release signing keys; omit APK when all signing secrets are unavailable.",
      ios_policy: "No IPA without distribution signing and provisioning.",
    };
    await io.publishManifest(tag, manifest); // Never overwrite this source-of-truth asset.
  }
  return manifest;
}

function digest(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function stagePackage(input, output, platform, manifest) {
  if (!PLATFORMS.includes(platform)) throw new Error("Unsupported Flutter release platform.");
  const extension = platform.startsWith("android") ? ".apk" : platform.startsWith("linux") ? ".tar.gz" : ".zip";
  if (!input.endsWith(extension) || !fs.statSync(input).isFile()) throw new Error("Unexpected package format.");
  fs.mkdirSync(output, { recursive: true });
  const name = `Flutter-HandwritingWeb-${manifest.version}-${platform}${extension}`;
  const destination = path.join(output, name);
  fs.copyFileSync(input, destination);
  fs.writeFileSync(path.join(output, `${name}.json`), `${JSON.stringify({
    schema_version: 1, repository: manifest.repository, release_tag: manifest.release_tag,
    version: manifest.version, build_number: manifest.build_number,
    flutter_sha: manifest.flutter_sha, platform, file: name, sha256: digest(destination),
  }, null, 2)}\n`);
  return destination;
}

function verifyPackages(directory, manifest, android) {
  const files = fs.readdirSync(directory);
  const packages = [];
  const platforms = new Set();
  for (const file of files.filter((name) => name.endsWith(".json"))) {
    const info = JSON.parse(fs.readFileSync(path.join(directory, file), "utf8"));
    if (info.schema_version !== 1 || info.repository !== manifest.repository || info.release_tag !== manifest.release_tag || info.version !== manifest.version || info.build_number !== manifest.build_number || info.flutter_sha !== manifest.flutter_sha || !PLATFORMS.includes(info.platform) || platforms.has(info.platform)) throw new Error("Package provenance does not match pinned release source.");
    const extension = info.platform.startsWith("android") ? ".apk" : info.platform.startsWith("linux") ? ".tar.gz" : ".zip";
    const expected = `Flutter-HandwritingWeb-${manifest.version}-${info.platform}${extension}`;
    if (info.file !== expected || file !== `${expected}.json` || digest(path.join(directory, expected)) !== info.sha256) throw new Error("Package name or checksum does not match provenance.");
    platforms.add(info.platform);
    packages.push(expected, file);
  }
  const required = android ? PLATFORMS : PLATFORMS.slice(0, 3);
  if (required.some((platform) => !platforms.has(platform)) || platforms.size !== required.length || files.length !== packages.length) throw new Error("The complete expected Flutter platform set is required before publishing.");
  return packages;
}

function github(repository) {
  if (!/^[\w.-]+\/[\w.-]+$/u.test(repository ?? "")) throw new Error("Explicit GitHub repository is required.");
  const gh = (...args) => execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const api = (route) => JSON.parse(gh("api", `repos/${repository}/${route}`));
  let deadline;
  return {
    release: (tag) => api(`releases/tags/${encodeURIComponent(tag)}`),
    file: (file, ref) => Buffer.from(api(`contents/${file}?ref=${encodeURIComponent(ref)}`).content, "base64").toString("utf8"),
    branchSha: () => api("git/ref/heads/flutter").object.sha,
    manifest: (id) => JSON.parse(gh("api", `repos/${repository}/releases/assets/${id}`, "-H", "Accept: application/octet-stream")),
    runs: (workflow, sha) => {
      deadline ??= Date.now() + 30 * 60 * 1000;
      return waitForWorkflow({
        workflow, sha, repository, deadline,
        fetchRuns: () => api(`actions/workflows/${workflow}/runs?head_sha=${sha}&per_page=100`).workflow_runs,
        onWait({ status }) {
          const message = `Waiting for ${workflow} at fixed Flutter SHA ${sha}: ${status}`;
          console.log(message);
          if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${message}\n`);
        },
      });
    },
    publishManifest(tag, manifest) {
      const directory = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP || require("node:os").tmpdir(), "flutter-release-"));
      const file = path.join(directory, MANIFEST);
      fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
      gh("release", "upload", tag, file, "--repo", repository); // No --clobber for the pin.
    },
  };
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === "resolve") {
    const resultFile = process.env.RELEASE_RESULT_FILE;
    const manifest = await resolveRelease({
      event: process.env.EVENT_NAME, manualTag: process.env.MANUAL_TAG,
      manualSha: process.env.MANUAL_FLUTTER_SHA, sourceRunId: process.env.SOURCE_RUN_ID,
      repository: process.env.GITHUB_REPOSITORY,
      androidSigningReady: process.env.ANDROID_SIGNING_READY === "true",
      runAttempt: process.env.GITHUB_RUN_ATTEMPT,
      result: resultFile ? JSON.parse(fs.readFileSync(resultFile, "utf8")) : undefined,
    }, github(process.env.GITHUB_REPOSITORY));
    if (!manifest) return;
    fs.mkdirSync("release-plan", { recursive: true });
    fs.writeFileSync(`release-plan/${MANIFEST}`, `${JSON.stringify(manifest, null, 2)}\n`);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `tag=${manifest.release_tag}\nversion=${manifest.version}\nbuild_number=${manifest.build_number}\nflutter_sha=${manifest.flutter_sha}\nandroid=${process.env.ANDROID_SIGNING_READY === "true"}\n`);
    if (process.env.ANDROID_SIGNING_READY !== "true" && process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, "\nAndroid APK omitted: all four formal release signing secrets are required. No debug-signed APK or unsigned iOS IPA is distributed.\n");
  } else if (command === "stage" || command === "verify") {
    const [manifestFile, directory, platform, input] = args;
    const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
    validateManifest(manifest, process.env.GITHUB_REPOSITORY, manifest.release_tag);
    if (command === "stage") stagePackage(input, directory, platform, manifest);
    else verifyPackages(directory, manifest, platform === "true");
  } else throw new Error("Use flutter-release.cjs resolve|stage|verify.");
}

module.exports = { MANIFEST, REQUIRED_WORKFLOWS, releaseVersion, sourceSha, targetTag, validateManifest, approvedRun, sourceContract, resolveRelease, stagePackage, verifyPackages, waitForWorkflow };
if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
