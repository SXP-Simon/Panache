const assert = require('assert').strict;

async function run() {
  const { convertLatexToUnicode: convert, hasLatexMarkup } = await import('../src/utils/latexToUnicode.ts');
  const cases = [
    ['mixed prose coefficient powers', String.raw`导数：3x^2 + 12y_1，标识符 abc3x^2 不变。`, String.raw`导数：3x² + 12y₁，标识符 abc3x^2 不变。`],
    ['mixed prose evaluation limits', String.raw`左边：\int_{-1}^{1} x^2 dx = \left. \frac{1}{3}x^3 \right\vert{}_{-1}^{1} = \frac{2}{3}`, '左边：∫₋₁¹ x² dx = ⅓x³|₋₁¹ = ⅔'],
    ['mixed prose paired bracket and powers', String.raw`右边：\frac{1}{2}\left[ (\frac{1}{2}-\frac{1}{2\sqrt{3}})^3 + (\frac{1}{2}+\frac{1}{2\sqrt{3}})^3 \right]`, '右边：½[(½-(1)/(2√(3)))³+(½+(1)/(2√(3)))³]'],
    ['mixed prose nested delimiters', String.raw`展开：2 \times \left( \left[ x^2 \right]+y \right)^3。`, '展开：2 × ([x²]+y)³。'],
    ['mixed prose ordinary closing powers', String.raw`验证：(-1)^2 + 3(1)^2 + [x]^3。`, '验证：(-1)² + 3(1)² + [x]³。'],
    ['invalid paired group preserves source', String.raw`结果：\left[ \unknown{x} \right]`, String.raw`结果：\left[ \unknown{x} \right]`],
    ['aligned rows', String.raw`\begin{aligned}x &= 1 \\ y &= 2\end{aligned}`, 'x=1\ny=2'],
    ['display wrapper', String.raw`\[\begin{aligned}x&=1\\y&=2\end{aligned}\]`, 'x=1\ny=2'],
    ['starred align and spacing', String.raw`\begin{align*}x&=1\\[2pt]y&=2\end{align*}`, 'x=1\ny=2'],
    ['line-end row break', 'x=1' + String.raw`\\` + '\ny=2', 'x=1\ny=2'],
    ['final row break', String.raw`x=1\\`, 'x=1\n'],
    ['boxed formula', String.raw`$\boxed{x^2+\alpha}$`, 'x²+α'],
    ['nested braces', String.raw`\boxed{\frac{a}{b}}`, '(a)/(b)'],
    ['nested boxes', String.raw`\boxed{\boxed{x_1}}`, 'x₁'],
    ['escaped braces', String.raw`\boxed{\{a,b\}}`, '{a,b}'],
    ['inline math wrapper', String.raw`答案：\(x_1\leq 2\)。`, '答案：x₁≤2。'],
    ['existing conversions', String.raw`$\sqrt{x}+\frac{a}{b}\Rightarrow\beta$`, '√(x)+(a)/(b)⇒β'],
    ['literal ampersand', String.raw`$\text{R&D}\quad A\&B$`, 'R&D A&B'],
    ['plain prose', 'R&D，https://example.com/a//b，a/b，普通正文。', 'R&D，https://example.com/a//b，a/b，普通正文。'],
    ['invalid box retains content', String.raw`\boxed{x+1 后面的正文`, String.raw`\boxed{x+1 后面的正文`],
    ['pmatrix matrix', String.raw`\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}`, '⟦ pmatrix: 1  2 ; 3  4 ⟧'],
    ['bmatrix matrix', String.raw`\begin{bmatrix}a & b \\ c & d\end{bmatrix}`, '⟦ bmatrix: a  b ; c  d ⟧'],
    ['pearson complex formula', String.raw`$r = \frac{\sum (x_i - \bar{x})(y_i - \bar{y})}{\sqrt{\sum(x_i - \bar{x})^2}\sqrt{\sum(y_i - \bar{y})^2}}$`, 'r=(∑(xᵢ-x̄)(yᵢ-ȳ))/(√(∑(xᵢ-x̄)²)√(∑(yᵢ-ȳ)²))'],
    ['euclidean distance formula', String.raw`$d(x, y) = \sqrt{(1-2)^2 + (1-2)^2} = \sqrt{4} = 2$`, 'd(x,y)=√((1-2)²+(1-2)²)=√(4)=2'],
    ['cosine similarity fraction', String.raw`$\cos(x, y) = \frac{x \cdot y}{\|x\|_2 \|y\|_2}$`, 'cos(x,y)=(x·y)/(||x||₂||y||₂)'],
    ['implies and long arrows', String.raw`$$0 \implies \cos(x, y) = 0$$`, '0 ⇒ cos(x,y)=0'],
    ['relations and sets', String.raw`$x \in A \cap B \cup C \subseteq D \neq \emptyset$`, 'x∈A∩B∪C⊆D≠∅'],
    ['multiline full homework paragraph', String.raw`- 余弦相似度：
$$x \cdot y = 0\times 1 + 1\times 0 = 0 \implies \cos(x, y) = 0$$`, `- 余弦相似度：
x·y=0×1+1×0=0 ⇒ cos(x,y)=0`],
    ['sized parentheses in boxed prose', String.raw`故所求公式为 \(\boxed{\neg\bigl(p\land(q\land\neg r)\bigr)}\)，其中仅含联结词 \(\neg\) 和 \(\land\)。`, '故所求公式为 ¬(p∧(q∧¬r))，其中仅含联结词 ¬ 和 ∧。'],
    ['sized escaped braces', String.raw`\Bigl\{x\Bigr\}`, '{x}'],
    ['sized named brackets', String.raw`\biggl\langle x\biggr\rangle`, '⟨x⟩'],
    ['sized floor and ceiling', String.raw`\bigl\lfloor x\bigr\rfloor+\Bigl\lceil y\Bigr\rceil`, '⌊x⌋+⌈y⌉'],
    ['sizing does not match longer commands', String.raw`\bigcup+\Biggish`, String.raw`\bigcup+\Biggish`],
  ];
  const sizes = ['big', 'Big', 'bigg', 'Bigg'];
  // Course examples retain meaning, and matrix markers are consumed by the
  // handwriting renderer rather than flattened into semicolon-separated text.
  cases.push(
    ['Laplace transform uses distinct calligraphic operator', String.raw`$\mathcal{L}\{f(t)\}=F(s)$`, 'ℒ{f(t)}=F(s)'],
    ['Fourier transform retains bound and complex phase', String.raw`$\mathcal{F}\{x(t)\}=\int_{-\infty}^{\infty}x(t)e^{-j\omega t}\,dt$`, 'ℱ{x(t)}=∫_(-∞)^(∞)x(t)e^(-jωt) dt'],
    ['all calligraphic capitals including legacy Unicode positions', String.raw`$\mathcal{ABCDEFGHIJKLMNOPQRSTUVWXYZ}$`, '𝒜ℬ𝒞𝒟ℰℱ𝒢ℋℐ𝒥𝒦ℒℳ𝒩𝒪𝒫𝒬ℛ𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵'],
    ['RLC impedance', String.raw`$Z=R+j\omega L+\frac{1}{j\omega C}$`, 'Z=R+jωL+(1)/(jωC)'],
    ['phasor polar notation', String.raw`$\dot{U}=220\angle30^\circ\,\mathrm{V}$`, 'U̇=220∠30° V'],
    ['function composition stays on the baseline', String.raw`$(f\circ g)(x)=f(g(x))$`, '(f∘g)(x)=f(g(x))'],
    ['named functions separate from their arguments', String.raw`$\sin x+\cos\theta+\log_2 n+\sin^2 x$`, 'sin x+cos θ+log₂ n+sin² x'],
    ['operator name keeps argument boundary', String.raw`$\operatorname{rank}A+\arg\max_x P(x)$`, 'rank A+arg maxₓ P(x)'],
    ['function parentheses remain compact', String.raw`$\det(A)+\exp(-x)+\sin(x)$`, 'det(A)+exp(-x)+sin(x)'],
    ['Gauss surface integral is not the word oiint', String.raw`$\oiint_S\vec{D}\cdot d\vec{S}=Q$`, '∯_(S)D⃗·dS⃗=Q'],
    ['closed volume and integral aliases', String.raw`$\oiiint_Vf\,dV+\intop_0^1x\,dx+\smallint f$`, '∰_(V)f dV+∫₀¹x dx+∫f'],
    ['Faraday law', String.raw`$\oint_C\vec{E}\cdot d\vec{l}=-\frac{d\Phi_B}{dt}$`, '∮_(C)E⃗·dl⃗=-(dΦ_(B))/(dt)'],
    ['heat equation partial derivatives', String.raw`$\frac{\partial u}{\partial t}=\alpha\frac{\partial^2u}{\partial x^2}$`, '(∂u)/(∂t)=α(∂²u)/(∂x²)'],
    ['conditional probability', String.raw`$\Pr(A\mid B)=\frac{\Pr(A\cap B)}{\Pr(B)}$`, 'Pr(A|B)=(Pr(A∩B))/(Pr(B))'],
    ['quantum state ket', String.raw`$\ket{\psi}=\alpha\ket0+\beta\ket1$`, '|ψ⟩=α|0⟩+β|1⟩'],
    ['number theory congruence', String.raw`$a\equiv b\pmod{n}$`, 'a≡b (mod n)'],
    ['number theory remainder', String.raw`$a\bmod n$`, 'a mod n'],
    ['definition and logical inference', String.raw`$A\triangleq B\quad\because x\ll y\quad\therefore x\ne y$`, 'A≜B ∵x≪y ∴x≠y'],
    ['geometry angle variants', String.raw`$\measuredangle ABC+\sphericalangle DEF$`, '∡ABC+∢DEF'],
    ['chemical equilibrium direction retained', String.raw`$A\rightleftharpoons B$`, 'A⇌B'],
    ['set builder middle delimiter', String.raw`$\left\{x\in\mathbb R\middle|x>0\right\}$`, '{x∈ℝ|x>0}'],
    ['paper equation number remains visible', String.raw`\[E=mc^2\tag{1}\]`, 'E=mc²  (1)'],
    ['SI resistor and capacitor', String.raw`$R=\SI{4.7}{\kilo\ohm},C=\SI{100}{\nano\farad}$`, 'R=4.7 kΩ,C=100 nF'],
    ['SI scientific notation', String.raw`$c=\SI{3e8}{\metre\per\second}$`, 'c=3×10⁸ m/s'],
    ['SI negative exponent and leading decimal', String.raw`$\num{-.25e-03}$`, '-.25×10⁻³'],
    ['SI acceleration unit', String.raw`$g=\SI{9.81}{\metre\per\second\squared}$`, 'g=9.81 m/s²'],
    ['SI per applies to only the next unit', String.raw`$\si{\pascal\per\second\henry}$`, 'Pa H/s'],
    ['SI repeated per groups denominator', String.raw`$\si{\joule\per\mole\per\kelvin}$`, 'J/(mol K)'],
    ['SI inverse area signed unit power', String.raw`$\si{\metre\tothe{-2}}$`, 'm⁻²'],
    ['SI leading reciprocal unit', String.raw`$\si{\per\second}$`, '1/s'],
    ['SI Celsius and percentage', String.raw`$T=\SI{25}{\degreeCelsius},\eta=\SI{95}{\percent}$`, 'T=25 °C,η=95 %'],
    ['SI macro in prose keeps adjacent words', String.raw`电阻为 \SI{10}{\kilo\ohm}，正常。`, '电阻为 10 kΩ，正常。'],
    ['all matrix delimiter types are structural', String.raw`$\begin{Bmatrix}a&b\end{Bmatrix}+\begin{Vmatrix}c&d\end{Vmatrix}$`, '⟦ Bmatrix: a  b ⟧+⟦ Vmatrix: c  d ⟧'],
    ['augmented matrix keeps explicit rule', String.raw`$\left(\begin{array}{cc|c}1&0&2\\0&1&3\end{array}\right)$`, '⟦ pmatrix: 1  0 | 2 ; 0  1 | 3 ⟧'],
    ['matrix cells quote semicolons', String.raw`$\begin{pmatrix}\text{a ; b}&x\\y&z\end{pmatrix}$`, '⟦ pmatrix: "a ; b"  x ; y  z ⟧'],
    ['small matrix keeps two dimensional layout', String.raw`$\begin{smallmatrix}1&0\\0&1\end{smallmatrix}$`, '⟦ matrix: 1  0 ; 0  1 ⟧'],
    ['table text cannot impersonate a matrix protocol header', String.raw`$\begin{array}{c|c}\text{matrix: label}&x\\y&z\end{array}$`, '⟦ "matrix: label" | x ; y | z ⟧'],
    ['ordinary delimiters are not matrices', String.raw`$\left(x+1\right)^2$`, '(x+1)²'],
  );
  // 2026-10-15：正文范围、数学语义与失败保真回归。
  cases.push(
    ['mixed English preserves spaces', String.raw`The result $\frac{a}{b}$ is useful.`, 'The result (a)/(b) is useful.'],
    ['mixed Chinese preserves spaces', String.raw`结果是 \(\sqrt{x}\)，下一步。`, '结果是 √(x)，下一步。'],
    ['multiple formula spans', String.raw`Let $x_1$ and $x_2$ be roots.`, 'Let x₁ and x₂ be roots.'],
    ['bare macro in English', String.raw`The value \frac{a}{b} is useful.`, 'The value (a)/(b) is useful.'],
    ['unsupported superscript remains structural', String.raw`$a^b+x^{ab}$`, 'a^(b)+x^(ab)'],
    ['unsupported subscript remains structural', String.raw`$x_{foo}+x_A$`, 'x_(foo)+x_(A)'],
    ['whole supported scripts', String.raw`$x_{n+1}^2$`, 'xₙ₊₁²'],
    ['prime notation', String.raw`$f^{\prime}(x)$`, 'f′(x)'],
    ['binomial is not division', String.raw`$\binom{n}{k}$`, 'C(n, k)'],
    ['binomial mixed with sum', String.raw`$\sum_{k=0}^{n}\binom{n}{k}$`, '∑ₖ₌₀ⁿC(n, k)'],
    ['sets in blackboard font', String.raw`$\mathbb{R}\subseteq\mathbb{C}$`, 'ℝ⊆ℂ'],
    ['nested fraction and radical', String.raw`$\frac{\sqrt{a+\frac{b}{c}}}{d}$`, '(√(a+(b)/(c)))/(d)'],
    ['unbraced frac tokens', String.raw`$\frac\alpha\beta$`, '(α)/(β)'],
    ['unbraced radical', String.raw`$\sqrt x$`, '√(x)'],
    ['indexed radical', String.raw`$\sqrt[5]{x}$`, '⁵√(x)'],
    ['underbrace retains expression and grouping', String.raw`$\underbrace{x+y}_{n}$`, '(x+y)ₙ'],
    ['overset retains annotation structure', String.raw`$\overset{!}{=}$`, '=^(!)'],
    ['operator name', String.raw`$\operatorname{rank}(A)$`, 'rank(A)'],
    ['accent dot', String.raw`$\dot{x}+\ddot{y}$`, 'ẋ+ÿ'],
    ['underline single base', String.raw`$\underline{x}$`, 'x̲'],
    ['underline whole group', String.raw`$\underline{a+b}$`, '(a+b)̲'],
    ['underline nested radical', String.raw`$\underline{\sqrt{x}}$`, '(√(x))̲'],
    ['vector whole group', String.raw`$\vec{AB}$`, '(AB)⃗'],
    ['wide hat group', String.raw`$\widehat{xy}$`, '(xy)̂'],
    ['cases retain conditions', String.raw`$\begin{cases}x&x>0\\-x&x\leq0\end{cases}$`, '⟦ cases: x  x>0 ; -x  x≤0 ⟧'],
    ['empty matrix cells retain positions', String.raw`$\begin{pmatrix}1&\\&1\end{pmatrix}$`, '⟦ pmatrix: 1   ;   1 ⟧'],
    ['text in matrix does not create a column', String.raw`$\begin{pmatrix}\text{R&D}&2\\3&4\end{pmatrix}$`, '⟦ pmatrix: R&D  2 ; 3  4 ⟧'],
    ['nested matrix environments', String.raw`$\begin{pmatrix}1&\begin{bmatrix}a&b\\c&d\end{bmatrix}\\0&1\end{pmatrix}$`, '⟦ pmatrix: 1  ⟦ bmatrix: a  b ; c  d ⟧ ; 0  1 ⟧'],
    ['gather rows', String.raw`\begin{gather}x=1\\y=2\end{gather}`, 'x=1\ny=2'],
    ['bare scripts', 'x^2 + x_n', 'x²+xₙ'],
    ['escaped underscore is literal', String.raw`$x\_n$`, 'x_n'],
    ['grouped power', '${a+b}^2$', '(a+b)²'],
    ['fraction power', String.raw`$\frac{a}{b}^2$`, '((a)/(b))²'],
    ['operator power', String.raw`$\mathop{a+b}^2$`, '(a+b)²'],
    ['negated relation', String.raw`$x\not\subseteq Y$`, 'x⊈Y'],
    ['negated equivalence', String.raw`$\not\equiv$`, '≢'],
    ['negated equals', String.raw`$x\not=y$`, 'x≠y'],
    ['mentioning commands is not a fraction', String.raw`Use \frac in prose and \sqrt in prose.`, String.raw`Use \frac in prose and \sqrt in prose.`],
    ['multiple align groups stay distinct', String.raw`$\begin{aligned}x&=y&z&=w\\a&=b&c&=d\end{aligned}$`, 'x=y  z=w\na=b  c=d'],
    ['plain matrix preserves its unbounded layout', String.raw`$\begin{matrix}a&b\\c&d\end{matrix}$`, '⟦ matrix: a  b ; c  d ⟧'],
    ['distribution array with abbreviated fractions', String.raw`\[\begin{array}{c|cccc}X&0&1&2&3\\ \hline P&\frac8{15}&\frac4{15}&\frac2{15}&\frac1{15}\end{array}\]`, '⟦ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ⟧'],
    ['boxed distribution array', String.raw`\[\boxed{\begin{array}{c|ccc}Y&1&2&3\\ \hline P&\frac13&\frac13&\frac13\end{array}}\]`, '⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧'],
    ['bare boxed distribution array is one formula', String.raw`因此，\boxed{\begin{array}{c|cc}Y&1&2\\ \hline P&\frac12&\frac12\end{array}}。`, '因此，⟦ Y | 1  2 ; ── ; P | ½  ½ ⟧。'],
    ['bare box containing matrix and formula', String.raw`\boxed{x+\begin{matrix}1&2\\3&4\end{matrix}}`, 'x+⟦ matrix: 1  2 ; 3  4 ⟧'],
    ['bare augmented array preserves the column rule', String.raw`\begin{array}{cc|c}1&0&2\\0&1&3\end{array}`, '⟦ 1  0 | 2 ; 0  1 | 3 ⟧'],
    ['double column rules and outer rules', String.raw`$\begin{array}{|c||c|}a&b\\c&d\end{array}$`, '⟦ | a || b | ; | c || d | ⟧'],
    ['row rules at boundaries and repeated rules', String.raw`$\begin{array}{cc}\hline a&b\\\hline\hline c&d\\\hdashline\end{array}$`, '⟦ ── ; a  b ; ── ; ── ; c  d ; ╌╌ ⟧'],
    ['dashed column rule preserves position', String.raw`$\begin{array}{c:c}1&2\\3&4\end{array}$`, '⟦ 1 ┆ 2 ; 3 ┆ 4 ⟧'],
    ['empty cells retain augmented positions', String.raw`$\begin{array}{c|cc}a&&b\\&c&\end{array}$`, '⟦ a |   b ;  | c   ⟧'],
    ['determinant bounds survive internal horizontal rule', String.raw`$\begin{vmatrix}1&2\\\hline3&4\end{vmatrix}$`, '⟦ vmatrix: 1  2 ; ── ; 3  4 ⟧'],
    ['table cell semicolon is quoted without adding rows', String.raw`$\begin{array}{c|c}X&\text{a ; b}\\\hline P&1\end{array}$`, '⟦ X | "a ; b" ; ── ; P | 1 ⟧'],
    ['table text whitespace normalizes safely', String.raw`$\begin{array}{c|c}X&\text{a  b}\\\hline P&1\end{array}$`, '⟦ X | a b ; ── ; P | 1 ⟧'],
    ['table absolute bars remain cell content', String.raw`$\begin{array}{c|c}X&|a|\\\hline P&|b|\end{array}$`, '⟦ X | "|a|" ; ── ; P | "|b|" ⟧'],
    ['integral and spacing', String.raw`$\int_0^1 x\,dx$`, '∫₀¹x dx'],
    ['limit with structural lower bound', String.raw`$\lim_{x\to0}\frac{\sin x}{x}$`, 'lim_(x→0) (sin x)/(x)'],
    ['double integral', String.raw`$\iint_D f(x,y)dxdy$`, '∬_(D)f(x,y)dxdy'],
    ['Greek variant variables stay distinct', String.raw`$\epsilon+\varepsilon+\theta+\vartheta+\phi+\varphi$`, 'ϵ+ε+θ+ϑ+ϕ+φ'],
    ['amount arithmetic does not swallow later formulas', String.raw`Pay $5 + $10; $x^2$.`, 'Pay $5 + $10; x².'],
    ['chemical equation with mhchem', String.raw`$\ce{2H2 + O2 -> 2H2O}$`, '2H₂+O₂→2H₂O'],
    ['chemical equilibrium with ion charge', String.raw`$\ce{CH3COOH <=> CH3COO- + H+}$`, 'CH₃COOH⇌CH₃COO⁻+H⁺'],
    ['alignat aligned multi-column equations', String.raw`$\begin{alignat*}{2}x&=1&\quad y&=2\\a&=3&\quad b&=4\end{alignat*}$`, 'x=1   y=2\na=3   b=4'],
  );
  const preserved = [
    String.raw`$\SI[round-mode=places]{1.234}{\volt}$`,
    String.raw`$\SI{1.2(3)}{\volt}$`, String.raw`$\SI{5}{\customunit}$`,
    String.raw`$\si{\milli\kilo\ohm}$`, String.raw`$\si{\per\per\second}$`,
    String.raw`$\si{\metre\squared\cubed}$`, String.raw`$\si{\metre\per}$`,
    String.raw`$\si{\metre\tothe{1000}}$`, String.raw`$\num{1e1000}$`,
    String.raw`$\qty(\frac ab)$`, String.raw`$\ce{\unknown{formula}}$`,
    String.raw`$x\xrightarrow{\mathcal F}X$`, String.raw`$\overleftarrow{AB}$`,
    String.raw`\begin{circuitikz}\draw (0,0) to[R=$R$] (2,0);\end{circuitikz}`,
    String.raw`\begin{tikzpicture}\draw[->] (0,0)--(1,1);\end{tikzpicture}`,
    String.raw`$\unknown{x+1}$`, String.raw`$\frac{a}{$`,
    String.raw`\fbox{x+\begin{matrix}1&2\\3&4\end{matrix}}`,
    String.raw`Before $\unknown{x}$ after $x^2$.`,
    String.raw`$\cancel{x}$`, String.raw`$\mathcal{a}$`,
    String.raw`$\begin{array}{c|c}1&\unknown{x}\\\hline3&4\end{array}$`,
    String.raw`\[\boxed{\begin{array}{c|c}X&0\\\hline P&\frac1{2}\end{array}\]`,
    String.raw`$\not\models$`,
    String.raw`Cost $5 and $10. C:\temp\new_folder`,
    String.raw`Pay $5 + $10.`, String.raw`Costs $10/$20.`, String.raw`Price $5 - $2.`,
    String.raw`file:///tmp/$x^2$.txt`,
    String.raw`https://example.com/a_b/$x$/c`,
    String.raw`file_name and new_folder and x_A_suffix`,
    String.raw`Open assets/font_x.ttf and mydir/a_1.txt`,
    String.raw`![插图 1|50%](img:a_b)`,
    '`$x^2$ \\frac{a}{b}`', '```latex\n$x^2$\n```',
    String.raw`\begin{matrix}1&2`, String.raw`\[x+1`,
    '$' + 'x'.repeat(16001) + '$',
    '$' + String.raw`\boxed{`.repeat(8000) + 'x' + '}'.repeat(8000) + '$',
    String.raw`\boxed{`.repeat(8000) + 'x' + '}'.repeat(8000),
    String.raw`$\def\a{\a}\a$`,
  ];
  for (const input of preserved) {
    const expected = input.includes(' after $x^2$') ? input.replace(' after $x^2$', ' after x²') : input;
    cases.push(['preserves unsupported/literal ' + input.slice(0, 60), input, expected]);
  }
  for (const size of sizes) {
    cases.push(
      [`${size} plain delimiters`, `\\${size}(p\\${size})`, '(p)'],
      [`${size} directional delimiters`, `\\${size}l(p\\${size}m|q\\${size}r)`, '(p|q)'],
      [`${size} inline math`, `$\\${size}l(p\\${size}r)$`, '(p)'],
      [`${size} AST preserves delimiters`, `$\\frac{1}{2}+\\${size}l(p\\${size}r)$`, '½+(p)'],
    );
  }
  cases.push(
    ['AST preserves sized braces', String.raw`$\frac{1}{2}+\Bigl\{p\Bigr\}$`, '½+{p}'],
    ['AST preserves sized angle brackets', String.raw`$\frac{1}{2}+\biggl\langle p\biggr\rangle$`, '½+⟨p⟩'],
    ['AST preserves sized norms', String.raw`$\frac{1}{2}+\Biggl\lVert p\Biggr\rVert$`, '½+||p||'],
  );
  for (const [name, input, expected] of cases) {
    assert.equal(convert(input), expected, name);
    console.log(`PASS: ${name}`);
  }
  const { normalizeCourseLatex } = await import('../src/utils/courseLatex.ts');
  for (const source of [String.raw`\\SI{5}{\volt}`, String.raw`\text{Use \SI{5}{\volt} here}`, String.raw`\SI[round-mode=places]{1.2}{\volt}`]) {
    assert.equal(normalizeCourseLatex(source), source, 'literal command contexts are not unit conversions');
  }
  for (const source of [String.raw`$\begin{pmatrix}1&2\\3&4\end{pmatrix}$`, String.raw`$\begin{cases}x&x>0\\0&x\le0\end{cases}$`]) {
    const rendered = convert(source);
    assert.equal(convert(rendered), rendered, 'matrix protocol is idempotent');
  }
  const oversizedMatrix = '$\\begin{pmatrix}' + Array.from({ length: 33 }, () => '1').join('\\\\') + '\\end{pmatrix}$';
  assert.equal(convert(oversizedMatrix), oversizedMatrix, 'matrix renderer dimension budget preserves source');
  for (const input of [String.raw`\boxed{x}`, String.raw`\begin{aligned}x\end{aligned}`, String.raw`\[x\]`, String.raw`x\\`]) {
    assert.equal(hasLatexMarkup(input), true, input);
  }
  assert.equal(hasLatexMarkup('R&D https://example.com'), false);
  for (const source of ['(x)^2', '[x]_1', '3x^2']) {
    assert.equal(hasLatexMarkup(source), true, source);
  }
  assert.equal(hasLatexMarkup('}^2'), false);
  assert.equal(convert('}^2'), '}^2');
  for (const source of [String.raw`\hat{x}`, 'x^2', 'x_A', String.raw`$\binom{n}{k}$`]) {
    assert.equal(hasLatexMarkup(source), true, source);
  }
  for (const source of ['file_name', '`$x^2$`', String.raw`C:\temp\new_folder`, 'Cost $5 and $10.']) {
    assert.equal(hasLatexMarkup(source), false, source);
  }
  for (const size of sizes) {
    for (const suffix of ['', 'l', 'm', 'r']) {
      assert.equal(hasLatexMarkup(`\\${size}${suffix}(p)`), true);
    }
  }
  assert.equal(hasLatexMarkup(String.raw`\bigcup+\Biggish`), true);
  console.log(`Passed ${cases.length} conversion cases and 30 detection cases.`);
}

run().catch(error => { console.error(error); process.exitCode = 1; });
