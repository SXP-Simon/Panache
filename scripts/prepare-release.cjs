"use strict";

const fs = require("node:fs");
const { execFileSync } = require("node:child_process");
const { releaseVersion } = require("./flutter-release.cjs");

function releaseNotes(changelog, tag) {
  const lines = changelog.split(/\r?\n/u);
  const index = lines.findIndex((line) => /^## (v[\d.]+) \(\d{4}-\d{2}-\d{2}\)$/u.exec(line)?.[1] === tag);
  if (index < 0) throw new Error("Missing CHANGELOG.md section for " + tag);
  const end = lines.findIndex((line, i) => i > index && /^#{1,2} /u.test(line));
  const notes = lines.slice(index + 1, end < 0 ? undefined : end).join("\n").trim();
  if (!notes) throw new Error("Empty release notes for " + tag);
  return notes;
}

function prepareRelease(tag) {
  const version = releaseVersion(tag);
  const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trimEnd();
  if (git("branch", "--show-current") !== "main") throw new Error("Prepare the release on main.");
  const originalVersion = fs.readFileSync("VERSION", "utf8");
  const previous = originalVersion.trim();
  if (previous !== git("show", "HEAD:VERSION") || version.build_number <= releaseVersion("v" + previous).build_number) {
    throw new Error("Start from the committed VERSION and select a higher version.");
  }
  const changelog = fs.readFileSync("CHANGELOG.md", "utf8");
  const heading = /^## 未发布\r?$/mu;
  if (!heading.test(changelog)) throw new Error("Missing 未发布 section in CHANGELOG.md");
  if (changelog.includes("\n## " + tag + " (")) throw new Error("Version already in CHANGELOG.md");
  const date = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Shanghai" }).format(new Date());
  const next = changelog.replace(heading, "## 未发布\n\n## " + tag + " (" + date + ")");
  releaseNotes(next, tag);
  try {
    fs.writeFileSync("CHANGELOG.md", next);
    fs.writeFileSync("VERSION", version.version + "\n");
    git("commit", "--only", "-m", "chore(release): " + tag,
      "-m", "背景：准备发布 Panache " + tag + "。",
      "-m", "解决手段：同步产品版本并归档本版更新说明。",
      "-m", "收益：安装包、源码和发布记录可按同一版本追溯。",
      "--", "VERSION", "CHANGELOG.md");
  } catch (error) {
    fs.writeFileSync("CHANGELOG.md", changelog);
    fs.writeFileSync("VERSION", originalVersion);
    throw error;
  }
}

module.exports = { releaseNotes };
if (require.main === module) {
  try {
    prepareRelease(process.argv[2]);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
