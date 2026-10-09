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
// 只在线性化的数学区域中移除对齐符，避免删除正文中的 R&D 等文本。
function cleanMathLayout(text) {
  return text
    .replace(/\\(?:text|mathrm|mathbf|mathit|operatorname)\{[^{}]*\}|\\&|&/g, token => token === '&' ? '' : token)
    .replace(/[ \t]*\\\\\*?(?:[ \t]*\[[^\]\n]*\])?[ \t]*(?:\r?\n)?/g, '\n');
}

// 处理矩阵环境：将二维 & 与 \\ 布局转为带括号或方括号的数学表达
function flattenMatrixLayout(name, body) {
  const openBracket = name === 'pmatrix' ? '(' : name === 'bmatrix' ? '[' : name === 'Bmatrix' ? '{' : name === 'vmatrix' || name === 'Vmatrix' ? '|' : '[';
  const closeBracket = name === 'pmatrix' ? ')' : name === 'bmatrix' ? ']' : name === 'Bmatrix' ? '}' : name === 'vmatrix' || name === 'Vmatrix' ? '|' : ']';
  
  // 替换矩阵内部换行符 \\
  const cleanedRowsText = body.replace(/[ \t]*\\\\\*?(?:[ \t]*\[[^\]\n]*\])?[ \t]*(?:\r?\n)?/g, '\n');
  const rows = cleanedRowsText.split('\n')
    .map(r => r.trim())
    .filter(r => r.length > 0);
  
  if (rows.length === 0) return `${openBracket}${closeBracket}`;
  
  const formattedRows = rows.map(r => {
    // 按列分割 &
    const cols = r.split('&').map(c => c.trim()).filter(c => c.length > 0);
    return cols.join('  ');
  });

  return `${openBracket} ${formattedRows.join(' ; ')} ${closeBracket}`;
}

function stripMathLayout(text) {
  // 1. 矩阵环境降级平铺：matrix, pmatrix, bmatrix, Bmatrix, vmatrix, Vmatrix
  const matrixEnv = /\\begin\{(matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix)\}(?:\[(?:t|c|b)\])?([\s\S]*?)\\end\{\1\}/g;
  let s = text.replace(matrixEnv, (_, name, body) => flattenMatrixLayout(name, body));

  // 2. 线性多行公式环境
  const environment = /\\begin\{(aligned|align\*?|equation\*?|gather\*?|gathered|multline\*?|split)\}(?:\[(?:t|c|b)\])?([\s\S]*?)\\end\{\1\}/g;
  s = s.replace(environment, (_, name, body) => cleanMathLayout(stripMathLayout(body)).trim());
  s = s.replace(/\\\[([\s\S]*?)\\\]|\\\(([\s\S]*?)\\\)|\$\$([\s\S]*?)\$\$|\$([^$\n]*?)\$/g,
    (_, display, inline, dollars, single) => cleanMathLayout(display ?? inline ?? dollars ?? single).trim());
  // 单独粘贴的公式行也可能没有 $ 包裹，行尾的 \\\\ 是换行而非正文。
  return s.replace(/[ \t]*\\\\\*?(?:[ \t]*\[[^\]\n]*\])?[ \t]*(?:\r?\n|$)/g, '\n');
}

function unwrapBoxes(text) {
  // 用括号深度匹配参数，支持 \\boxed{\\frac{a}{b}} 和多层 boxed。
  const command = /\\(?:boxed|fbox)(?![a-zA-Z])\s*\{/g;
  let result = '';
  let cursor = 0;
  let match;
  while ((match = command.exec(text))) {
    let depth = 1;
    let end = command.lastIndex;
    for (; end < text.length && depth > 0; end++) {
      if (text[end] === '\\') { end++; continue; }
      if (text[end] === '{') depth++;
      if (text[end] === '}') depth--;
    }
    if (depth !== 0) continue; // 不完整的参数保留，不能截掉后续正文。
    result += text.slice(cursor, match.index) + unwrapBoxes(text.slice(command.lastIndex, end - 1));
    cursor = end;
    command.lastIndex = end;
  }
  return result + text.slice(cursor);
}

function unwrapFractions(text) {
  // 基于深度平衡匹配参数，彻底解决多层嵌套分式解析失败的问题：\frac{4\pi R^2 dR}{\frac{4}{3}\pi R^3}
  const fracPattern = /\\(?:frac|dfrac|tfrac)(?![a-zA-Z])\s*\{/g;
  let result = '';
  let cursor = 0;
  let match;

  while ((match = fracPattern.exec(text))) {
    // 1. 匹配分子
    let depth = 1;
    let numEnd = fracPattern.lastIndex;
    for (; numEnd < text.length && depth > 0; numEnd++) {
      if (text[numEnd] === '\\') { numEnd++; continue; }
      if (text[numEnd] === '{') depth++;
      if (text[numEnd] === '}') depth--;
    }
    if (depth !== 0) continue;
    const numerator = text.slice(fracPattern.lastIndex, numEnd - 1);

    // 2. 匹配分母（紧跟在后面的花括号）
    let denomStart = numEnd;
    while (denomStart < text.length && /\s/.test(text[denomStart])) {
      denomStart++;
    }
    if (text[denomStart] !== '{') continue;

    depth = 1;
    let denomEnd = denomStart + 1;
    for (; denomEnd < text.length && depth > 0; denomEnd++) {
      if (text[denomEnd] === '\\') { denomEnd++; continue; }
      if (text[denomEnd] === '{') depth++;
      if (text[denomEnd] === '}') depth--;
    }
    if (depth !== 0) continue;
    const denominator = text.slice(denomStart + 1, denomEnd - 1);

    // 递归解析分子和分母内部的嵌套分式
    const parsedNum = unwrapFractions(numerator);
    const parsedDenom = unwrapFractions(denominator);

    result += text.slice(cursor, match.index) + `(${parsedNum})/(${parsedDenom})`;
    cursor = denomEnd;
    fracPattern.lastIndex = denomEnd;
  }

  return result + text.slice(cursor);
}

export function convertLatexToUnicode(text) {
  if (!text || typeof text !== 'string') {
    return '';
  }

  let s = unwrapBoxes(stripMathLayout(text));
  s = unwrapFractions(s);

  // 1. 处理 \text{...}, \mathrm{...}, \mathbf{...}, \mathit{...}, \operatorname{...} -> 保留内部文字
  s = s.replace(/\\(text|mathrm|mathbf|mathit|operatorname|textbf|textit|textsf|texttt)\{([^{}]+)\}/g, '$2');

  // 2. 剥离 \left 和 \right 前缀（如 \left| -> |, \left( -> (），注意不能误伤 \rightarrow / \leftarrow 等
  s = s.replace(/\\left(?![a-zA-Z])\s*([([{|.])?/g, '$1');
  s = s.replace(/\\right(?![a-zA-Z])\s*([)\]}|.])?/g, '$1');

  // 3. 替换标准宏命令与特殊符号
  for (const [cmd, sym] of Object.entries(LATEX_SYMBOL_MAP)) {
    // 准确匹配形如 \varepsilon, \pi, \le, \| 的宏命令
    const cleanCmd = cmd.replace(/^\\+/, '');
    const isWordCmd = /[a-zA-Z]$/.test(cleanCmd);
    const escaped = cleanCmd.replace(/([|{}[\]()])/g, '\\$1');
    const regex = isWordCmd ? new RegExp('\\\\' + escaped + '(?![a-zA-Z])', 'g') : new RegExp('\\\\' + escaped, 'g');
    s = s.replace(regex, sym);
  }

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

  // 9. 清理转义百分号与其它转义符号
  s = s.replace(/\\%/g, '%');
  s = s.replace(/\\([a-zA-Z]+)/g, '$1');

  return s.replace(/\\&/g, '&');
}

/**
 * 判断文本中是否包含 LaTeX 公式标记
 * @param {string} text
 * @returns {boolean}
 */
export function hasLatexMarkup(text) {
  if (!text || typeof text !== 'string') return false;
  return /\$|\\(?:begin\{|end\{|boxed\b|fbox\b|[()[\]]|\\)|\\(mid|frac|sqrt|alpha|beta|Rightarrow|rightarrow|to|sum|prod|in|leq|geq|neq|text|mathrm)|\^\{|_\{/.test(text);
}
