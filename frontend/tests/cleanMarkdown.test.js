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

test("strips markdown table separators and neatly formats rows in default list mode", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "| 序号 | 名称 | 状态 |\n|:---|:---:|---:|\n| 1 | 产生式 | 正常 |\n| 2 | 文法 | 结束 |";
  const output = cleanMarkdown(input);
  assert.equal(output, "1. 序号: 1 (名称: 产生式; 状态: 正常)\n2. 序号: 2 (名称: 文法; 状态: 结束)");
});

test("formats table in aligned mode", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "| 序号 | 名称 | 状态 |\n|:---|:---:|---:|\n| 1 | 产生式 | 正常 |\n| 2 | 文法 | 结束 |";
  const output = cleanMarkdown(input, { tableMode: "aligned" });
  assert.ok(output.includes("序号"));
  assert.ok(output.includes("产生式"));
  assert.ok(!output.includes("|"));
});

test("formats table in raw_pipe mode", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "| 序号 | 名称 | 状态 |\n|:---|:---:|---:|\n| 1 | 产生式 | 正常 |\n| 2 | 文法 | 结束 |";
  const output = cleanMarkdown(input, { tableMode: "raw_pipe" });
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

test("handles asterisk lists and preserves arithmetic multiplication without stripping", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "* 步骤一: 计算 3 * 4 * 5 = 60\n* 步骤二: **重要提示** *注意斜体* 乘法 a * b";
  const output = cleanMarkdown(input);
  assert.equal(
    output,
    "- 步骤一: 计算 3 * 4 * 5 = 60\n- 步骤二: 重要提示 注意斜体 乘法 a * b"
  );
});

test("handles discrete math markdown content with tables, lists, and formulas cleanly", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = [
    "# 离散数学：真值表与命题演算",
    "> 结论：该公式为可满足式。",
    "* 变元定义：$p, q, r$",
    "* 乘法与集合：A * B 与 2 * 3",
    "",
    "| p | q | p -> q |",
    "|---|---|---|",
    "| 0 | 0 | 1 |",
    "| 0 | 1 | 1 |"
  ].join("\n");
  const output = cleanMarkdown(input, { tableMode: "aligned" });
  assert.ok(output.includes("离散数学：真值表与命题演算"));
  assert.ok(output.includes("结论：该公式为可满足式。"));
  assert.ok(!output.includes("> 结论"));
  assert.ok(output.includes("- 变元定义：$p, q, r$"));
  assert.ok(output.includes("A * B 与 2 * 3"));
  assert.ok(!output.includes("#"));
  assert.ok(!output.includes("|"));
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
