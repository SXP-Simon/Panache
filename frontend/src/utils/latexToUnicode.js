import katex from 'katex';

/**
 * LaTeX 公式转 Unicode 数学文本工具模块
 * 采用 KaTeX 工业级词法/语法树（AST）解析器 + 正则兼容兜底的双层设计
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

// 常见数字手写真分数映射（映射到底层手写竖式分数渲染器）
const VULGAR_FRACTION_MAP = {
  '1/2': '½',
  '1/3': '⅓',
  '2/3': '⅔',
  '1/4': '¼',
  '3/4': '¾',
  '1/5': '⅕',
  '2/5': '⅖',
  '3/5': '⅗',
  '4/5': '⅘',
  '1/6': '⅙',
  '5/6': '⅚',
  '1/8': '⅛',
  '3/8': '⅜',
  '5/8': '⅝',
  '7/8': '⅞',
  '4/3': '\ue001',
  '1/9': '\ue002',
  '1/10': '\ue003',
};

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
    const parsedNum = unwrapFractions(numerator).trim();
    const parsedDenom = unwrapFractions(denominator).trim();

    // 若分子分母属于常见手写简单分数，直接转换为真分数上下竖式字形
    const fracKey = `${parsedNum}/${parsedDenom}`;
    const replacement = VULGAR_FRACTION_MAP[fracKey] || `(${parsedNum})/(${parsedDenom})`;

    result += text.slice(cursor, match.index) + replacement;
    cursor = denomEnd;
    fracPattern.lastIndex = denomEnd;
  }

  return result + text.slice(cursor);
}


// 深度平衡匹配解析根号：支持 \sqrt{...} 以及多层嵌套如 \sqrt{\sum (x_i - \bar{x})^2}
function unwrapSqrt(text) {
  const sqrtPattern = /\\sqrt(?:\s*\[([^{}]+)\])?\s*\{/g;
  let result = '';
  let cursor = 0;
  let match;

  while ((match = sqrtPattern.exec(text))) {
    const rootIndex = match[1];
    let depth = 1;
    let end = sqrtPattern.lastIndex;
    for (; end < text.length && depth > 0; end++) {
      if (text[end] === '\\') { end++; continue; }
      if (text[end] === '{') depth++;
      if (text[end] === '}') depth--;
    }
    if (depth !== 0) continue;

    const inner = text.slice(sqrtPattern.lastIndex, end - 1);
    // 递归解析根号内部可能嵌套的内容
    const parsedInner = unwrapSqrt(inner);
    let replacement = `√(${parsedInner})`;
    if (rootIndex) {
      const supN = rootIndex.split('').map(c => SUPERSCRIPT_MAP[c] || c).join('');
      replacement = `${supN}√(${parsedInner})`;
    }

    result += text.slice(cursor, match.index) + replacement;
    cursor = end;
    sqrtPattern.lastIndex = end;
  }

  return result + text.slice(cursor);
}

/**
 * 基于 KaTeX AST 将语法树节点递归转换为清晰的 Unicode 文本
 * @param {object|array} node KaTeX AST 节点或节点列表
 * @returns {string}
 */
function astNodeToUnicode(node) {
  if (!node) return '';
  if (Array.isArray(node)) {
    return node.map(astNodeToUnicode).join('');
  }

  switch (node.type) {
    case 'mathord':
    case 'textord':
    case 'atom': {
      const text = node.text || '';
      if (text === '\\|') return '||';
      if (text === '\\{') return '{';
      if (text === '\\}') return '}';
      if (text === '\\&') return '&';
      if (text === '\\%') return '%';
      if (text === '\\$') return '$';
      if (LATEX_SYMBOL_MAP[text]) return LATEX_SYMBOL_MAP[text];
      if (text.startsWith('\\')) {
        const cmdName = text.slice(1);
        return LATEX_SYMBOL_MAP[text] || cmdName;
      }
      return text;
    }

    case 'op': {
      if (node.name && LATEX_SYMBOL_MAP[node.name]) {
        return LATEX_SYMBOL_MAP[node.name];
      }
      if (node.name) {
        return node.name.replace(/^\\/, '');
      }
      return node.body ? astNodeToUnicode(node.body) : '';
    }

    case 'genfrac': {
      const num = astNodeToUnicode(node.numer).trim();
      const den = astNodeToUnicode(node.denom).trim();
      // 常见手写真分数映射（映射到底层手写竖式分数渲染器）
      const fracKey = `${num}/${den}`;
      if (VULGAR_FRACTION_MAP[fracKey]) {
        return VULGAR_FRACTION_MAP[fracKey];
      }
      return `(${num})/(${den})`;
    }

    case 'sqrt': {
      const body = astNodeToUnicode(node.body);
      if (node.index) {
        const idx = astNodeToUnicode(node.index);
        const supIdx = idx.split('').map(c => SUPERSCRIPT_MAP[c] || c).join('');
        return `${supIdx}√(${body})`;
      }
      return `√(${body})`;
    }

    case 'supsub': {
      let base = astNodeToUnicode(node.base);
      if (node.sub) {
        const subText = astNodeToUnicode(node.sub);
        base += subText.split('').map(c => SUBSCRIPT_MAP[c] || c).join('');
      }
      if (node.sup) {
        const supText = astNodeToUnicode(node.sup);
        base += supText.split('').map(c => SUPERSCRIPT_MAP[c] || c).join('');
      }
      return base;
    }

    case 'accent': {
      const base = astNodeToUnicode(node.base);
      if (node.label === '\\bar' || node.label === '\\overline') {
        return base.length === 1 ? `${base}\u0304` : `(${base})\u0304`;
      }
      if (node.label === '\\hat') {
        return base.length === 1 ? `${base}\u0302` : `(${base})\u0302`;
      }
      if (node.label === '\\vec') {
        return base.length === 1 ? `${base}\u20D7` : `(${base})\u20D7`;
      }
      return base;
    }

    case 'overline': {
      const base = astNodeToUnicode(node.body);
      return base.length === 1 ? `${base}\u0304` : `(${base})\u0304`;
    }

    case 'underline': {
      return astNodeToUnicode(node.body);
    }

    case 'array': {
      // 矩阵或多行公式环境
      if (node.colSeparationType === 'align') {
        // 对齐环境（如 aligned）：行与行之间换行，列之间直接拼接
        const rows = node.body.map(row => {
          return row.map(cell => astNodeToUnicode(cell)).join('').trim();
        });
        return rows.filter(r => r.length > 0).join('\n');
      }
      // 矩阵环境：列用双空格，行用分号
      const rows = node.body.map(row => {
        return row.map(cell => astNodeToUnicode(cell).trim()).filter(c => c.length > 0).join('  ');
      });
      return ` ${rows.join(' ; ')} `;
    }

    case 'leftright': {
      let l = node.left || '';
      let r = node.right || '';
      if (l === '.') l = '';
      if (r === '.') r = '';
      if (LATEX_SYMBOL_MAP[l]) l = LATEX_SYMBOL_MAP[l];
      if (LATEX_SYMBOL_MAP[r]) r = LATEX_SYMBOL_MAP[r];
      return `${l}${astNodeToUnicode(node.body)}${r}`;
    }

    case 'text':
    case 'styling':
    case 'ordgroup':
    case 'color':
    case 'enclose':
      return astNodeToUnicode(node.body);

    case 'htmlmathml':
      if (node.mathml) return astNodeToUnicode(node.mathml);
      return astNodeToUnicode(node.html);

    case 'mclass':
      return astNodeToUnicode(node.body);

    case 'spacing':
      return node.text || ' ';

    case 'kern':
      return node.dimension && node.dimension.number >= 1 ? '  ' : ' ';

    default:
      if (node.body) return astNodeToUnicode(node.body);
      return node.text || '';
  }
}

/**
 * 尝试通过 KaTeX AST 将一段纯公式转换为 Unicode 数学文本
 * 若解析失败则返回 null
 * @param {string} formulaText
 * @returns {string|null}
 */
function tryConvertFormulaViaKatex(formulaText) {
  if (!formulaText || typeof formulaText !== 'string') return null;
  const trimmed = formulaText.trim();
  if (!trimmed) return '';

  try {
    const ast = katex.__parse(trimmed, { throwOnError: false, displayMode: true });
    if (ast && ast.length > 0) {
      return astNodeToUnicode(ast);
    }
  } catch (e) {
    // 忽略 KaTeX 解析异常，回退至正则流水线
  }
  return null;
}

export function convertLatexToUnicode(text) {
  if (!text || typeof text !== 'string') {
    return '';
  }

  // 1. 先进行盒模型展开与数学环境降级（aligned、矩阵、行尾换行符）
  let s = unwrapBoxes(stripMathLayout(text));

  // 2. 如果包含 $...$, $$...$$, \[...\], \(...\)，优先用 KaTeX AST 解析公式块
  const mathDelimRegex = /\$\$([\s\S]*?)\$\$|\\\[([\s\S]*?)\\\]|\\\(([\s\S]*?)\\\)|\$([^$\n]+?)\$/g;
  if (mathDelimRegex.test(s)) {
    s = s.replace(mathDelimRegex, (match, d1, d2, d3, d4) => {
      const expr = (d1 ?? d2 ?? d3 ?? d4 ?? '').trim();
      if (!expr) return '';
      const astResult = tryConvertFormulaViaKatex(expr);
      if (astResult !== null) {
        return astResult;
      }
      return expr;
    });
  }

  // 3. 针对未加 $ 包裹但含有明确复合公式（如整行 r = \frac{...}{...} 或 \sqrt{...}）的行进行 KaTeX AST 解析
  const lines = s.split('\n');
  const processedLines = lines.map(line => {
    const trimmed = line.trim();
    if (
      trimmed.length > 0 &&
      /\\(?:frac|dfrac|tfrac|sqrt|sum|prod|int|cos|sin|tan|lim)\b/.test(trimmed)
    ) {
      const astResult = tryConvertFormulaViaKatex(trimmed);
      if (astResult !== null) {
        return astResult;
      }
    }
    return line;
  });
  s = processedLines.join('\n');

  // 4. 正则流水线保底：处理未进入 AST 或分散在正文中的零散标记
  s = unwrapFractions(s);
  s = unwrapSqrt(s);

  // 4.1 处理统计与代数修饰符：\bar{x} -> x̄, \hat{x} -> x̂, \vec{x} -> x⃗
  s = s.replace(/\\(bar|overline)\{([a-zA-Z0-9])\}/g, '$2\u0304');
  s = s.replace(/\\(bar|overline)\{([^{}]+)\}/g, '($2)\u0304');
  s = s.replace(/\\hat\{([a-zA-Z0-9])\}/g, '$1\u0302');
  s = s.replace(/\\vec\{([a-zA-Z0-9])\}/g, '$1\u20D7');

  // 4.2 处理 \text{...}, \mathrm{...}, \mathbf{...}, \mathit{...}, \operatorname{...} -> 保留内部文字
  s = s.replace(/\\(text|mathrm|mathbf|mathit|operatorname|textbf|textit|textsf|texttt)\{([^{}]+)\}/g, '$2');

  // 4.3 剥离 \left 和 \right 前缀
  s = s.replace(/\\left(?![a-zA-Z])\s*([([{|.])?/g, '$1');
  s = s.replace(/\\right(?![a-zA-Z])\s*([)\]}|.])?/g, '$1');

  // 4.4 替换标准宏命令与特殊符号
  for (const [cmd, sym] of Object.entries(LATEX_SYMBOL_MAP)) {
    const cleanCmd = cmd.replace(/^\\+/, '');
    const isWordCmd = /[a-zA-Z]$/.test(cleanCmd);
    const escaped = cleanCmd.replace(/([|{}[\]()])/g, '\\$1');
    const regex = isWordCmd ? new RegExp('\\\\' + escaped + '(?![a-zA-Z])', 'g') : new RegExp('\\\\' + escaped, 'g');
    s = s.replace(regex, sym);
  }

  // 4.5 替换上标与下标：x^{2} -> x²，x_1 -> x₁，A_{1} -> A₁
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

  // 4.6 清理多余的 $ 与 $$ 标记
  s = s.replace(/\$\$(.*?)\$\$/gs, '$1');
  s = s.replace(/\$(.*?)\$/g, '$1');

  // 4.7 清理多余的 LaTeX 空格调整符
  s = s.replace(/\\[,;:! ]/g, ' ');

  // 4.8 清理转义百分号与其它未识别命令
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
