/** Keep programming examples literal while removing their Markdown wrappers. */
export function protectMarkdownCode(source: string): {
  text: string;
  restore: (value: string) => string;
} {
  let prefix = '\ue110CODE';
  while (source.includes(prefix)) prefix += '\ue110';
  const values: string[] = [];
  const save = (value: string): string => {
    values.push(value);
    return `${prefix}${values.length - 1}\ue111`;
  };
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  const output: string[] = [];
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index] ?? '';
    const opening = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line);
    const fence = opening?.[2];
    if (!fence || (fence[0] === '`' && opening?.[3]?.includes('`'))) {
      output.push(line);
      continue;
    }
    const indent = opening?.[1]?.length ?? 0;
    const body: string[] = [];
    for (index++; index < lines.length; index++) {
      const current = lines[index] ?? '';
      const closing = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(current)?.[1];
      if (closing && closing[0] === fence[0] && closing.length >= fence.length) break;
      const leading = /^ */.exec(current)?.[0].length ?? 0;
      body.push(current.slice(Math.min(indent, leading)));
    }
    output.push(save(body.join('\n')));
  }
  // Exact backtick run lengths allow ` characters inside a longer code span.
  const joined = output.join('\n');
  let text = '';
  let cursor = 0;
  const runs = Array.from(joined.matchAll(/`+/g));
  const next = new Map<number, number>();
  const following = new Map<number, number>();
  for (let index = runs.length - 1; index >= 0; index--) {
    const run = runs[index];
    if (!run) continue;
    const candidate = following.get(run[0].length);
    if (candidate !== undefined) next.set(index, candidate);
    following.set(run[0].length, index);
  }
  for (let index = 0; index < runs.length; index++) {
    const run = runs[index];
    const closeIndex = next.get(index);
    if (!run || closeIndex === undefined) continue;
    let backslashes = 0;
    for (let before = run.index - 1; before >= 0 && joined[before] === '\\'; before--)
      backslashes++;
    if (backslashes % 2) continue;
    const close = runs[closeIndex];
    if (!close) continue;
    let value = joined.slice(run.index + run[0].length, close.index).replace(/\n/g, ' ');
    if (value.startsWith(' ') && value.endsWith(' ') && /[^ ]/.test(value))
      value = value.slice(1, -1);
    text += joined.slice(cursor, run.index) + save(value);
    cursor = close.index + close[0].length;
    index = closeIndex;
  }
  text += joined.slice(cursor);
  return {
    text,
    restore: (value) =>
      value.replace(
        new RegExp(`${prefix}(\\d+)\ue111`, 'g'),
        (raw: string, index: string) => values[Number(index)] ?? raw,
      ),
  };
}

/** Balanced destinations are common in references to engineering documentation. */
export function stripMarkdownLinks(source: string): string {
  const closes = new Map<number, number>();
  const stack: number[] = [];
  for (let index = 0; index < source.length; index++) {
    if (source[index] === '\\' && source[index + 1] !== '\n') index++;
    else if (source[index] === '\n') stack.length = 0;
    else if (source[index] === '(') stack.push(index);
    else if (source[index] === ')') {
      const start = stack.pop();
      if (start !== undefined) closes.set(start, index + 1);
    }
  }
  let output = '';
  let cursor = 0;
  const opening = /!?\[([^\][\n]*)\]\(/g;
  for (let match = opening.exec(source); match; match = opening.exec(source)) {
    const end = closes.get(opening.lastIndex - 1);
    if (end === undefined) continue;
    output += source.slice(cursor, match.index) + (match[1] ?? '');
    cursor = end;
    opening.lastIndex = end;
  }
  return output + source.slice(cursor);
}
