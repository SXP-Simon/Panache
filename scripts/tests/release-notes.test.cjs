"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { flutterSection, replaceSection } = require("../append-release-notes.js");

test("previous Flutter source can be selected before the new release appears in the cached list", () => {
  const { previousFlutterRelease } = require("../append-release-notes.js");
  const older = { tag_name: "v1.9.0", published_at: "2026-10-24T00:00:00Z", assets: [{ name: "Flutter-source.json" }] };
  const previous = { ...older, tag_name: "v1.10.0", published_at: "2026-11-01T00:00:00Z" };
  const later = { ...previous, tag_name: "v1.11.0", published_at: "2026-11-04T00:00:00Z" };
  assert.equal(previousFlutterRelease([older, later, { ...previous, draft: true }, previous], "2026-11-03T00:00:00Z"), previous);
  assert.equal(previousFlutterRelease([], "2026-11-03T00:00:00Z"), undefined);
});

test("Flutter notes group user-facing changes and link exact commits", () => {
  const base = "a".repeat(40);
  const head = "b".repeat(40);
  const output = flutterSection(base, head, [
    { sha: "c".repeat(40), subject: "feat(app): 图片预览" },
    { sha: "d".repeat(40), subject: "fix(crates/core): 修复排版" },
    { sha: "e".repeat(40), subject: "fix(.github/workflows): 更新运行器" },
    { sha: "f".repeat(40), subject: "test: 验证测试" },
  ], "owner/repo");
  assert.match(output, /### 新功能\n\n- 图片预览/u);
  assert.match(output, /### 修复\n\n- 修复排版/u);
  assert.match(output, /owner\/repo\/compare\/a{40}\.\.\.b{40}/u);
  assert.doesNotMatch(output, /更新运行器|验证测试/u);
  assert.equal(flutterSection(base, base, [], "owner/repo"), "");
});

test("managed notes can be replaced or removed without losing manual text", () => {
  const body = "before\n\n<!-- flutter-changes -->\nold\n<!-- /flutter-changes -->\n\nafter\n";
  assert.equal(replaceSection(body, "<!-- flutter-changes -->", "<!-- /flutter-changes -->", "<!-- flutter-changes -->\nnew\n<!-- /flutter-changes -->"), "before\n\n<!-- flutter-changes -->\nnew\n<!-- /flutter-changes -->\n\nafter\n");
  assert.equal(replaceSection(body, "<!-- flutter-changes -->", "<!-- /flutter-changes -->", ""), "before\n\nafter\n");
  assert.throws(() => replaceSection("before <!-- flutter-changes -->", "<!-- flutter-changes -->", "<!-- /flutter-changes -->", "x"));
});
