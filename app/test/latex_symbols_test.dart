import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/utils/latex.dart';

// Explicit semantic expectations, independent of the converter's AST output.
const symbols = <String, Map<String, String>>{
  'Greek': {
    'alpha': 'α',
    'beta': 'β',
    'gamma': 'γ',
    'delta': 'δ',
    'epsilon': 'ϵ',
    'varepsilon': 'ε',
    'zeta': 'ζ',
    'eta': 'η',
    'theta': 'θ',
    'vartheta': 'ϑ',
    'iota': 'ι',
    'kappa': 'κ',
    'lambda': 'λ',
    'mu': 'μ',
    'nu': 'ν',
    'xi': 'ξ',
    'pi': 'π',
    'varpi': 'ϖ',
    'rho': 'ρ',
    'varrho': 'ϱ',
    'sigma': 'σ',
    'varsigma': 'ς',
    'tau': 'τ',
    'upsilon': 'υ',
    'phi': 'ϕ',
    'varphi': 'φ',
    'chi': 'χ',
    'psi': 'ψ',
    'omega': 'ω',
    'Gamma': 'Γ',
    'Delta': 'Δ',
    'Theta': 'Θ',
    'Lambda': 'Λ',
    'Xi': 'Ξ',
    'Pi': 'Π',
    'Sigma': 'Σ',
    'Upsilon': 'Υ',
    'Phi': 'Φ',
    'Psi': 'Ψ',
    'Omega': 'Ω',
  },
  'Relations': {
    'le': '≤',
    'leq': '≤',
    'ge': '≥',
    'geq': '≥',
    'ne': '≠',
    'neq': '≠',
    'equiv': '≡',
    'approx': '≈',
    'simeq': '≃',
    'cong': '≅',
    'sim': '~',
    'propto': '∝',
    'll': '≪',
    'gg': '≫',
    'prec': '≺',
    'succ': '≻',
    'preceq': '≼',
    'succeq': '≽',
    'perp': '⊥',
    'parallel': '||',
    'mid': '|',
    'nmid': '∤',
    'models': '⊨',
    'vdash': '⊢',
    'dashv': '⊣',
  },
  'Sets and logic': {
    'in': '∈',
    'notin': '∉',
    'ni': '∋',
    'subset': '⊂',
    'supset': '⊃',
    'subseteq': '⊆',
    'supseteq': '⊇',
    'subsetneq': '⊊',
    'supsetneq': '⊋',
    'cup': '∪',
    'cap': '∩',
    'setminus': '∖',
    'emptyset': '∅',
    'varnothing': '∅',
    'forall': '∀',
    'exists': '∃',
    'nexists': '∄',
    'neg': '¬',
    'lnot': '¬',
    'land': '∧',
    'lor': '∨',
    'wedge': '∧',
    'vee': '∨',
    'top': '⊤',
    'bot': '⊥',
  },
  'Operators': {
    'pm': '±',
    'mp': '∓',
    'times': '×',
    'div': '÷',
    'cdot': '·',
    'ast': '*',
    'star': '⋆',
    'circ': '∘',
    'bullet': '∙',
    'oplus': '⊕',
    'ominus': '⊖',
    'otimes': '⊗',
    'oslash': '⊘',
    'odot': '⊙',
    'dagger': '†',
    'ddagger': '‡',
    'partial': '∂',
    'nabla': '∇',
    'infty': '∞',
    'hbar': 'ℏ',
    'ell': 'ℓ',
    'Re': 'ℜ',
    'Im': 'ℑ',
    'aleph': 'ℵ',
    'wp': '℘',
    'angle': '∠',
    'triangle': '△',
  },
  'Arrows': {
    'to': '→',
    'rightarrow': '→',
    'leftarrow': '←',
    'leftrightarrow': '↔',
    'Rightarrow': '⇒',
    'Leftarrow': '⇐',
    'Leftrightarrow': '⇔',
    'longrightarrow': '→',
    'longleftarrow': '←',
    'longleftrightarrow': '↔',
    'Longrightarrow': '⇒',
    'Longleftarrow': '⇐',
    'Longleftrightarrow': '⇔',
    'mapsto': '↦',
    'uparrow': '↑',
    'downarrow': '↓',
    'updownarrow': '↕',
    'nearrow': '↗',
    'searrow': '↘',
    'swarrow': '↙',
    'nwarrow': '↖',
    'hookrightarrow': '↪',
    'hookleftarrow': '↩',
    'rightleftharpoons': '⇌',
    'leftrightharpoons': '⇋',
  },
};

void main() {
  for (final group in symbols.entries) {
    for (final symbol in group.value.entries) {
      test('${group.key}: \\${symbol.key} preserves its meaning', () {
        final command = '\\${symbol.key}';
        final expected = symbol.value;
        expect(convertLatex('\$$command\$'), expected);
        expect(convertLatex('\\[$command\\]'), expected);
        expect(convertLatex('符号 $command，保留正文'), '符号 $expected，保留正文');
      });
    }
  }

  for (final formula in [
    r'$\ce{2H2 + O2 -> 2H2O}$',
    r'$\pu{9.81 m/s2}$',
    r'$\qty{5}{\metre\per\second}$',
    r'$\begin{circuitikz}\draw (0,0) to[R] (1,0);\end{circuitikz}$',
    r'$\def\foo{\foo}\foo$',
    r'$\unknownphysics{x}+\alpha$',
    r'$\cancel{x}+1$',
    r'$\frac{a}{b$',
    r'$\sqrt[3{x}$',
  ]) {
    test('unsupported or malformed source remains intact: $formula', () {
      expect(convertLatex('前文 $formula 后文'), '前文 $formula 后文');
    });
  }

  test('bounded local macros expand without changing later formula scope', () {
    expect(convertLatex(r'$\newcommand{\foo}{x}\foo^2$'), 'x²');
    expect(convertLatex(r'$\foo$'), r'$\foo$');
  });

  for (final function in [
    'sin',
    'cos',
    'tan',
    'cot',
    'sec',
    'csc',
    'arcsin',
    'arccos',
    'arctan',
    'sinh',
    'cosh',
    'tanh',
    'coth',
    'log',
    'ln',
    'exp',
    'det',
    'dim',
    'gcd',
    'ker',
    'arg',
    'deg',
    'hom',
  ]) {
    test('named function $function keeps its full name and argument', () {
      expect(convertLatex('\$\\$function(x)\$'), '$function(x)');
    });
  }

  const structures = <String, String>{
    r'\sum_{i=1}^{n}x_i': '∑ᵢ₌₁ⁿxᵢ',
    r'\prod_{k=1}^{m}p_k': '∏ₖ₌₁ᵐpₖ',
    r'\int_0^1f(x)\,dx': '∫₀¹f(x) dx',
    r'\iint_Df(x,y)\,dx\,dy': '∬_(D)f(x,y) dx dy',
    r'\iiint_V\rho\,dV': '∭_(V)ρ dV',
    r'\oint_C\vec{F}\cdot d\vec{r}': '∮_(C)F⃗·dr⃗',
    r'\bigcup_{i=1}^{n}A_i': '⋃ᵢ₌₁ⁿAᵢ',
    r'\bigcap_{i=1}^{n}A_i': '⋂ᵢ₌₁ⁿAᵢ',
    r'\left\langle x,y\right\rangle': '⟨x,y⟩',
    r'\left\lfloor x\right\rfloor+\left\lceil x\right\rceil': '⌊x⌋+⌈x⌉',
    r'\left|x\right|+\left\|v\right\|': '|x|+||v||',
    r'\hat{x}+\bar{x}+\dot{x}+\ddot{x}': 'x̂+x̄+ẋ+ẍ',
    r'\overrightarrow{AB}+\overline{AB}+\underline{xy}': '(AB)⃗+(AB)̄+(xy)̲',
    r'\binom{n}{k}=\frac{n!}{k!(n-k)!}': 'C(n, k)=(n!)/(k!(n-k)!)',
    r'\mathbb{R}\supset\mathbb{Q}\supset\mathbb{Z}\supset\mathbb{N}': 'ℝ⊃ℚ⊃ℤ⊃ℕ',
    r'\mathrm{H}_2\mathrm{O}+\mathrm{CO}_2': 'H₂O+CO₂',
    r'{AB}_2+\mathrm{a+b}_2': '(AB)₂+(a+b)₂',
    r'\mathrm{Fe}^{3+}+\mathrm{CuSO}_4': 'Fe³⁺+CuSO₄',
    r'\text{速度}=\frac{\text{位移}}{\text{时间}}': '速度=(位移)/(时间)',
  };
  for (final entry in structures.entries) {
    test('composed operators and notation: ${entry.key}', () {
      expect(convertLatex('\$${entry.key}\$'), entry.value);
    });
  }

  const superscripts = {
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
    '+': '⁺',
    '-': '⁻',
    '=': '⁼',
    '(': '⁽',
    ')': '⁾',
    'n': 'ⁿ',
    'i': 'ⁱ',
    'x': 'ˣ',
    'y': 'ʸ',
    'k': 'ᵏ',
    'm': 'ᵐ',
  };
  const subscripts = {
    '0': '₀',
    '1': '₁',
    '2': '₂',
    '3': '₃',
    '4': '₄',
    '5': '₅',
    '6': '₆',
    '7': '₇',
    '8': '₈',
    '9': '₉',
    '+': '₊',
    '-': '₋',
    '=': '₌',
    '(': '₍',
    ')': '₎',
    'a': 'ₐ',
    'e': 'ₑ',
    'h': 'ₕ',
    'i': 'ᵢ',
    'j': 'ⱼ',
    'k': 'ₖ',
    'l': 'ₗ',
    'm': 'ₘ',
    'n': 'ₙ',
    'o': 'ₒ',
    'p': 'ₚ',
    'r': 'ᵣ',
    's': 'ₛ',
    't': 'ₜ',
    'u': 'ᵤ',
    'v': 'ᵥ',
    'x': 'ₓ',
    'y': 'ᵧ',
  };
  for (final (operator, mappings) in [('^', superscripts), ('_', subscripts)]) {
    for (final entry in mappings.entries) {
      test('script $operator ${entry.key} has the correct code point', () {
        expect(convertLatex('\$z$operator{${entry.key}}\$'), 'z${entry.value}');
      });
    }
  }
  for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZbcdflopqrstuvz'.split('')) {
    test(
      'unsupported superscript letter $letter retains explicit grouping',
      () {
        expect(convertLatex('\$z^{$letter}\$'), 'z^($letter)');
      },
    );
  }
}
