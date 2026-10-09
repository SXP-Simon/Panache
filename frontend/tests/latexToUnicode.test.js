const assert = require('assert').strict;

async function run() {
  const { convertLatexToUnicode: convert, hasLatexMarkup } = await import('../src/utils/latexToUnicode.js');
  const cases = [
    ['aligned rows', String.raw`\begin{aligned}x &= 1 \\ y &= 2\end{aligned}`, 'x = 1\ny = 2'],
    ['display wrapper', String.raw`\[\begin{aligned}x&=1\\y&=2\end{aligned}\]`, 'x=1\ny=2'],
    ['starred align and spacing', String.raw`\begin{align*}x&=1\\[2pt]y&=2\end{align*}`, 'x=1\ny=2'],
    ['line-end row break', 'x=1' + String.raw`\\` + '\ny=2', 'x=1\ny=2'],
    ['final row break', String.raw`x=1\\`, 'x=1\n'],
    ['boxed formula', String.raw`$\boxed{x^2+\alpha}$`, 'x²+α'],
    ['nested braces', String.raw`\boxed{\frac{a}{b}}`, '(a)/(b)'],
    ['nested boxes', String.raw`\boxed{\boxed{x_1}}`, 'x₁'],
    ['escaped braces', String.raw`\boxed{\{a,b\}}`, '{a,b}'],
    ['inline math wrapper', String.raw`答案：\(x_1\leq 2\)。`, '答案：x₁≤ 2。'],
    ['existing conversions', String.raw`$\sqrt{x}+\frac{a}{b}\Rightarrow\beta$`, '√(x)+(a)/(b)⇒β'],
    ['literal ampersand', String.raw`$\text{R&D}\quad A\&B$`, 'R&D   A&B'],
    ['plain prose', 'R&D，https://example.com/a//b，a/b，普通正文。', 'R&D，https://example.com/a//b，a/b，普通正文。'],
    ['invalid box retains content', String.raw`\boxed{x+1 后面的正文`, 'boxed{x+1 后面的正文'],
    ['pmatrix matrix', String.raw`\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}`, '( 1  2 ; 3  4 )'],
    ['bmatrix matrix', String.raw`\begin{bmatrix}a & b \\ c & d\end{bmatrix}`, '[ a  b ; c  d ]'],
  ];
  for (const [name, input, expected] of cases) {
    assert.equal(convert(input), expected, name);
    console.log(`PASS: ${name}`);
  }
  for (const input of [String.raw`\boxed{x}`, String.raw`\begin{aligned}x\end{aligned}`, String.raw`\[x\]`, String.raw`x\\`]) {
    assert.equal(hasLatexMarkup(input), true, input);
  }
  assert.equal(hasLatexMarkup('R&D https://example.com'), false);
  console.log(`Passed ${cases.length} conversion cases and 5 detection cases.`);
}

run().catch(error => { console.error(error); process.exitCode = 1; });
