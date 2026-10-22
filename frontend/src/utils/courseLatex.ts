// Only unambiguous siunitx number/unit syntax is accepted. Options, uncertain
// values and custom unit definitions stay intact for the caller's safe fallback.
const PREFIXES: Record<string, string> = {
  pico: 'p',
  nano: 'n',
  micro: 'μ',
  milli: 'm',
  centi: 'c',
  deci: 'd',
  kilo: 'k',
  mega: 'M',
  giga: 'G',
  tera: 'T',
};
const UNITS: Record<string, string> = {
  metre: 'm',
  meter: 'm',
  second: 's',
  ampere: 'A',
  kelvin: 'K',
  mole: 'mol',
  candela: 'cd',
  gram: 'g',
  kilogram: 'kg',
  hertz: 'Hz',
  newton: 'N',
  pascal: 'Pa',
  joule: 'J',
  watt: 'W',
  coulomb: 'C',
  volt: 'V',
  farad: 'F',
  ohm: 'Ω',
  siemens: 'S',
  weber: 'Wb',
  tesla: 'T',
  henry: 'H',
  radian: 'rad',
  steradian: 'sr',
  degree: '°',
  degreeCelsius: '°C',
  liter: 'L',
  litre: 'L',
  electronvolt: 'eV',
  decibel: 'dB',
  percent: '\\%',
  bit: 'bit',
  byte: 'B',
};

function numberLatex(source: string): string | null {
  const match = /^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(?:[eE]([+-]?\d{1,3}))?$/.exec(source.trim());
  if (!match) return null;
  return match[2] === undefined ? (match[1] ?? null) : `${match[1]}\\times10^{${Number(match[2])}}`;
}

function unitLatex(source: string): string | null {
  const tokens = /\\([A-Za-z]+)(?:\{([+-]?\d{1,3})\})?/g;
  const numerator: string[] = [],
    denominator: string[] = [];
  let cursor = 0,
    prefix = '',
    perNext = false,
    powered = false;
  let lastTarget: string[] | null = null;
  for (const token of source.matchAll(tokens)) {
    if (source.slice(cursor, token.index).trim()) return null;
    cursor = token.index + token[0].length;
    const name = token[1] ?? '';
    if (name === 'per' && token[2] === undefined) {
      if (perNext || prefix) return null;
      perNext = true;
      lastTarget = null;
      powered = false;
    } else if (Object.hasOwn(PREFIXES, name) && token[2] === undefined) {
      if (prefix) return null;
      prefix = PREFIXES[name] ?? '';
    } else if (Object.hasOwn(UNITS, name) && token[2] === undefined) {
      const target = perNext ? denominator : numerator;
      target.push(`\\mathrm{${prefix}${UNITS[name]}}`);
      lastTarget = target;
      perNext = false;
      prefix = '';
      powered = false;
    } else if (['squared', 'cubed', 'tothe'].includes(name)) {
      if (!lastTarget?.length || prefix || powered) return null;
      const power =
        name === 'tothe'
          ? token[2]
          : token[2] === undefined
            ? name === 'squared'
              ? '2'
              : '3'
            : undefined;
      if (power === undefined) return null;
      lastTarget[lastTarget.length - 1] += `^{${Number(power)}}`;
      powered = true;
    } else return null;
  }
  if (
    source.slice(cursor).trim() ||
    prefix ||
    perNext ||
    (!numerator.length && !denominator.length)
  )
    return null;
  const top = numerator.length ? numerator.join('\\,') : '1';
  if (!denominator.length) return top;
  const bottom = denominator.join('\\,');
  return `${top}/${denominator.length > 1 ? `(${bottom})` : bottom}`;
}

function groupAt(source: string, offset: number): { body: string; end: number } | null {
  let start = offset;
  while (/\s/.test(source[start] ?? '') && start < source.length) start++;
  if (source[start] !== '{') return null;
  let depth = 1;
  for (let cursor = start + 1; cursor < source.length; cursor++) {
    if (source[cursor] === '\\') cursor++;
    else if (source[cursor] === '{') depth++;
    else if (source[cursor] === '}' && --depth === 0)
      return { body: source.slice(start + 1, cursor), end: cursor + 1 };
  }
  return null;
}

function chemicalFormulaLatex(source: string): string | null {
  // Convert standard mhchem \ce{...} formula into standard math LaTeX with correct sub/superscripts
  // Example: 'H2O' -> '\mathrm{H_2O}', 'Fe^{3+} + 3OH^- -> Fe(OH)3 v'
  let s = source.trim();
  if (!s) return null;
  // Handle reaction arrows and states
  s = s.replace(/<->|<=>/g, ' \\rightleftharpoons ');
  s = s.replace(/->/g, ' \\rightarrow ');
  s = s.replace(/\s+v(?=\s|$)/g, '\\downarrow');
  s = s.replace(/\s+\^(?=\s|$)/g, '\\uparrow');
  // Handle ion charges like ^2+, ^-, ^+, or bare trailing - and +: e.g. H+, CH3COO-, Fe3+
  s = s.replace(/\^([0-9]*[+-])/g, '^{$1}');
  s = s.replace(/([A-Za-z)\]])(\d*[+-])(?=\s|$)/g, '$1^{$2}');
  // Subscript numbers immediately following an element or parenthesis: e.g. H2 -> H_2, (OH)3 -> (OH)_3
  s = s.replace(/([A-Za-z)])(\d+)/g, '$1_{$2}');
  // Wrap non-math symbols in \mathrm for clean upright chemical representation

  return `\\mathrm{${s}}`;
}

export function normalizeCourseLatex(source: string): string {
  const commands = /\\([a-zA-Z]+|[^a-zA-Z])/g;
  let result = '',
    cursor = 0;
  for (let match = commands.exec(source); match; match = commands.exec(source)) {
    const name = match[1] ?? '';
    // Text mentions and escaped slashes do not invoke mathematical macros.
    if (['text', 'textrm', 'textbf', 'textit', 'texttt'].includes(name)) {
      const text = groupAt(source, commands.lastIndex);
      if (text) commands.lastIndex = text.end;
      continue;
    }
    if (name === 'ce') {
      const group = groupAt(source, commands.lastIndex);
      if (group) {
        const chem = chemicalFormulaLatex(group.body);
        if (chem !== null) {
          result += source.slice(cursor, match.index) + chem;
          cursor = group.end;
          commands.lastIndex = group.end;
          continue;
        }
      }
    }
    if (!['SI', 'si', 'num'].includes(name)) continue;
    const first = groupAt(source, commands.lastIndex);
    if (!first) continue;
    const second = name === 'SI' ? groupAt(source, first.end) : null;
    const end = second?.end ?? first.end;
    const number = name === 'si' ? null : numberLatex(first.body);
    const unit =
      name === 'num' ? null : unitLatex(name === 'si' ? first.body : (second?.body ?? ''));
    const replacement =
      name === 'num'
        ? number
        : name === 'si'
          ? unit
          : number !== null && unit !== null
            ? `${number}\\,${unit}`
            : null;
    result += source.slice(cursor, match.index) + (replacement ?? source.slice(match.index, end));
    cursor = end;
    commands.lastIndex = end;
  }
  return result + source.slice(cursor);
}
