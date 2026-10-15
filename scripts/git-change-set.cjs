"use strict";

const { spawnSync } = require("node:child_process");
const { planChanges } = require("./change-impact.cjs");
const ZERO = /^0+$/;
const OID = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/i;

function git(args, cwd = process.cwd()) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || `git ${args[0]} failed`);
  return result.stdout;
}
const paths = (output) => output.split("\0").filter(Boolean);
function head(cwd) { return git(["rev-parse", "--verify", "HEAD"], cwd).trim(); }
function commit(oid, cwd) {
  if (!OID.test(oid) || ZERO.test(oid)) throw new Error("Missing comparison commit");
  return git(["rev-parse", "--verify", `${oid}^{commit}`], cwd).trim();
}
function diff(base, target, cwd) {
  return paths(git(["diff", "--name-only", "-z", "--no-renames", base, target, "--"], cwd));
}
function staged(cwd) {
  let current = "";
  try { current = head(cwd); } catch { /* An initial commit has no HEAD yet. */ }
  return { paths: paths(git(["diff", "--cached", "--name-only", "-z", "--no-renames", "--"], cwd)),
    full: false, reason: "staged paths", head_sha: current };
}
function ciChanges(environment = process.env, cwd) {
  const target = environment.PR_HEAD || environment.HEAD_SHA || head(cwd);
  const fallback = (reason) => ({ paths: [], full: true, reason, head_sha: OID.test(target) ? target : head(cwd) });
  if (environment.EVENT_NAME === "workflow_dispatch") return fallback("manual full validation");
  try {
    const targetCommit = commit(target, cwd);
    let base;
    if (environment.EVENT_NAME === "pull_request") {
      base = git(["merge-base", commit(environment.PR_BASE || "", cwd), targetCommit], cwd).trim();
    } else if (environment.EVENT_NAME === "push") {
      base = commit(environment.PUSH_BASE || "", cwd);
    } else return fallback("unknown CI event; full validation");
    const changed = diff(base, targetCommit, cwd);
    if (environment.EVENT_NAME === "pull_request") {
      return { paths: changed, full: false, reason: "PR merge-base to head", head_sha: targetCommit };
    }
    // A later documentation push can cancel an application's checks before it is released.
    // Carry those application inputs forward, but do not perpetually repeat unrelated test/CI changes.
    const releaseTag = git(["tag", "--merged", targetCommit, "--sort=-version:refname"], cwd)
      .split(/\r?\n/).find((tag) => /^v\d+\.\d+\.\d+$/.test(tag));
    if (!releaseTag) {
      return { paths: changed, full: true, reason: "stable release baseline unavailable; full validation", head_sha: targetCommit };
    }
    const pending = diff(releaseTag, targetCommit, cwd).filter((file) => planChanges([file]).release);
    return { paths: [...new Set([...changed, ...pending])], full: false,
      reason: pending.length ? `push before to head plus unpublished application paths since ${releaseTag}`
        : `push before to head; release baseline ${releaseTag}`, head_sha: targetCommit };
  } catch {
    return fallback("comparison history unavailable; full validation");
  }
}
function pushChanges(input, cwd) {
  const current = head(cwd);
  const lines = input.trim().split(/\r?\n/).filter(Boolean);
  if (!lines.length) return { paths: [], full: true, reason: "missing push ref input; full validation", head_sha: current };
  const changed = new Set();
  let full = false;
  let updates = 0;
  for (const line of lines) {
    const fields = line.trim().split(/\s+/);
    if (fields.length !== 4 || !OID.test(fields[1]) || !OID.test(fields[3]))
      throw new Error("Invalid Git pre-push ref input; refusing an unverified push");
    const [, local, , remote] = fields;
    if (ZERO.test(local)) continue;
    updates += 1;
    const target = commit(local, cwd);
    if (target !== current) throw new Error("推送目标不是当前 HEAD，无法用当前工作区验证；请先切换到对应提交再推送。");
    try {
      for (const file of diff(commit(remote, cwd), target, cwd)) changed.add(file);
    } catch { full = true; }
  }
  return { paths: [...changed], full, reason: !updates ? "ref deletions only" : full ? "new branch or missing remote history; full validation" : "all pushed ref updates",
    head_sha: current };
}
function dirtyPaths(cwd, { includeStaged = false } = {}) {
  return [...new Set([...paths(git(["diff", "--name-only", "-z", "--no-renames", "--"], cwd)),
    ...(includeStaged ? paths(git(["diff", "--cached", "--name-only", "-z", "--no-renames", "--"], cwd)) : []),
    ...paths(git(["ls-files", "--others", "--exclude-standard", "-z"], cwd))])];
}

module.exports = { git, head, diff, staged, ciChanges, pushChanges, dirtyPaths };
