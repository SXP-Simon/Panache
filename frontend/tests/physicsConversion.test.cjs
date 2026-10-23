const assert = require('node:assert/strict');
const { test } = require('node:test');

const cases = [
  [
    "\\dv{y}{x}",
    "(dy)/(dx)"
  ],
  [
    "\\dv[2]{y}{x}",
    "(d²y)/(dx²)"
  ],
  [
    "\\dv{x}",
    "(d)/(dx)"
  ],
  [
    "\\pdv[2]{T}{x}",
    "(∂²T)/(∂x²)"
  ],
  [
    "\\abs{x-1}",
    "|x-1|"
  ],
  [
    "\\norm{v}",
    "||v||"
  ]
];
const unsupported = [
  "\\dv{f}{x}{y}",
  "\\dv{\\frac{1}{x}}{x}{y}",
  "\\dv{x}(x^2)",
  "\\pdv{f}{x,y}",
  "\\dv*{f}{x}",
  "\\dv[100]{y}{x}",
  "\\abs*{x}",
  "\\norm[2]{v}"
];
test('physics conversion keeps complete bare and wrapped argument lists', async () => {
  const { convertLatexToUnicode: convert } = await import('../src/utils/latexToUnicode.ts');
  for (const [source, expected] of cases) {
    assert.equal(convert(source), expected);
    assert.equal(convert('$' + source + '$'), expected);
    assert.equal(convert('结果 ' + source + '，下一步。'), '结果 ' + expected + '，下一步。');
    assert.equal(convert('`' + source + '`'), '`' + source + '`');
  }
  for (const source of unsupported) {
    assert.equal(convert(source), source);
    assert.equal(convert('$' + source + '$'), '$' + source + '$');
    assert.equal(convert('保留 ' + source + '。'), '保留 ' + source + '。');
  }
});
