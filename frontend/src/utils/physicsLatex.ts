// Bounded physics-package aliases. Semantics follow physics.pdf §2.1 / §2.5:
// https://mirrors.ctan.org/macros/latex/contrib/physics/physics.pdf
// Starred, long-form and mixed partial derivatives stay intact.
const MAX_SOURCE = 32768;
const MAX_GROUP = 4096;
const MAX_DEPTH = 16;
const VARIABLE =
  /^(?:[A-Za-zΑ-Ωα-ωϑϕϖϱϵϰ]|\\[A-Za-z]+)(?:_(?:[A-Za-z0-9]|\{(?:[A-Za-z0-9]{1,16}|\\[A-Za-z]+)\}))?$/;

function skipSpace(source: string, offset: number): number {
  while (offset < source.length && /\s/.test(source[offset] ?? '')) offset++;
  return offset;
}

function groupAt(source: string, offset: number): { body: string; end: number } | null {
  const start = skipSpace(source, offset);
  if (source[start] !== '{') return null;
  let depth = 1;
  for (let cursor = start + 1; cursor < source.length; cursor++) {
    if (cursor - start > MAX_GROUP) return null;
    if (source[cursor] === '\\') cursor++;
    else if (source[cursor] === '{') {
      if (++depth > MAX_DEPTH) return null;
    } else if (source[cursor] === '}' && --depth === 0) {
      return { body: source.slice(start + 1, cursor), end: cursor + 1 };
    }
  }
  return null;
}

function normalizeFragment(source: string, depth: number): string | null {
  if (depth > MAX_DEPTH) return null;
  const commands = /\\([A-Za-z]+|[^A-Za-z])/g;
  let result = '',
    cursor = 0;
  for (let match = commands.exec(source); match; match = commands.exec(source)) {
    const name = match[1] ?? '';
    if (['text', 'textrm', 'textbf', 'textit', 'texttt', 'operatorname', 'ce'].includes(name)) {
      const text = groupAt(source, commands.lastIndex);
      if (text) commands.lastIndex = text.end;
      continue;
    }
    if (!['dv', 'pdv', 'abs', 'norm'].includes(name)) continue;
    let offset = skipSpace(source, commands.lastIndex);
    let order = '';
    if ((name === 'dv' || name === 'pdv') && source[offset] === '[') {
      const option = /^\[([1-9]\d?|[A-Za-z])\]/.exec(source.slice(offset));
      if (!option) return null;
      order = option[1] ?? '';
      offset += option[0].length;
    }
    const first = groupAt(source, offset);
    if (!first || !first.body.trim()) return null;
    let replacement: string,
      end = first.end;
    if (name === 'abs' || name === 'norm') {
      const body = normalizeFragment(first.body, depth + 1);
      if (body === null) return null;
      const delimiter = name === 'abs' ? '|' : '\\Vert';
      replacement = `\\left${delimiter}{${body}}\\right${delimiter}`;
    } else {
      const second = groupAt(source, first.end);
      end = second?.end ?? first.end;
      const tail = source[skipSpace(source, end)];
      // Third braced argument means mixed partial; (...) is physics long form.
      if (tail === '{' || tail === '(' || tail === '[') return null;
      const variable = (second?.body ?? first.body).trim();
      if (!VARIABLE.test(variable)) return null;
      const body = second ? normalizeFragment(first.body, depth + 1) : '';
      if (body === null) return null;
      const differential = name === 'dv' ? '\\mathrm{d}' : '\\partial';
      const power = order && order !== '1' ? `^{${order}}` : '';
      replacement = `\\frac{${differential}${power}${body ? `{${body}}` : ''}}{${differential}{${variable}}${power}}`;
    }
    result += source.slice(cursor, match.index) + replacement;
    cursor = end;
    commands.lastIndex = end;
  }
  return result + source.slice(cursor);
}

export function normalizePhysicsLatex(source: string): string {
  if (source.length > MAX_SOURCE) return source;
  return normalizeFragment(source, 0) ?? source;
}
