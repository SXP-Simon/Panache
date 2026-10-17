const assert = require("assert").strict;

const tests = [];
function test(name, run) {
  tests.push({ name, run });
}

const cleanModule = import("../src/utils/cleanMarkdown.ts");

test("single-character emphasis closes before following paragraphs", async () => {
  const { cleanMarkdown } = await cleanModule;
  for (const marker of ["**", "__", "***", "___", "~~", "=="]) {
    const source = `选择属性 ${marker}A${marker}。\n公式结论\n选择属性 ${marker}B${marker}。`;
    assert.equal(cleanMarkdown(source), "选择属性 A。\n公式结论\n选择属性 B。");
  }
  assert.equal(cleanMarkdown("**单字**。\n**多字内容**。"), "单字。\n多字内容。");
});

test("protects bare sized groups from emphasis in either cleanup order", async () => {
  const { cleanMarkdown } = await cleanModule;
  const { convertLatexToUnicode } = await import('../src/utils/latexToUnicode.ts');
  const inputs = [
    [String.raw`结果：\left[ a_b+c_d \right]，_保留强调内容_。`, '结果：[a_(b)+c_(d)]，保留强调内容。'],
    [String.raw`结果：\left[ {a}_{b}+{c}_{d} \right]，**重要**。`, '结果：[a_(b)+c_(d)]，重要。'],
    [String.raw`结果：\left( \left[ {a}_{b}+{c}_{d} \right]+x^2 \right)，*结论*。`, '结果：([a_(b)+c_(d)]+x²)，结论。'],
  ];
  for (const [source, expected] of inputs) {
    assert.equal(convertLatexToUnicode(cleanMarkdown(source)), expected, source);
    assert.equal(cleanMarkdown(convertLatexToUnicode(source)), expected, source);
  }
  const source = String.raw`\left[ {a}_{b}+{c}_{d} \right]`;
  assert.equal(cleanMarkdown(source), source);
});

test("removes unordered item and continuation indentation without trimming ordinary paragraphs", async () => {
  const { cleanMarkdown } = await cleanModule;
  assert.equal(cleanMarkdown(' * 第一项\n   展开计算\n   再乘系数\n\n    保留普通缩进\n\t- [x] 完成\n\t  下一行\n  + 嵌套项'), '第一项\n展开计算\n再乘系数\n    保留普通缩进\n完成\n下一行\n嵌套项');
  assert.equal(cleanMarkdown('负号\n-0.5\n-x\n  正文'), '负号\n-0.5\n-x\n  正文');
});

test("cleanup then conversion preserves numerical integration expressions", async () => {
  const { cleanMarkdown } = await cleanModule;
  const { convertLatexToUnicode } = await import('../src/utils/latexToUnicode.ts');
  const input = String.raw` * 左边：\int_{-1}^{1} x^2 dx = \left. \frac{1}{3}x^3 \right\vert{}_{-1}^{1}
   展开：2 \times \left( (\frac{1}{2})^3 + \frac{3}{2} \times \frac{1}{12} \right)`;
  const output = convertLatexToUnicode(cleanMarkdown(input));
  assert.equal(output, '左边：∫₋₁¹ x² dx = ⅓x³|₋₁¹\n展开：2 × ((½)³+(3)/(2)×(1)/(12))');
  assert.equal(convertLatexToUnicode(cleanMarkdown(output)), output);
});

test("both cleanup orders preserve mixed numerical integration notes and derivative prose", async () => {
  const { cleanMarkdown } = await cleanModule;
  const { convertLatexToUnicode } = await import('../src/utils/latexToUnicode.ts');
  const input = String.raw`导数 f'(x) = 3x^2，代入 f(x)。
> * 左边：\int_{-1}^{1} x^2 dx = \left. \frac{1}{3}x^3 \right\vert{}_{-1}^{1}
>   结论：左边 \neq 右边。
 * 右边：\frac{1}{2}\left[ (\frac{1}{2}-\frac{1}{2\sqrt{3}})^3 + (\frac{1}{2}+\frac{1}{2\sqrt{3}})^3 \right]
   展开：2 \times \left( (\frac{1}{2})^3 + \frac{3}{2} \times \frac{1}{12} \right)
   再乘以系数 \frac{1}{2}，得到 \frac{1}{4}。`;
  const expected = `导数 f'(x) = 3x²，代入 f(x)。
左边：∫₋₁¹ x² dx = ⅓x³|₋₁¹
结论：左边 ≠ 右边。
右边：½[(½-(1)/(2√(3)))³+(½+(1)/(2√(3)))³]
展开：2 × ((½)³+(3)/(2)×(1)/(12))
再乘以系数 ½，得到 ¼。`;
  assert.equal(convertLatexToUnicode(cleanMarkdown(input)), expected);
  assert.equal(cleanMarkdown(convertLatexToUnicode(input)), expected);
});

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
  const input = "查看 [项目地址](https://example.invalid/project) 或图片 ![图示](https://example.invalid/pic.png)";
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

test("explicit cleanup removes standalone separators and empty lines", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "第一页内容\n\n---\n\n第二页内容";
  const output = cleanMarkdown(input);
  assert.equal(output, "第一页内容\n第二页内容");
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
    "步骤一: 计算 3 * 4 * 5 = 60\n步骤二: 重要提示 注意斜体 乘法 a * b"
  );
});

test("handles discrete math markdown content with tables, lists, and formulas cleanly", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = [
    "# 离散数学：真值表与命题演算",
    "> 结论：该公式为可满足式。",
    "* 变元定义：$p, q, r$",
    "- 负号计算：-0.5 与 -x-x̄",
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
  assert.ok(output.includes("变元定义：$p, q, r$"));
  assert.ok(output.includes("负号计算：-0.5 与 -x-x̄"));
  assert.ok(output.includes("A * B 与 2 * 3"));
  assert.ok(!output.includes("#"));
  assert.ok(!output.includes("|"));
});

test("preserves math structure while compacting blank lines", async () => {
  const { cleanMarkdown } = await cleanModule;
  const formula = String.raw`$$
- x + y
+ z


a<b>c
$$`;
  const environment = String.raw`\begin{aligned}
x &= 1 \\
+ y &= 2
\end{aligned}`;
  assert.equal(cleanMarkdown(`# 标题\n${formula}\n\n${environment}`), `标题\n${formula.replace(/\n{2,}/g, "\n")}\n${environment}`);
  assert.equal(cleanMarkdown(String.raw`**结论** $a<b>c$，\(x_1 * x_2\) 与 \[x<y\]`), String.raw`结论 $a<b>c$，\(x_1 * x_2\) 与 \[x<y\]`);
});

test("keeps formula pipes inside one Markdown table cell", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = '| formula | value |\n|---|---|\n| $|x|$ | 1 |';
  assert.equal(cleanMarkdown(input), '1. formula: $|x|$ (value: 1)');
});

test("preserves incomplete and over-budget formulas during Markdown cleanup", async () => {
  const { cleanMarkdown } = await cleanModule;
  const sources = [
    '$unclosed <b>c',
    String.raw`\[x<y>z`,
    String.raw`\begin{equation}x<y>z`,
    '$1+x<y>z',
    '$1+' + 'x'.repeat(32769) + '<b>c$',
    '$' + '{'.repeat(65) + 'x<y>z' + '}'.repeat(65) + '$',
  ];
  for (const source of sources) assert.equal(cleanMarkdown('**标题**\n' + source), '标题\n' + source);
});

test("math placeholders cannot collide and code retains its original cleaning behavior", async () => {
  const { cleanMarkdown } = await cleanModule;
  assert.equal(cleanMarkdown('\ue100MATH0\ue101 **粗体** $a<b>c$'), '\ue100MATH0\ue101 粗体 $a<b>c$');
  assert.equal(cleanMarkdown('```text\n**code** $x$\n```'), 'code $x$');
  assert.equal(cleanMarkdown('`**code**`'), 'code');
});

test("shared scanner isolates nested formulas, escaped delimiters and literal content", async () => {
  const { scanMathSegments, mapMathSegments } = await import('../src/utils/mathSegments.ts');
  const nested = String.raw`\begin{pmatrix}1&\begin{matrix}a&b\\c&d\end{matrix}\\0&1\end{pmatrix}`;
  const input = String.raw`正文 $x+1$ \$5 and $10 \(y\) ` + nested;
  const math = scanMathSegments(input).filter(segment => segment.kind === 'math');
  assert.deepEqual(math.map(segment => segment.body), ['x+1', 'y', nested]);
  assert.equal(mapMathSegments(input), input);
  assert.equal(mapMathSegments(input, () => undefined), input);
  const protectedInputs = [
    '`$x$ \\frac{a}{b}`',
    '```latex\n$x$\n```',
    'https://example.com/$x$/a',
    String.raw`C:\temp\new_folder\$x$`,
    String.raw`\\server\folder\$x$`,
    '/tmp/a_$x$/file',
    './a_$x$/file',
    'assets/font_x.ttf',
    'mydir/a_1.txt',
    'a/x_1.txt',
    String.raw`mydir\a_1.txt`,
    'src/x_2/y^2.txt',
    '素材/a_1.txt',
    '![插图 1|50%]',
    '![formula $x$](img:a)',
    'Cost $5 and $10.',
    '$unclosed',
    String.raw`\[unclosed`,
    String.raw`\begin{matrix}x`,
  ];
  for (const source of protectedInputs) {
    assert.equal(scanMathSegments(source).some(segment => segment.kind === 'math'), false, source);
    assert.equal(mapMathSegments(source, (original, segment) => segment.kind === 'math' ? 'BAD' : original), source);
  }
  assert.equal(scanMathSegments('$5+2$')[0].kind, 'math');
  assert.equal(scanMathSegments('$1+x_2$10')[0].body, '1+x_2');
  assert.equal(scanMathSegments('$1+x_2$10')[0].kind, 'math');
  assert.equal(scanMathSegments('a/b').length, 0);
  assert.equal(scanMathSegments('$1+x<y')[0].safeMathLiteral, true);
  assert.equal(scanMathSegments('$' + 'x'.repeat(32769) + '$')[0].safeMathLiteral, true);
  assert.equal(scanMathSegments(String.raw`\$x\$`).length, 0);
  assert.equal(scanMathSegments('\\(x\n+y\\)')[0].body, 'x\n+y');
  assert.equal(scanMathSegments('$' + 'x'.repeat(32769) + '$')[0].kind, 'literal');
  assert.equal(scanMathSegments('$' + '{'.repeat(65) + 'x' + '}'.repeat(65) + '$')[0].kind, 'literal');
  const deep = String.raw`\begin{matrix}`.repeat(65) + 'x' + String.raw`\end{matrix}`.repeat(65);
  assert.equal(scanMathSegments(deep)[0].kind, 'literal');
  assert.equal(scanMathSegments(String.raw`\begin{a}x\end{b}`)[0].kind, 'literal');
  const segments = scanMathSegments(input);
  for (let index = 1; index < segments.length; index++) assert.ok(segments[index - 1].end <= segments[index].start);
});


test("cleanup removes only complete separator lines without losing leading content", async () => {
  const { cleanMarkdown } = await cleanModule;
  const input = "---\r\n第一段\r\n  ---\t\r\n\t\r\n\u3000\r\n  第二段\r\n前---后\r\n-1\r\n![插图 1|50%]\r\n---";
  const expected = "第一段\n  第二段\n前---后\n-1\n![插图 1|50%]";
  assert.equal(cleanMarkdown(input), expected);
  assert.equal(cleanMarkdown(expected), expected);
  assert.equal(cleanMarkdown("---\n\t\n---"), "");
  assert.equal(cleanMarkdown("---\ntitle: Example\n---\n正文"), "正文");
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
