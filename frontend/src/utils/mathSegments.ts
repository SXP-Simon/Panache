export interface MathSegment {
  start: number;
  end: number;
  kind: 'literal' | 'math';
  body: string;
  display: boolean;
  safeMathLiteral?: boolean;
}
// 2026-10-15：共享公式边界扫描；只标记明确范围，正文交给调用方处理。
const MAX_MATH_LENGTH = 32768;
const MAX_ENV_DEPTH = 64;

interface ScanOptions {
  // Markdown 清洗需要保护裸分组；转写仍由裸公式转换器消费分组后的上下标。
  includeBareSizedGroups?: boolean;
}

export function sizedGroupEnd(text: string, start: number): number | null {
  const commands = /\\(left|right)(?![a-zA-Z])\s*(\\[a-zA-Z]+|\\.|[()[\]{}.|])/g;
  commands.lastIndex = start;
  let depth = 0;
  for (let token = commands.exec(text); token; token = commands.exec(text)) {
    if (depth === 0 && token.index !== start) return null;
    depth += token[1] === 'left' ? 1 : -1;
    if (depth === 0) return commands.lastIndex;
  }
  return null;
}

function escapedAt(text: string, index: number) {
  let count = 0;
  while (index > 0 && text[--index] === '\\') count++;
  return count % 2 === 1;
}

function environmentAt(text: string, index: number) {
  const match = /^\\(begin|end)\{([a-zA-Z][a-zA-Z0-9*]*)\}/.exec(text.slice(index, index + 100));
  return match && { command: match[1], name: match[2], length: match[0].length };
}

function withinMathBudget(body: string) {
  if (body.length > MAX_MATH_LENGTH) return false;
  let braces = 0;
  let environments = 0;
  for (let index = 0; index < body.length; index++) {
    const char = body[index];
    if (char === '\\') {
      const tag = environmentAt(body, index);
      if (tag) {
        environments += tag.command === 'begin' ? 1 : -1;
        if (environments > MAX_ENV_DEPTH) return false;
        index += tag.length - 1;
      } else {
        // 转义花括号不参与结构深度；\\ 本身也不能引入环境。
        index++;
      }
    } else if (char === '{') {
      if (++braces > MAX_ENV_DEPTH) return false;
    } else if (char === '}') braces--;
  }
  return true;
}

function scanEnvironment(text: string, start: number) {
  const first = environmentAt(text, start);
  if (!first) return { end: start, valid: false };
  const stack = [first.name];
  let tooLarge = false;
  let cursor = start + first.length;
  while (cursor < text.length) {
    if (cursor - start > MAX_MATH_LENGTH) tooLarge = true;
    if (text.startsWith('\\\\', cursor)) {
      cursor += 2;
      continue;
    }
    if (text[cursor] !== '\\' || escapedAt(text, cursor)) {
      cursor++;
      continue;
    }
    const tag = environmentAt(text, cursor);
    if (!tag) {
      cursor++;
      continue;
    }
    cursor += tag.length;
    if (tag.command === 'begin') {
      stack.push(tag.name);
      // 超出深度时不继续分配栈，剩余原文作为字面内容保留。
      if (stack.length > MAX_ENV_DEPTH) return { end: text.length, valid: false };
    } else {
      if (stack.pop() !== tag.name) return { end: text.length, valid: false };
      if (!stack.length) return { end: cursor, valid: !tooLarge };
    }
  }
  return { end: text.length, valid: false };
}

function scanDelimited(text: string, start: number, opener: string, closer: string) {
  const bodyStart = start + opener.length;
  let cursor = bodyStart;
  while (cursor < text.length) {
    if (opener === '$' && (text[cursor] === '\n' || text[cursor] === '\r')) break;
    if (text.startsWith(closer, cursor) && !escapedAt(text, cursor)) {
      // 不把 $$ 的一半识别成单美元闭合符。
      if (closer === '$' && (text[cursor - 1] === '$' || text[cursor + 1] === '$')) {
        cursor++;
        continue;
      }
      const body = text.slice(bodyStart, cursor);
      const nextIsAmount = /\d/.test(text[cursor + 1] || '');
      const currency =
        opener === '$' &&
        ((/^\d[\d,.]*(?:[ \t]+[a-zA-Z]+)*[ \t]*$/.test(body) &&
          (nextIsAmount || /\s$/.test(body))) ||
          (nextIsAmount && /^\d[\d,. \t+\-*/%×÷]*$/.test(body)) ||
          /^\d[\d,.]*[;:!?][ \t]*$/.test(body));
      if (currency) return null;
      return { end: cursor + closer.length, body, valid: withinMathBudget(body), closed: true };
    }
    cursor++;
  }
  return { end: cursor, body: text.slice(bodyStart, cursor), valid: false, closed: false };
}

/**
 * 返回不重叠的明确公式和受保护字面片段；其余间隙是普通正文。
 * start/end 为 UTF-16 索引（end 不包含在范围内）。公式定界符不在 body 内；
 * 独立环境的 body 包含完整 begin/end，便于直接交给公式解析器。
 * 代码、URL、路径、图片以及未闭合/超限公式的 kind 为 literal。
 * 未闭合/超限公式另有 safeMathLiteral: true，Markdown 清洗也应保留其源码。
 */
export function scanMathSegments(text: string, options: ScanOptions = {}): MathSegment[] {
  if (typeof text !== 'string' || !text) return [];
  const segments: MathSegment[] = [];
  const add = (
    start: number,
    end: number,
    kind: MathSegment['kind'] = 'literal',
    body = text.slice(start, end),
    display = false,
    safeMathLiteral = false,
  ) => {
    const segment: MathSegment = { start, end, kind, body, display };
    if (safeMathLiteral) segment.safeMathLiteral = true;
    segments.push(segment);
    return end;
  };
  let cursor = 0;
  while (cursor < text.length) {
    const start = cursor;
    const char = text[cursor];

    // 代码围栏和行内代码优先；其中的美元、宏与环境均不转换。
    if (char === '`' || (char === '~' && text.startsWith('~~~', cursor))) {
      let count = 1;
      while (text[cursor + count] === char) count++;
      if (char === '`' || count >= 3) {
        const fence = char.repeat(count);
        let end = text.indexOf(fence, cursor + count);
        while (end >= 0 && (text[end - 1] === char || text[end + count] === char))
          end = text.indexOf(fence, end + count);
        cursor = add(
          start,
          end < 0
            ? count >= 3
              ? text.length
              : text.indexOf('\n', cursor) < 0
                ? text.length
                : text.indexOf('\n', cursor)
            : end + count,
        );
        continue;
      }
    }

    // 常见网络地址、Windows/UNC 路径和 Markdown 图片作为整体保留。
    if (
      (char === 'h' || char === 'f') &&
      /^(?:https?|ftp|file):\/\//.test(text.slice(cursor, cursor + 9))
    ) {
      let end = cursor;
      while (end < text.length && !/[\s<>]/.test(text[end] ?? '')) end++;
      cursor = add(start, end);
      continue;
    }
    const pathBoundary = cursor === 0 || /[\s"'(]/.test(text[cursor - 1] ?? '');
    const pathStart =
      /^[a-zA-Z]:[\\/]/.test(text.slice(cursor, cursor + 3)) ||
      /^\\\\[^\s\\/]+[\\/][^\s]/.test(text.slice(cursor)) ||
      (pathBoundary && /^(?:\/[^\s/]+\/|\.{1,2}\/)[^\s]/.test(text.slice(cursor))) ||
      // 常见未加 ./ 的相对路径；至少两字目录名或明确扩展名，避免吞掉 a/b。
      (pathBoundary &&
        /^(?:[\p{L}\p{N}_.-]{2,}[\\/]|[\p{L}\p{N}_.-]+[\\/][^\s<>"']*\.[a-zA-Z0-9]{1,10}(?=$|[\s.,;:)]))/u.test(
          text.slice(cursor),
        ));
    if (pathStart) {
      let end = cursor;
      while (end < text.length && !/[\s<>"']/.test(text[end] ?? '')) end++;
      cursor = add(start, end);
      continue;
    }
    if (text.startsWith('![', cursor)) {
      let end = cursor + 2;
      while (end < text.length && (text[end] !== ']' || escapedAt(text, end))) end++;
      if (end < text.length) {
        end++;
        if (text[end] === '(') {
          let depth = 1;
          for (end++; end < text.length && depth; end++) {
            if ((text[end] === '(' || text[end] === ')') && escapedAt(text, end)) continue;
            if (text[end] === '(') depth++;
            if (text[end] === ')') depth--;
          }
        }
        cursor = add(start, end);
        continue;
      }
    }

    // 成对反斜杠不是定界符；成对跳过也避免长反斜杠串的二次回溯。
    if (text.startsWith('\\\\', cursor)) {
      cursor += 2;
      continue;
    }
    if ((char === '\\' || char === '$') && !escapedAt(text, cursor)) {
      if (char === '\\') {
        if (options.includeBareSizedGroups && /^\\left(?![a-zA-Z])/.test(text.slice(cursor))) {
          const end = sizedGroupEnd(text, cursor);
          if (end !== null) {
            cursor = add(start, end, 'math');
            continue;
          }
        }
        const env = environmentAt(text, cursor);
        if (env && env.command === 'begin') {
          const found = scanEnvironment(text, cursor);
          const body = text.slice(start, found.end);
          const valid = found.valid && withinMathBudget(body);
          cursor = add(start, found.end, valid ? 'math' : 'literal', body, true, !valid);
          continue;
        }
      }
      let opener;
      let closer = '';
      let display = false;
      if (text.startsWith('$$', cursor)) {
        opener = closer = '$$';
        display = true;
      } else if (char === '$') opener = closer = '$';
      else if (text.startsWith('\\[', cursor)) {
        opener = '\\[';
        closer = '\\]';
        display = true;
      } else if (text.startsWith('\\(', cursor)) {
        opener = '\\(';
        closer = '\\)';
      }
      if (opener) {
        const found = scanDelimited(text, cursor, opener, closer);
        const amount = opener === '$' ? /^\$\d[\d,.]*/.exec(text.slice(cursor)) : null;
        const amountBoundary =
          amount && !/[a-zA-Z+\-*/^_={\\<>]/.test(text[cursor + amount[0].length] || '');
        if (amountBoundary && (!found || !found.closed)) {
          cursor = add(start, cursor + amount[0].length);
          continue;
        }
        if (found) {
          cursor = add(
            start,
            found.end,
            found.valid ? 'math' : 'literal',
            found.body,
            display,
            !found.valid,
          );
          continue;
        }
        // 成对美元疑似货币时，仅保护当前金额，继续扫描后面的正文。
        cursor = add(start, cursor + (amount ? amount[0].length : 1));
        continue;
      }
    }
    cursor++;
  }
  return segments;
}

/** 对数学/字面片段调用回调，普通正文原样保留；回调无返回值时保留源码。 */
export function mapMathSegments(
  text: string,
  callback: (source: string, segment: MathSegment) => string | undefined = (source) => source,
  options: ScanOptions = {},
) {
  if (typeof text !== 'string') return '';
  let cursor = 0;
  let result = '';
  for (const segment of scanMathSegments(text, options)) {
    const source = text.slice(segment.start, segment.end);
    const replacement = callback(source, segment);
    result +=
      text.slice(cursor, segment.start) + (typeof replacement === 'string' ? replacement : source);
    cursor = segment.end;
  }
  return result + text.slice(cursor);
}
