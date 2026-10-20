/** Keep the changelog readable; installer guidance belongs on the release page. */
export function summarizeReleaseNotes(notes: string): string[] {
  const changes: string[] = [];
  let inCode = false;
  let guidance = false;
  const source = notes.slice(0, 50000).split(/<!--\s*download-guide\s*-->/i)[0] ?? '';
  for (const line of source.split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) {
      inCode = !inCode;
      continue;
    }
    if (inCode) continue;
    const heading = /^\s*#{1,6}\s+(.+)$/.exec(line)?.[1];
    if (heading) {
      guidance = /下载|安装|校验|构建|源码|download|install|checksum|assets|source code/i.test(
        heading,
      );
      continue;
    }
    if (guidance) continue;
    let text = /^\s*[-*+]\s+(.+)$/.exec(line)?.[1];
    if (!text) continue;
    if (
      /^(?:\*\*)?(?:scripts|ci|docs|tests?|build|\.github)(?:[/\w.-]*)(?:\*\*)?[:：]/i.test(text) ||
      /^(?:chore|docs|test|ci|build)(?:\([^)]+\))?:/i.test(text)
    )
      continue;
    text = text
      .replace(/\(?\[([a-f\d]{7,40})\]\(https:\/\/github\.com\/[^)]+\)\)?/gi, '')
      .replace(/\(([a-f\d]{7,40})\)/gi, '')
      .replace(/^\*\*[^*\n]{1,100}[:：]\*\*\s*/, '')
      .replace(/^\*\*[^*\n]{1,100}\*\*[:：]\s*/, '')
      .replace(/^(?:feat|fix|refactor|perf)(?:\([^)]+\))?:\s*/i, '')
      .replace(/^(?:fe|be|frontend|backend|desktop|app|crates|lib)(?:[/\w.-]*)[:：]\s*/i, '')
      .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      .replace(/[*`]/g, '')
      .replace(/<[^>]*>/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    if (!text || changes.includes(text)) continue;
    changes.push(text.length > 160 ? `${text.slice(0, 159)}…` : text);
    if (changes.length === 6) break;
  }
  return changes;
}
