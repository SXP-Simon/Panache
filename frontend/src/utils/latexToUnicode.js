/**
 * LaTeX 公式转 Unicode 数学文本工具模块
 * 将用户输入或粘贴的 LaTeX 语法 ($...$、\mid、\frac、\sqrt、\alpha、产生式等) 转换为排版清晰的 Unicode 字符
 */

// 常用 LaTeX 宏命令与数学符号映射表
const LATEX_SYMBOL_MAP = {
  // 分隔符与竖线（文法产生式、整除、集合常用）
  '\\mid': '|',
  '\\parallel': '||',
  '\\vert': '|',
  '\\lvert': '|',
  '\\rvert': '|',
  '\\|': '||',
  '\\{': '{',
  '\\}': '}',
  '\\setminus': '\\',
  '\\backslash': '\\',

  // 箭头与推导
  '\\Rightarrow': '⇒',
  '\\Leftarrow': '⇐',
  '\\Leftrightarrow': '⇔',
  '\\rightarrow': '→',
  '\\leftarrow': '←',
  '\\to': '→',
  '\\gets': '←',
  '\\leftrightarrow': '↔',
  '\\mapsto': '↦',
  '\\uparrow': '↑',
  '\\downarrow': '↓',
  '\\implies': '⇒',
  '\\iff': '⇔',

  // 关系与逻辑
  '\\neq': '≠',
  '\\ne': '≠',
  '\\leq': '≤',
  '\\le': '≤',
  '\\geq': '≥',
  '\\ge': '≥',
  '\\approx': '≈',
  '\\equiv': '≡',
  '\\sim': '~',
  '\\simeq': '~=',
  '\\cong': '≅',
  '\\propto': '∝',
  '\\in': '∈',
  '\\notin': '∉',
  '\\ni': '∋',
  '\\owns': '∋',
  '\\subset': '⊂',
  '\\subseteq': '⊆',
  '\\supset': '⊃',
  '\\supseteq': '⊇',
  '\\cup': '∪',
  '\\cap': '∩',
  '\\land': '∧',
  '\\lor': '∨',
  '\\neg': '¬',
  '\\lnot': '¬',
  '\\forall': '∀',
  '\\exists': '∃',
  '\\nexists': '∄',
  '\\emptyset': '∅',
  '\\varnothing': '∅',
  '\\models': '⊨',
  '\\vdash': '⊢',
  '\\bot': '⊥',
  '\\top': '⊤',

  // 运算与函数
  '\\times': '×',
  '\\div': '÷',
  '\\pm': '±',
  '\\mp': '∓',
  '\\cdot': '·',
  '\\circ': '∘',
  '\\bullet': '•',
  '\\star': '*',
  '\\ast': '*',
  '\\oplus': '⊕',
  '\\otimes': '⊗',
  '\\odot': '⊙',
  '\\sum': '∑',
  '\\prod': '∏',
  '\\coprod': '∐',
  '\\infty': '∞',
  '\\partial': '∂',
  '\\nabla': '∇',
  '\\int': '∫',
  '\\iint': '∬',
  '\\iiint': '∭',
  '\\oint': '∮',

  // 省略号与空白
  '\\dots': '...',
  '\\ldots': '...',
  '\\cdots': '···',
  '\\vdots': '⋮',
  '\\ddots': '⋱',
  '\\quad': '  ',
  '\\qquad': '    ',

  // 希腊大写字母
  '\\Gamma': 'Γ',
  '\\Delta': 'Δ',
  '\\Theta': 'Θ',
  '\\Lambda': 'Λ',
  '\\Xi': 'Ξ',
  '\\Pi': 'Π',
  '\\Sigma': 'Σ',
  '\\Upsilon': 'Υ',
  '\\Phi': 'Φ',
  '\\Psi': 'Ψ',
  '\\Omega': 'Ω',

  // 希腊小写字母
  '\\alpha': 'α',
  '\\beta': 'β',
  '\\gamma': 'γ',
  '\\delta': 'δ',
  '\\epsilon': 'ε',
  '\\varepsilon': 'ε',
  '\\zeta': 'ζ',
  '\\eta': 'η',
  '\\theta': 'θ',
  '\\vartheta': 'θ',
  '\\iota': 'ι',
  '\\kappa': 'κ',
  '\\lambda': 'λ',
  '\\mu': 'μ',
  '\\nu': 'ν',
  '\\xi': 'ξ',
  '\\pi': 'π',
  '\\varpi': 'ϖ',
  '\\rho': 'ρ',
  '\\varrho': 'ϱ',
  '\\sigma': 'σ',
  '\\varsigma': 'ς',
  '\\tau': 'τ',
  '\\upsilon': 'υ',
  '\\phi': 'φ',
  '\\varphi': 'φ',
  '\\chi': 'χ',
  '\\psi': 'ψ',
  '\\omega': 'ω',
};

// 上标与下标映射表
const SUPERSCRIPT_MAP = {
  '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
  '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
  '+': '⁺', '-': '⁻', '=': '⁼', '(': '⁽', ')': '⁾',
  'n': 'ⁿ', 'i': 'ⁱ', 'x': 'ˣ', 'y': 'ʸ', 'k': 'ᵏ', 'm': 'ᵐ'
};

const SUBSCRIPT_MAP = {
  '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄',
  '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
  '+': '₊', '-': '₋', '=': '₌', '(': '₍', ')': '₎',
  'a': 'ₐ', 'e': 'ₑ', 'o': 'ₒ', 'x': 'ₓ', 'i': 'ᵢ', 'j': 'ⱼ', 'k': 'ₖ', 'm': 'ₘ', 'n': 'ₙ', 'p': 'ₚ', 's': 'ₛ', 't': 'ₜ'
};

/**
 * 将单段公式或文本中的 LaTeX 语法转换为可读 Unicode 数学文本
 * @param {string} text 输入文本（可包含 $...$、\mid、\frac、\sqrt 等）
 * @returns {string} 转换后的文本
 */
export function convertLatexToUnicode(text) {
  if (!text || typeof text !== 'string') {
    return '';
  }

  let s = text;

  // 1. 处理 \text{...}, \mathrm{...}, \mathbf{...}, \mathit{...}, \operatorname{...} -> 保留内部文字
  s = s.replace(/\\(text|mathrm|mathbf|mathit|operatorname|textbf|textit|textsf|texttt)\{([^{}]+)\}/g, '$2');

  // 2. 剥离 \left 和 \right 前缀（如 \left| -> |, \left( -> (），注意不能误伤 \rightarrow / \leftarrow 等
  s = s.replace(/\\left(?![a-zA-Z])\s*([([{|.])?/g, '$1');
  s = s.replace(/\\right(?![a-zA-Z])\s*([)\]}|.])?/g, '$1');

  // 3. 替换标准宏命令与特殊符号
  for (const [cmd, sym] of Object.entries(LATEX_SYMBOL_MAP)) {
    const escapedCmd = cmd.replace(/([\\|{}])/g, '\\$1');
    // 对于字母结尾的命令，使用单词边界；非字母结尾直接替换
    const isWordCmd = /[a-zA-Z]$/.test(cmd);
    const regex = isWordCmd ? new RegExp(escapedCmd + '(?![a-zA-Z])', 'g') : new RegExp(escapedCmd, 'g');
    s = s.replace(regex, sym);
  }

  // 4. 替换分式 \frac{a}{b} -> (a)/(b)
  s = s.replace(/\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g, '($1)/($2)');
  s = s.replace(/\\dfrac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g, '($1)/($2)');
  s = s.replace(/\\tfrac\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g, '($1)/($2)');

  // 5. 替换根号 \sqrt{x} -> √(x), \sqrt[n]{x} -> ⁿ√(x)
  s = s.replace(/\\sqrt\s*\[([^{}]+)\]\s*\{([^{}]+)\}/g, (match, n, inner) => {
    const supN = n.split('').map(c => SUPERSCRIPT_MAP[c] || c).join('');
    return `${supN}√(${inner})`;
  });
  s = s.replace(/\\sqrt\s*\{([^{}]+)\}/g, '√($1)');

  // 6. 替换上标与下标：x^{2} -> x²，x_1 -> x₁，A_{1} -> A₁
  s = s.replace(/\^\{([0-9+\-=()nixykm]+)\}/g, (match, p1) => {
    return p1.split('').map(c => SUPERSCRIPT_MAP[c] || c).join('');
  });
  s = s.replace(/\^([0-9+\-=()nixykm])/g, (match, p1) => {
    return SUPERSCRIPT_MAP[p1] || match;
  });

  s = s.replace(/_\{([0-9+\-=()aeoxijkmnpst]+)\}/g, (match, p1) => {
    return p1.split('').map(c => SUBSCRIPT_MAP[c] || c).join('');
  });
  s = s.replace(/_([0-9+\-=()aeoxijkmnpst])/g, (match, p1) => {
    return SUBSCRIPT_MAP[p1] || match;
  });

  // 7. 清理包裹公式的 $ 与 $$ 标记
  s = s.replace(/\$\$(.*?)\$\$/gs, '$1');
  s = s.replace(/\$(.*?)\$/g, '$1');

  // 8. 清理多余的 LaTeX 空格调整符（如 \, \: \; \! 等）
  s = s.replace(/\\[,;:! ]/g, ' ');

  // 9. 清理孤立的反斜杠与多余空格
  s = s.replace(/\\([a-zA-Z]+)/g, '$1');

  return s;
}

/**
 * 判断文本中是否包含 LaTeX 公式标记
 * @param {string} text
 * @returns {boolean}
 */
export function hasLatexMarkup(text) {
  if (!text || typeof text !== 'string') return false;
  return /\$|\\(mid|frac|sqrt|alpha|beta|Rightarrow|rightarrow|to|sum|prod|in|leq|geq|neq|text|mathrm)|\^\{|_\{/.test(text);
}
