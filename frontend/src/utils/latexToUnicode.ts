import katex from 'katex';
import { scanMathSegments, sizedGroupEnd } from './mathSegments.ts';

// KaTeX exposes an internal parser. Its output crosses an unknown boundary and
// is narrowed before access; unsupported shapes preserve the original formula.
type ArrayMode = 'standalone' | 'matrix' | 'cases';
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
function isUnknownArray(value: unknown): value is unknown[] {
  return Array.isArray(value);
}
function nodeArray(value: unknown): unknown[] {
  if (value === undefined || value === null) return [];
  if (!isUnknownArray(value)) throw new Error('Invalid math array');
  return value;
}
function textField(value: unknown): string {
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') throw new Error('Invalid math text');
  return value;
}
function nodeKind(value: unknown): string {
  return isRecord(value) ? textField(value['type']) : '';
}
function hasAstParser(
  value: unknown,
): value is { __parse: (source: string, options: Record<string, unknown>) => unknown } {
  return isRecord(value) && typeof value['__parse'] === 'function';
}

/**
 * LaTeX 公式转 Unicode 数学文本工具模块
 * 共享范围扫描器隔离公式与正文，使用 KaTeX AST 转换受支持的数学节点。
 * 无法可靠转换时保留源码；裸宏仅在明确的局部参数范围内尝试转换。
 * 将用户输入或粘贴的 LaTeX 语法 ($...$、\mid、\frac、\sqrt、\alpha、产生式等) 转换为排版清晰的 Unicode 字符
 */

// 常用 LaTeX 宏命令与数学符号映射表
const LATEX_SYMBOL_MAP: Record<string, string> = {
  // 分隔符与竖线（文法产生式、整除、集合常用）
  '\\mid': '|',
  '\\parallel': '||',
  '\\vert': '|',
  '\\lvert': '|',
  '\\rvert': '|',
  '\\lVert': '||',
  '\\rVert': '||',
  '\\langle': '⟨',
  '\\rangle': '⟩',
  '\\lfloor': '⌊',
  '\\rfloor': '⌋',
  '\\lceil': '⌈',
  '\\rceil': '⌉',
  '\\|': '||',
  '\\{': '{',
  '\\}': '}',
  '\\setminus': '\\',
  '\\backslash': '\\',

  // 箭头与推导
  '\\Rightarrow': '⇒',
  '\\Leftarrow': '⇐',
  '\\Leftrightarrow': '⇔',
  '\\Longrightarrow': '⇒',
  '\\Longleftarrow': '⇐',
  '\\Longleftrightarrow': '⇔',
  '\\longrightarrow': '→',
  '\\longleftarrow': '←',
  '\\longleftrightarrow': '↔',
  '\\rightarrow': '→',
  '\\leftarrow': '←',
  '\\to': '→',
  '\\gets': '←',
  '\\leftrightarrow': '↔',
  '\\mapsto': '↦',
  '\\longmapsto': '↦',
  '\\uparrow': '↑',
  '\\downarrow': '↓',
  '\\updownarrow': '↕',
  '\\Uparrow': '⇑',
  '\\Downarrow': '⇓',
  '\\Updownarrow': '⇕',
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
  '\\epsilon': 'ϵ',
  '\\varepsilon': 'ε',
  '\\zeta': 'ζ',
  '\\eta': 'η',
  '\\theta': 'θ',
  '\\vartheta': 'ϑ',
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
  '\\phi': 'ϕ',
  '\\varphi': 'φ',
  '\\chi': 'χ',
  '\\psi': 'ψ',
  '\\omega': 'ω',
};

// 上标与下标映射表
const SUPERSCRIPT_MAP: Record<string, string> = {
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
  n: 'ⁿ',
  i: 'ⁱ',
  x: 'ˣ',
  y: 'ʸ',
  k: 'ᵏ',
  m: 'ᵐ',
};

const SUBSCRIPT_MAP: Record<string, string> = {
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
  a: 'ₐ',
  e: 'ₑ',
  h: 'ₕ',
  i: 'ᵢ',
  j: 'ⱼ',
  k: 'ₖ',
  l: 'ₗ',
  m: 'ₘ',
  n: 'ₙ',
  o: 'ₒ',
  p: 'ₚ',
  r: 'ᵣ',
  s: 'ₛ',
  t: 'ₜ',
  u: 'ᵤ',
  v: 'ᵥ',
  x: 'ₓ',
  y: 'ᵧ',
};

// 2026-10-15：仅完整可表示的上下标使用 Unicode，避免 a^b 被误写成 ab。
function script(text: string, superscript: boolean) {
  const map = superscript ? SUPERSCRIPT_MAP : SUBSCRIPT_MAP;
  const chars = Array.from(text);
  if (superscript && /^[′″‴⁗]+$/.test(text)) return text;
  return chars.length && chars.every((c) => map[c])
    ? chars.map((c) => map[c]).join('')
    : `${superscript ? '^' : '_'}(${text})`;
}

const FRACTIONS: Record<string, string> = {
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

const EXTRA_SYMBOLS: Record<string, string> = {
  '\\langle': '⟨',
  '\\rangle': '⟩',
  '\\lfloor': '⌊',
  '\\rfloor': '⌋',
  '\\lceil': '⌈',
  '\\rceil': '⌉',
  '\\lVert': '||',
  '\\rVert': '||',
  '\\Vert': '||',
  '\\prime': '′',
  '\\doubleprime': '″',
  '\\bigcup': '⋃',
  '\\bigcap': '⋂',
  '\\bigsqcup': '⨆',
  '\\bigvee': '⋁',
  '\\bigwedge': '⋀',
  '\\biguplus': '⨄',
  '\\aleph': 'ℵ',
  '\\hbar': 'ℏ',
  '\\ell': 'ℓ',
  '\\Re': 'ℜ',
  '\\Im': 'ℑ',
  '\\angle': '∠',
  '\\perp': '⊥',
  '\\degree': '°',
  '\\%': '%',
  '\\&': '&',
  '\\$': '$',
  '\\_': '_',
  '\\#': '#',
  '\\ldotp': '.',
  '\\colon': ':',
  '\\lt': '<',
  '\\gt': '>',
  '\\not': '̸',
  '\\smallsetminus': '\\',
  '\\triangle': '△',
};
Object.assign(LATEX_SYMBOL_MAP, EXTRA_SYMBOLS);

const MAX_FORMULA_LENGTH = 16000;
const MAX_FORMULA_DEPTH = 64;

function withinBudget(text: string) {
  if (text.length > MAX_FORMULA_LENGTH) return false;
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\') {
      i++;
      continue;
    }
    if (text[i] === '{' && ++depth > MAX_FORMULA_DEPTH) return false;
    if (text[i] === '}') depth--;
  }
  return true;
}

function symbol(text: string) {
  if (Object.prototype.hasOwnProperty.call(LATEX_SYMBOL_MAP, text))
    return LATEX_SYMBOL_MAP[text] ?? text;
  if (text.startsWith('\\')) throw new Error('Unmapped math symbol');
  return text;
}

// 不用逐字替换混合普通脚标；集合字体也保留字形含义。
function blackboard(text: string) {
  const legacy: Record<string, string> = { C: 'ℂ', H: 'ℍ', N: 'ℕ', P: 'ℙ', Q: 'ℚ', R: 'ℝ', Z: 'ℤ' };
  return Array.from(text)
    .map((c) => {
      if (legacy[c]) return legacy[c];
      if (/[A-Z]/.test(c)) return String.fromCodePoint(0x1d538 + c.charCodeAt(0) - 65);
      if (/[a-z]/.test(c)) return String.fromCodePoint(0x1d552 + c.charCodeAt(0) - 97);
      if (/[0-9]/.test(c)) return String.fromCodePoint(0x1d7d8 + Number(c));
      throw new Error('Unsupported blackboard glyph');
    })
    .join('');
}

function astNodeToUnicode(value: unknown, depth = 0, arrayMode: ArrayMode = 'standalone'): string {
  if (depth > MAX_FORMULA_DEPTH) throw new Error('Math nesting limit');
  if (value === null || value === undefined) return '';
  const child = (n: unknown, mode: ArrayMode = arrayMode): string =>
    astNodeToUnicode(n, depth + 1, mode);
  if (isUnknownArray(value)) return value.map((n) => child(n)).join('');
  if (!isRecord(value)) throw new Error('Invalid math node');
  const node = value;
  switch (node['type']) {
    case 'mathord':
    case 'textord':
    case 'atom':
      return symbol(textField(node['text']) || '');
    case 'op':
      return textField(node['name'])
        ? LATEX_SYMBOL_MAP[textField(node['name'])] || textField(node['name']).replace(/^\\/, '')
        : child(node['body']);
    case 'operatorname':
      return child(node['body']);
    case 'genfrac': {
      const num = child(node['numer']).trim();
      const den = child(node['denom']).trim();
      if (!node['hasBarLine']) {
        if (textField(node['leftDelim']) === '(' && textField(node['rightDelim']) === ')')
          return `C(${num}, ${den})`;
        throw new Error('Unsupported fraction without a bar');
      }
      const fraction = FRACTIONS[`${num}/${den}`] || `(${num})/(${den})`;
      return `${textField(node['leftDelim']) ? symbol(textField(node['leftDelim'])) : ''}${fraction}${textField(node['rightDelim']) ? symbol(textField(node['rightDelim'])) : ''}`;
    }
    case 'sqrt': {
      const body = child(node['body']);
      if (!node['index']) return `√(${body})`;
      const index = child(node['index']);
      const sup = script(index, true);
      if (sup.startsWith('^')) throw new Error('Unsupported radical index');
      return `${sup}√(${body})`;
    }
    case 'supsub': {
      // 装饰在整个表达式上时保留分组，避免 underbrace{x+y}_n → x+yₙ。
      const base = child(node['base']);
      const grouped =
        nodeKind(node['base']) === 'horizBrace' ||
        (Array.from(base).length > 1 &&
          (['ordgroup', 'genfrac', 'sqrt'].includes(nodeKind(node['base'])) ||
            (nodeKind(node['base']) === 'op' && isRecord(node['base']) && node['base']['body'])));
      return `${grouped ? `(${base})` : base}${node['sub'] ? script(child(node['sub']), false) : ''}${node['sup'] ? script(child(node['sup']), true) : ''}`;
    }
    case 'horizBrace':
      return child(node['base']);
    case 'accent': {
      const base = child(node['base']);
      const marks: Record<string, string> = {
        '\\bar': '\u0304',
        '\\hat': '\u0302',
        '\\widehat': '\u0302',
        '\\vec': '\u20d7',
        '\\tilde': '\u0303',
        '\\widetilde': '\u0303',
        '\\dot': '\u0307',
        '\\ddot': '\u0308',
        '\\breve': '\u0306',
        '\\acute': '\u0301',
        '\\grave': '\u0300',
        '\\check': '\u030c',
      };
      if (!marks[textField(node['label'])]) throw new Error('Unsupported accent');
      return `${Array.from(base).length === 1 ? base : `(${base})`}${marks[textField(node['label'])]}`;
    }
    case 'overline': {
      const base = child(node['body']);
      return `${Array.from(base).length === 1 ? base : `(${base})`}\u0304`;
    }
    case 'underline': {
      const base = child(node['body']);
      return `${Array.from(base).length === 1 ? base : `(${base})`}\u0332`;
    }
    case 'array': {
      if (
        nodeArray(node['cols']).some((col) => isRecord(col) && col['type'] === 'separator') ||
        nodeArray(node['hLinesBeforeRow']).some((lines) => nodeArray(lines).length > 0)
      ) {
        throw new Error('Matrix separator has mathematical meaning');
      }
      const rows = nodeArray(node['body']).map((row) => nodeArray(row).map((cell) => child(cell)));
      if (node['colSeparationType'] === 'align' || node['colSeparationType'] === 'gather') {
        return rows
          .map((row) =>
            row
              .map((cell, i) => `${i > 0 && i % 2 === 0 ? '  ' : ''}${cell}`)
              .join('')
              .trim(),
          )
          .join('\n');
      }
      if (arrayMode === 'cases') return ` ${rows.map((row) => row.join('  ')).join(' ; ')} `;
      // 保留空单元格的位置，不能 filter(Boolean)。
      const content = ` ${rows.map((row) => row.join('  ')).join(' ; ')} `;
      return arrayMode === 'standalone' ? `[${content}]` : content;
    }
    case 'leftright': {
      const left = textField(node['left']) === '.' ? '' : symbol(textField(node['left']) || '');
      const right = textField(node['right']) === '.' ? '' : symbol(textField(node['right']) || '');
      const cases =
        left === '{' && !right && nodeArray(node['body']).some((n) => nodeKind(n) === 'array');
      return `${left}${child(node['body'], cases ? 'cases' : 'matrix')}${cases ? '}' : right}`;
    }
    case 'delimsizing':
      return textField(node['delim']) === '.' ? '' : symbol(textField(node['delim']) || '');
    case 'font':
      if (textField(node['font']) === 'mathbb') return blackboard(child(node['body']));
      if (
        [
          'mathrm',
          'mathnormal',
          'mathit',
          'mathbf',
          'boldsymbol',
          'mathsf',
          'mathtt',
          'texttt',
          'textsf',
          'textbf',
          'textit',
          'textrm',
        ].includes(textField(node['font']))
      )
        return child(node['body']);
      throw new Error('Unsupported mathematical font');
    case 'text':
    case 'styling':
    case 'sizing':
    case 'ordgroup':
    case 'color':
    case 'mclass':
      return child(node['body']);
    case 'enclose':
      if (['\\fbox', '\\colorbox', '\\fcolorbox'].includes(textField(node['label'])))
        return child(node['body']);
      throw new Error('Unsupported enclosure changes mathematical meaning');
    case 'htmlmathml':
      return child(node['mathml']);
    case 'spacing':
      return textField(node['text']) === '\\!'
        ? ''
        : textField(node['text']) === '\\qquad'
          ? '    '
          : textField(node['text']) === '\\quad'
            ? '  '
            : ' ';
    case 'kern':
      return isRecord(node['dimension']) &&
        typeof node['dimension']['number'] === 'number' &&
        node['dimension']['number'] > 0
        ? ' '
        : '';
    case 'cr':
      return '\n';
    case 'internal':
      return '';
    default:
      // KaTeX 能解析不等于本转换器能无损线性化；未知节点让整个公式保留原文。
      throw new Error(`Unsupported math node: ${textField(node['type'])}`);
  }
}

function tryConvertFormulaViaKatex(text: string) {
  if (!withinBudget(text)) return null;
  try {
    // 粘贴来的 \text{R&D} 常未转义 &；仅在文字参数中兼容，不改矩阵分列符。
    const negated: Record<string, string> = {
      equiv: '≢',
      subseteq: '⊈',
      supseteq: '⊉',
      subset: '⊄',
      supset: '⊅',
      in: '∉',
      ni: '∌',
      parallel: '∦',
      mid: '∤',
      leq: '≰',
      geq: '≱',
      '=': '≠',
      '<': '≮',
      '>': '≯',
    };
    let normalized = text.replace(
      /\\not(?![a-zA-Z])\s*(?:\\([a-zA-Z]+)|([=<>]))/g,
      (raw: string, command: string | undefined, character: string | undefined) =>
        negated[command || character || ''] || raw,
    );
    // overlay 不能作为普通前缀文字拼接，否则会否定前一个变量。
    if (/\\not(?![a-zA-Z])/.test(normalized)) return null;
    normalized = normalized.replace(/\\(?:text|textrm|textbf|textit)\s*\{[^{}]*\}/g, (token) =>
      token.replace(/(\\.)|&/g, (_match: string, escaped: string | undefined) => escaped || '\\&'),
    );
    // __parse 属于内部接口；显式失败回退、回归测试与预算共同约束升级风险。
    if (!hasAstParser(katex)) return null;
    const ast = katex.__parse(normalized, {
      throwOnError: true,
      displayMode: true,
      strict: 'ignore',
      trust: false,
      maxExpand: 500,
      maxSize: 20,
      macros: {},
    });
    return astNodeToUnicode(ast);
  } catch {
    return null;
  }
}

// 无定界符时只尝试明显的数学行，避免把英文正文吞进数学模式。
function isBareFormula(text: string) {
  if (!/[\\^_]/.test(text)) return false;
  const rest = text
    .replace(/\\(?:text|operatorname|mathrm)\s*\{[^{}]*\}/g, '')
    .replace(/\\[a-zA-Z]+|\\./g, '')
    .replace(/\b(?:sin|cos|tan|log|ln|lim|max|min|det)\b/g, '');
  return !/[a-zA-Z]{2,}/.test(rest) && !Array.from(rest).some((c) => (c.codePointAt(0) ?? 0) > 127);
}

function argumentEnd(text: string, start: number) {
  let cursor = start;
  if (text[cursor] === '{' || text[cursor] === '[') {
    const open = text[cursor],
      close = open === '{' ? '}' : ']';
    let depth = 1;
    while (++cursor < text.length && depth) {
      if (text[cursor] === '\\') {
        cursor++;
        continue;
      }
      if (text[cursor] === open) depth++;
      if (text[cursor] === close) depth--;
    }
    return depth ? start : cursor;
  }
  const token = /^(?:\\[a-zA-Z]+|\\.|[^\s])/u.exec(text.slice(cursor));
  return token ? cursor + token[0].length : start;
}

// 正文中孤立的裸宏只消费自己的参数，不改周围空格、路径或标识符。
function convertBareText(text: string) {
  const lines = text.split('\n');
  return lines
    .map((line, lineIndex) => {
      if (!withinBudget(line)) return line;
      if (isBareFormula(line.trim())) {
        const converted = tryConvertFormulaViaKatex(line.trim());
        if (converted !== null) {
          const output =
            lineIndex < lines.length - 1 && converted.endsWith('\n')
              ? converted.slice(0, -1)
              : converted;
          return (line.match(/^\s*/)?.[0] ?? '') + output + (line.match(/\s*$/)?.[0] ?? '');
        }
        return line;
      }
      const command =
        /\\([a-zA-Z]+|[^a-zA-Z\n])|(?<![\w])([0-9]*[a-zA-Z]|[0-9])((?:[_^](?:\{[^{}]*\}|[a-zA-Z0-9]))+)|([)\]])((?:[_^](?:\{[^{}]*\}|[a-zA-Z0-9]))+)/g;
      let result = '',
        cursor = 0,
        match;
      while ((match = command.exec(line))) {
        let end = command.lastIndex;
        if (match[1]) {
          const name = match[1];
          if (name === 'left') {
            const groupEnd = sizedGroupEnd(line, match.index);
            if (groupEnd !== null) {
              end = groupEnd;
              if (/^\{\}[_^]/.test(line.slice(end))) end += 2;
            }
          }
          if (name === '\\') {
            result += line.slice(cursor, match.index) + '\n';
            cursor = end;
            continue;
          }
          const arity = /^(?:frac|dfrac|tfrac|binom|dbinom|tbinom|overset|underset)$/.test(name)
            ? 2
            : /^(?:sqrt|boxed|fbox|text|mathrm|mathbb|mathcal|mathfrak|mathbf|mathit|mathsf|mathtt|operatorname|bar|overline|underline|hat|widehat|vec|tilde|widetilde|dot|ddot|underbrace|overbrace)$/.test(
                  name,
                )
              ? 1
              : 0;
          if (arity && /^\s+[a-zA-Z]/.test(line.slice(end))) {
            // 正文提及 “Use \frac in prose” 没有明确参数，不把 in 消费成 i/n。
            result += line.slice(cursor, end);
            cursor = end;
            continue;
          }
          if (name === 'sqrt') {
            const next = end + (line.slice(end).match(/^\s*/)?.[0].length ?? 0);
            if (line[next] === '[') end = argumentEnd(line, next);
          }
          for (let i = 0; i < arity; i++) {
            const next = end + (line.slice(end).match(/^\s*/)?.[0].length ?? 0);
            const after = argumentEnd(line, next);
            if (after === next) {
              end = line.length;
              break;
            }
            end = after;
          }
          // 连续裸宏的上下标属于同一原子。
          while (line[end] === '_' || line[end] === '^') {
            const after = argumentEnd(line, end + 1);
            if (after === end + 1) break;
            end = after;
          }
        }
        const raw = line.slice(match.index, end);
        const converted = match[4]
          ? tryConvertFormulaViaKatex(`{}${match[5]}`)
          : tryConvertFormulaViaKatex(raw);
        result +=
          line.slice(cursor, match.index) +
          (converted === null ? raw : (match[4] ?? '') + converted);
        cursor = end;
        command.lastIndex = end;
      }
      return result + line.slice(cursor);
    })
    .join('\n');
}

export function convertLatexToUnicode(text: string) {
  if (!text || typeof text !== 'string') return '';
  let result = '',
    cursor = 0;
  for (const segment of scanMathSegments(text)) {
    result += convertBareText(text.slice(cursor, segment.start));
    const raw = text.slice(segment.start, segment.end);
    result += segment.kind === 'math' ? (tryConvertFormulaViaKatex(segment.body) ?? raw) : raw;
    cursor = segment.end;
  }
  return result + convertBareText(text.slice(cursor));
}

export function hasLatexMarkup(text: string) {
  if (!text || typeof text !== 'string') return false;
  let cursor = 0;
  for (const segment of scanMathSegments(text)) {
    if (segment.kind === 'math' || hasBareMarkup(text.slice(cursor, segment.start))) return true;
    cursor = segment.end;
  }
  return hasBareMarkup(text.slice(cursor));
}

function hasBareMarkup(text: string) {
  return /\\(?:[a-zA-Z]+)(?![a-zA-Z])|\\\\|(?:(?<![\w])(?:[0-9]*[a-zA-Z]|[0-9])|[)\]])[_^](?:\{|[a-zA-Z0-9])/.test(
    text,
  );
}
