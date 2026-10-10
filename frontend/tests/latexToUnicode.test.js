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
    ['pearson complex formula', String.raw`$r = \frac{\sum (x_i - \bar{x})(y_i - \bar{y})}{\sqrt{\sum(x_i - \bar{x})^2}\sqrt{\sum(y_i - \bar{y})^2}}$`, 'r=(∑(xᵢ-x̄)(yᵢ-ȳ))/(√(∑(xᵢ-x̄)²)√(∑(yᵢ-ȳ)²))'],
    ['euclidean distance formula', String.raw`$d(x, y) = \sqrt{(1-2)^2 + (1-2)^2} = \sqrt{4} = 2$`, 'd(x,y)=√((1-2)²+(1-2)²)=√(4)=2'],
    ['cosine similarity fraction', String.raw`$\cos(x, y) = \frac{x \cdot y}{\|x\|_2 \|y\|_2}$`, 'cos(x,y)=(x·y)/(||x||₂||y||₂)'],
    ['implies and long arrows', String.raw`$$0 \implies \cos(x, y) = 0$$`, '0  ⇒  cos(x,y)=0'],
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
