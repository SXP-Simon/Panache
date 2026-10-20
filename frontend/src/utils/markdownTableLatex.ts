import { scanMathSegments } from './mathSegments.ts';

function cellsOf(line: string): string[] | null {
  const spans = new Map(scanMathSegments(line).map((span) => [span.start, span]));
  const cells: string[] = [];
  let cell = '';
  for (let index = 0; index < line.length; index++) {
    const span = spans.get(index);
    if (span) {
      cell += line.slice(index, span.end);
      index = span.end - 1;
    } else if (line[index] === '\\' && line[index + 1] === '|') {
      cell += '\\|';
      index++;
    } else if (line[index] === '|') {
      cells.push(cell.trim());
      cell = '';
    } else cell += line[index];
  }
  if (!cells.length) return null;
  cells.push(cell.trim());
  if (line.trimStart().startsWith('|')) cells.shift();
  if (line.trimEnd().endsWith('|') && cells.at(-1) === '') cells.pop();
  return cells;
}

function textArgument(text: string): string {
  const special: Record<string, string> = {
    '\\': '\\textbackslash{}',
    '^': '\\textasciicircum{}',
    '~': '\\textasciitilde{}',
    '&': '\\&',
    '%': '\\%',
    $: '\\$',
    '#': '\\#',
    _: '\\_',
    '{': '\\{',
    '}': '\\}',
  };
  return text ? `\\text{${Array.from(text, (char) => special[char] ?? char).join('')}}` : '';
}

function unescapeMarkdown(text: string): string {
  let result = '';
  const punctuation = new Set(Array.from('\\`*_{}[]()#+-.!|>'));
  for (let index = 0; index < text.length; index++) {
    if (text[index] === '\\' && punctuation.has(text[index + 1] ?? '')) index++;
    result += text[index] ?? '';
  }
  return result;
}

function latexCell(source: string, cleanText: (text: string) => string): string | null {
  const clean = (value: string): string => {
    const content = unescapeMarkdown(cleanText(value));
    return content
      ? `${/^\s/.test(value) ? ' ' : ''}${content}${/\s$/.test(value) ? ' ' : ''}`
      : value.trim()
        ? ''
        : value
          ? ' '
          : '';
  };
  let result = '';
  let cursor = 0;
  for (const span of scanMathSegments(source)) {
    result += textArgument(clean(source.slice(cursor, span.start)));
    const raw = source.slice(span.start, span.end);
    if (span.kind === 'math') result += span.body;
    else if (span.safeMathLiteral) return null;
    else if (raw.startsWith('`')) {
      const fence = /^`+/.exec(raw)?.[0] ?? '';
      if (!fence || !raw.endsWith(fence) || raw.length < fence.length * 2) return null;
      result += textArgument(raw.slice(fence.length, -fence.length));
    } else result += textArgument(clean(raw));
    cursor = span.end;
  }
  return result + textArgument(clean(source.slice(cursor)));
}

/** Convert genuine Markdown tables before cleanup removes code/math boundaries. */
export function markdownTablesToLatex(source: string, cleanText: (text: string) => string): string {
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  const output: string[] = [];
  let fence: string | null = null;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index] ?? '';
    const fenceMatch = /^\s*(`{3,}|~{3,})/.exec(line)?.[1];
    if (fenceMatch) {
      if (!fence) fence = fenceMatch;
      else if (fenceMatch[0] === fence[0] && fenceMatch.length >= fence.length) fence = null;
      output.push(line);
      continue;
    }
    if (fence) {
      output.push(line);
      continue;
    }
    const header = cellsOf(line);
    const separator = cellsOf(lines[index + 1] ?? '');
    if (!header || !separator || !separator.every((cell) => /^:?-{3,}:?$/.test(cell))) {
      output.push(line);
      continue;
    }
    let end = index + 2;
    const rows = [header];
    while (end < lines.length) {
      const cells = cellsOf(lines[end] ?? '');
      if (!cells) break;
      rows.push(cells);
      end++;
    }
    const original = lines.slice(index, end);
    let valid =
      rows.length >= 2 &&
      rows.length <= 32 &&
      header.length >= 1 &&
      header.length <= 32 &&
      separator.length === header.length &&
      rows.every((row) => row.length <= header.length);
    const converted: string[] = [];
    if (valid) {
      for (const row of rows) {
        const cells: string[] = [];
        for (let column = 0; column < header.length; column++) {
          const value = latexCell(row[column] ?? '', cleanText);
          if (value === null) {
            valid = false;
            break;
          }
          cells.push(value);
        }
        converted.push(`${cells.join(' & ')} \\\\ \\hline`);
      }
    }
    const latex = [
      '\\[',
      `\\begin{array}{|${'c|'.repeat(header.length)}}`,
      '\\hline',
      ...converted,
      '\\end{array}',
      '\\]',
    ].join('\n');
    output.push(...(valid && latex.length <= 16000 ? [latex] : original));
    index = end - 1;
  }
  return output.join('\n');
}
