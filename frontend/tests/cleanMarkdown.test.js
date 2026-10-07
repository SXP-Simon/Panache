const assert = require("assert").strict;

const tests = [];
function test(name, run) {
  tests.push({ name, run });
}

const cleanModule = import("../src/utils/cleanMarkdown.js");

test("strips markdown headings (#, ##, ###)", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "# 一级标题\n## 二级标题\n### P36 第6题 (对应通话时间 02:04:02 图)\n正文内容";
  const output = cleanMarkdown(input);
  assert.equal(output, "一级标题\n二级标题\nP36 第6题 (对应通话时间 02:04:02 图)\n正文内容");
});

test("strips bold, italic, strikethrough, and inline code", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "这是 **粗体**，这是 *斜体*，这是 ~~删除线~~，这是 `int main()` 代码。";
  const output = cleanMarkdown(input);
  assert.equal(output, "这是 粗体，这是 斜体，这是 删除线，这是 int main() 代码。");
});

test("strips links and images while keeping text/alt", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "查看 [项目地址](https://github.com/14790897/handwriting-web) 或图片 ![图示](https://example.com/pic.png)";
  const output = cleanMarkdown(input);
  assert.equal(output, "查看 项目地址 或图片 图示");
});

test("strips code blocks fences while preserving code text", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "```python\ndef solve():\n    return 42\n```";
  const output = cleanMarkdown(input);
  assert.equal(output, "def solve():\n    return 42");
});

test("strips blockquote markers and preserves text", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "> 第一行引用\n>> 第二行嵌套引用\n正常正文";
  const output = cleanMarkdown(input);
  assert.equal(output, "第一行引用\n第二行嵌套引用\n正常正文");
});

test("strips markdown table separators and neatly formats rows", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "| 序号 | 名称 | 状态 |\n|:---|:---:|---:|\n| 1 | 产生式 | 正常 |\n| 2 | 文法 | 结束 |";
  const output = cleanMarkdown(input);
  assert.equal(output, "序号 | 名称 | 状态\n1 | 产生式 | 正常\n2 | 文法 | 结束");
});

test("preserves manual page break marker (---)", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "第一页内容\n\n---\n\n第二页内容";
  const output = cleanMarkdown(input);
  assert.equal(output, "第一页内容\n\n---\n\n第二页内容");
});

test("detects markdown markup correctly", async () => {
  const { hasMarkdownMarkup } = await cleanModule;
  assert.equal(hasMarkdownMarkup("### 标题"), true);
  assert.equal(hasMarkdownMarkup("纯文本段落没有任何标记"), false);
  assert.equal(hasMarkdownMarkup("这里有 **粗体** 文字"), true);
});

async function runAll() {
  let passed = 0;
  for (const { name, run } of tests) {
    try {
      await run();
      passed++;
      console.log(`✓ ${name}`);
    } catch (e) {
      console.error(`✗ ${name}`);
      console.error(e);
      process.exitCode = 1;
    }
  }
  console.log(`\nPassed ${passed} / ${tests.length} tests.`);
}

runAll();
