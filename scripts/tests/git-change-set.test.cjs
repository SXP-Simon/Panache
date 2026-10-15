"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const { FLAGS } = require("../change-impact.cjs");
const { diff, staged, ciChanges, pushChanges, dirtyPaths } = require("../git-change-set.cjs");
const { readPlan } = require("../plan-checks.cjs");
const ZERO = "0".repeat(40);
const UNKNOWN = "f".repeat(40);
const planner = path.resolve(__dirname, "../plan-checks.cjs");

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "handwrite-impact-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  function git(...args) {
    const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, `${args.join(" ")}\n${result.stderr}`);
    return result.stdout.trim();
  }
  git("init", "--initial-branch=main");
  git("config", "user.name", "Impact fixture");
  git("config", "user.email", "impact@example.invalid");
  git("config", "commit.gpgsign", "false");
  git("config", "core.autocrlf", "false");
  fs.mkdirSync(path.join(directory, "empty-hooks"));
  git("config", "core.hooksPath", path.join(directory, "empty-hooks"));
  function write(file, content = "fixture\n") {
    const target = path.join(directory, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content);
  }
  function commit(message = "fixture commit") {
    git("commit", "--allow-empty", "-m", message);
    return git("rev-parse", "HEAD");
  }
  function index(file, text = "indexed fixture\n") {
    const result = spawnSync("git", ["hash-object", "-w", "--stdin"], { cwd: directory, encoding: "utf8", input: text });
    assert.equal(result.status, 0, result.stderr);
    git("update-index", "--add", "--cacheinfo", "100644", result.stdout.trim(), file);
  }
  return { directory, git, write, commit, index };
}

test("Git NUL 输出保留中文和空格文件名，重命名同时覆盖旧新路径", (t) => {
  const { directory, git, commit, index } = fixture(t);
  const removed = "backend/中文 旧文件.py";
  const renamed = "frontend/src/旧 组件.tsx";
  index(removed);
  index(renamed);
  const base = commit();
  git("update-index", "--force-remove", "--", removed, renamed);
  // Git for Windows rejects names forbidden by NTFS even for index-only entries.
  const added = ["frontend/src/新 组件.tsx", ...(process.platform === "win32" ? [] :
    ['docs/引号"文件.md', "docs/换行\n文件.md", "docs/制表\t文件.md", "frontend/src/back\\slash.tsx"])];
  for (const file of added) index(file);
  const target = commit();
  assert.deepEqual(diff(base, target, directory).sort(), [removed, renamed, ...added].sort());
  assert.deepEqual(readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: base, HEAD_SHA: target }, directory).paths,
    [removed, renamed, ...added].sort());
});

test("首次提交暂存范围不依赖 HEAD，dirtyPaths 区分暂存、未暂存和未跟踪", (t) => {
  const { directory, git, write, commit } = fixture(t);
  write("frontend/src/App.tsx");
  git("add", "frontend/src/App.tsx");
  const initial = staged(directory);
  assert.deepEqual(initial.paths, ["frontend/src/App.tsx"]);
  assert.equal(initial.head_sha, "");
  assert.equal(initial.full, false);
  commit();
  write("frontend/src/App.tsx", "staged\n");
  git("add", "frontend/src/App.tsx");
  write("backend/new.py");
  assert.deepEqual(dirtyPaths(directory).sort(), ["backend/new.py"]);
  assert.deepEqual(dirtyPaths(directory, { includeStaged: true }).sort(), ["backend/new.py", "frontend/src/App.tsx"]);
  write("frontend/src/App.tsx", "unstaged\n");
  assert.deepEqual(dirtyPaths(directory).sort(), ["backend/new.py", "frontend/src/App.tsx"]);
});

test("PR 使用共同祖先比较，基础分支的新文件不进入 PR 影响范围", (t) => {
  const { directory, git, index, commit } = fixture(t);
  index("README.md");
  const base = commit();
  git("checkout", "-b", "feature");
  index("frontend/src/App.tsx");
  const feature = commit();
  git("checkout", "main");
  index("backend/main-only.py");
  const main = commit();
  git("checkout", "feature");
  const result = ciChanges({ EVENT_NAME: "pull_request", PR_BASE: main, PR_HEAD: feature }, directory);
  assert.deepEqual(result.paths, ["frontend/src/App.tsx"]);
  assert.equal(result.full, false);
  assert.equal(result.head_sha, feature);
  assert.notEqual(main, base);
});

test("文档推送继续验证并发布被前次 CI 取消的未发布应用变更", (t) => {
  const { directory, git, index, commit } = fixture(t);
  index("frontend/src/App.tsx", "released UI\n");
  commit();
  git("tag", "v1.9.0");
  index("frontend/src/App.tsx", "unreleased UI\n");
  const application = commit();
  index("docs/development.md");
  const documentation = commit();
  const plan = readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: application, HEAD_SHA: documentation }, directory);
  assert.deepEqual(plan.paths, ["docs/development.md", "frontend/src/App.tsx"]);
  assert.equal(plan.full, false);
  for (const flag of ["docs", "frontend", "unit_frontend", "e2e", "docker", "release"]) {
    assert.equal(plan[flag], true, flag);
  }
  assert.match(plan.reason, /unpublished application paths since v1\.9\.0/);

  // The nearest reachable stable release, rather than a prerelease, is the baseline.
  git("tag", "v1.10.0");
  index("frontend/src/App.tsx", "next unreleased UI\n");
  const nextApplication = commit();
  git("tag", "v2.0.0-beta.1");
  index("docs/development.md", "next docs\n");
  const nextDocs = commit();
  const next = readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: nextApplication, HEAD_SHA: nextDocs }, directory);
  assert.equal(next.release, true);
  assert.match(next.reason, /since v1\.10\.0$/);
});

test("fork 重启版本编号时使用最近发布 tag，不回到更高版本的上游祖先", (t) => {
  const { directory, git, index, commit } = fixture(t);
  index("frontend/src/App.tsx", "upstream UI\n");
  commit();
  git("tag", "v1.34.0");
  index("frontend/src/App.tsx", "fork UI\n");
  const forkRelease = commit();
  git("tag", "v1.2.0");
  index("docs/development.md");
  const documentation = commit();
  const plan = readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: forkRelease, HEAD_SHA: documentation }, directory);
  assert.deepEqual(plan.paths, ["docs/development.md"]);
  assert.deepEqual(FLAGS.filter((flag) => plan[flag]), ["docs"]);
  assert.equal(plan.full, false);
  assert.match(plan.reason, /release baseline v1\.2\.0$/);
});

test("新版本 tag 清除累计应用范围，未发布测试和工作流不反复触发重型检查", (t) => {
  const { directory, git, index, commit } = fixture(t);
  index("backend/app.py");
  commit();
  git("tag", "v1.0.0");
  index("backend/app.py", "new application\n");
  commit();
  git("tag", "v1.1.0");
  index("backend/tests/test_app.py");
  index(".github/workflows/engineering-quality.yml");
  const maintenance = commit();
  index("docs/development.md");
  const documentation = commit();
  const plan = readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: maintenance, HEAD_SHA: documentation }, directory);
  assert.deepEqual(plan.paths, ["docs/development.md"]);
  assert.deepEqual(FLAGS.filter((flag) => plan[flag]), ["docs"]);
  assert.equal(plan.full, false);
  assert.match(plan.reason, /release baseline v1\.1\.0$/);
});

test("缺少可达稳定发布 tag 时保守完整验证，旁支及预发布 tag 不充当基线", (t) => {
  const { directory, git, index, commit } = fixture(t);
  const base = commit();
  git("checkout", "-b", "unrelated-release");
  index("backend/app.py");
  commit();
  git("tag", "v99.0.0");
  git("checkout", "main");
  git("tag", "v1.0.0-beta.1");
  index("docs/development.md");
  const documentation = commit();
  const plan = readPlan(["--ci"], { EVENT_NAME: "push", PUSH_BASE: base, HEAD_SHA: documentation }, directory);
  assert.deepEqual(plan.paths, ["docs/development.md"]);
  assert.equal(plan.full, true);
  assert.ok(FLAGS.every((flag) => plan[flag]));
  assert.match(plan.reason, /stable release baseline unavailable/);
});

test("pre-push 合并全部引用更新，删除引用不覆盖其他更新", (t) => {
  const { directory, index, commit } = fixture(t);
  index("README.md");
  const first = commit();
  index("frontend/src/App.tsx");
  const second = commit();
  index("backend/app.py");
  const current = commit();
  const input = [
    `refs/heads/custom-base ${current} refs/heads/custom-base ${second}`,
    `refs/heads/alias ${current} refs/heads/alias ${first}`,
    `(delete) ${ZERO} refs/heads/obsolete ${first}`,
  ].join("\n") + "\n";
  const result = pushChanges(input, directory);
  assert.deepEqual(result.paths.sort(), ["backend/app.py", "frontend/src/App.tsx"]);
  assert.equal(result.full, false);
  assert.equal(result.head_sha, current);
});

test("新分支与缺失远端历史执行完整验证，纯删除引用不执行应用检查", (t) => {
  const { directory, index, commit } = fixture(t);
  index("README.md");
  const current = commit();
  for (const remote of [ZERO, UNKNOWN]) {
    const plan = readPlan(["--push"], {}, directory, `refs/heads/custom-base ${current} refs/heads/custom-base ${remote}\n`);
    assert.equal(plan.full, true);
    assert.ok(FLAGS.every((flag) => plan[flag]));
  }
  const deleted = readPlan(["--push"], {}, directory, `(delete) ${ZERO} refs/heads/obsolete ${current}\n`);
  assert.deepEqual(deleted.paths, []);
  assert.equal(deleted.full, false);
  assert.ok(FLAGS.every((flag) => !deleted[flag]));
  assert.equal(pushChanges("", directory).full, true);
});

test("不允许用当前工作区验证其他提交或畸形推送参数", (t) => {
  const { directory, commit } = fixture(t);
  const previous = commit();
  const current = commit();
  assert.throws(() => pushChanges(`refs/heads/old ${previous} refs/heads/old ${current}`, directory), /不是当前 HEAD/u);
  for (const input of ["invalid", `refs/heads/x invalid refs/heads/x ${ZERO}`, `refs/heads/x ${current} refs/heads/x invalid`]) {
    assert.throws(() => pushChanges(input, directory), /Invalid Git pre-push/);
  }
});

test("CI 没有比较基线、历史被裁剪或未知事件都回退完整验证", (t) => {
  const { directory, commit } = fixture(t);
  const current = commit();
  for (const env of [
    { EVENT_NAME: "push", HEAD_SHA: current },
    { EVENT_NAME: "push", HEAD_SHA: current, PUSH_BASE: ZERO },
    { EVENT_NAME: "push", HEAD_SHA: current, PUSH_BASE: UNKNOWN },
    { EVENT_NAME: "pull_request", PR_HEAD: current, PR_BASE: UNKNOWN },
    { EVENT_NAME: "workflow_dispatch", HEAD_SHA: current },
    { EVENT_NAME: "schedule", HEAD_SHA: current },
  ]) {
    const result = ciChanges(env, directory);
    assert.equal(result.full, true, JSON.stringify(env));
    assert.equal(result.head_sha, current);
    assert.deepEqual(result.paths, []);
  }
  const injected = ciChanges({ EVENT_NAME: "push", HEAD_SHA: `${current}\nrelease=true` }, directory);
  assert.equal(injected.head_sha, current);
});

test("CLI JSON、计划文件和 GitHub outputs 表示相同的实际 Git 变更", (t) => {
  const { directory, git, write, commit } = fixture(t);
  commit();
  write("docs/development.md");
  git("add", "docs/development.md");
  const output = path.join(directory, "output", "plan.json");
  const githubOutput = path.join(directory, "outputs.txt");
  const result = spawnSync(process.execPath, [planner, "--staged", "--output", output], {
    cwd: directory, encoding: "utf8", env: { ...process.env, GITHUB_OUTPUT: githubOutput },
  });
  assert.equal(result.status, 0, result.stderr);
  const plan = JSON.parse(result.stdout);
  assert.deepEqual(JSON.parse(fs.readFileSync(output, "utf8")), plan);
  assert.deepEqual(plan.paths, ["docs/development.md"]);
  const flags = Object.fromEntries(fs.readFileSync(githubOutput, "utf8").trim().split("\n").map((line) => line.split("=")));
  for (const flag of FLAGS) assert.equal(flags[flag], String(plan[flag]), flag);
  assert.equal(flags.head_sha, plan.head_sha);
  assert.equal(flags.docs, "true");
  assert.equal(flags.python, "false");
});

test("CLI 消费原始 pre-push stdin，拒绝冲突模式和未知选项", (t) => {
  const { directory, index, commit } = fixture(t);
  const base = commit();
  index("backend/app.py");
  const current = commit();
  const result = spawnSync(process.execPath, [planner, "--push"], {
    cwd: directory, encoding: "utf8", input: `refs/heads/custom-base ${current} refs/heads/custom-base ${base}\n`,
    env: { ...process.env, GITHUB_OUTPUT: "" },
  });
  assert.equal(result.status, 0, result.stderr);
  const plan = JSON.parse(result.stdout);
  assert.deepEqual(plan.paths, ["backend/app.py"]);
  assert.equal(plan.unit_python, true);
  for (const args of [[], ["--all", "--all"], ["--all", "--staged"], ["--staged", "--skip"], ["--staged", "--output"]]) {
    const invalid = spawnSync(process.execPath, [planner, ...args], { cwd: directory, encoding: "utf8" });
    assert.equal(invalid.status, 1, args.join(" "));
    assert.match(invalid.stderr, /规划失败/u);
  }
  assert.throws(() => readPlan(["--staged", "--skip"], {}, directory), /exactly one/);
});
