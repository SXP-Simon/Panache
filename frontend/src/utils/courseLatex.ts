import { normalizePhysicsLatex } from './physicsLatex.ts';

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

// A bounded mhchem subset: unfamiliar syntax is preserved as a whole formula.
// Counts and charges are separate: NH4+ is NH₄⁺, Fe^3+ is Fe³⁺.
function chemicalSpecies(source: string): string | null {
  let value = source.trim(),
    suffix = '';
  const gas = /\s+([v^])$/.exec(value);
  if (gas) {
    suffix = gas[1] === 'v' ? '\\downarrow' : '\\uparrow';
    value = value.slice(0, gas.index).trim();
  }
  const state = /\((aq|s|l|g)\)$/.exec(value);
  if (state) {
    suffix = `\\mathrm{${state[0]}}${suffix}`;
    value = value.slice(0, state.index);
  }
  let charge = '';
  const ion = /(?:\^(?:\{(\d{0,3}[+-])\}|(\d{0,3}[+-]))|([+-]))$/.exec(value);
  if (ion) {
    charge = `^{${ion[1] ?? ion[2] ?? ion[3]}}`;
    value = value.slice(0, ion.index);
  }
  const coefficient = /^(\d+\/\d+|\d+(?:\.\d+)?)\s*/.exec(value);
  let result = coefficient?.[1] ?? '';
  if (result.includes('/')) {
    const [top, bottom] = result.split('/');
    if (Number(bottom) === 0) return null;
    result = `\\frac{${top}}{${bottom}}\\,`;
  }
  if (coefficient) value = value.slice(coefficient[0].length);
  const stack: string[] = [];
  let atoms = 0,
    previous = false;
  for (let cursor = 0; cursor < value.length;) {
    const rest = value.slice(cursor);
    const element = /^(?:[A-Z][a-z]?|e)/.exec(rest);
    if (element) {
      result += element[0];
      atoms++;
      previous = true;
      cursor += element[0].length;
      continue;
    }
    const count = /^\d+/.exec(rest);
    if (count && previous) {
      if (count[0].length > 3) return null;
      result += `_{${count[0]}}`;
      previous = true;
      cursor += count[0].length;
      continue;
    }
    const char = value[cursor] ?? '';
    if (char === '(' || char === '[') {
      if (stack.length >= 8) return null;
      stack.push(char);
      result += char;
      previous = false;
    } else if (char === ')' || char === ']') {
      if (!previous || stack.pop() !== (char === ')' ? '(' : '[')) return null;
      result += char;
      previous = true;
    } else return null;
    cursor++;
  }
  if (!atoms || stack.length) return null;
  return `\\mathrm{${result}${charge}}${suffix}`;
}

function chemicalFormulaLatex(source: string): string | null {
  if (source.length > 4096 || !source.trim()) return null;
  const arrows: Record<string, string> = {
    '->': '\\rightarrow',
    '<-': '\\leftarrow',
    '<->': '\\leftrightarrow',
    '<=>': '\\rightleftharpoons',
  };
  const parts = source
    .trim()
    .split(/\s*(<=>|<->|->|<-)\s*|\s+(\+)\s+/)
    .filter((part) => part !== undefined && part !== '');
  if (parts.length > 127 || parts.length % 2 !== 1) return null;
  const result: string[] = [];
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index] ?? '';
    if (index % 2 === 1) {
      const op = part === '+' ? '+' : arrows[part];
      if (!op) return null;
      result.push(op);
    } else {
      const hydrate = part.split(/\s*[*.·]\s*/);
      // A decimal stoichiometric coefficient is not a hydrate separator.
      const pieces = /^\d+\.\d+\s*[A-Z]/.test(part) ? [part] : hydrate;
      const converted = pieces.map(chemicalSpecies);
      if (converted.some((piece) => piece === null)) return null;
      result.push(converted.join('\\cdot '));
    }
  }
  return result.join(' ');
}

export function normalizeCourseLatex(source: string): string {
  source = normalizePhysicsLatex(source);
  const commands = /\\([a-zA-Z]+|[^a-zA-Z])/g;
  let result = '',
    cursor = 0;
  for (let match = commands.exec(source); match; match = commands.exec(source)) {
    const rawName = match[1] ?? '';
    const name = rawName === 'qty' ? 'SI' : rawName === 'unit' ? 'si' : rawName;
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
        result +=
          source.slice(cursor, match.index) + (chem ?? source.slice(match.index, group.end));
        cursor = group.end;
        commands.lastIndex = group.end;
        continue;
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
