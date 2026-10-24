import { cleanMarkdown, type TableMode } from './cleanMarkdown.ts';
import { convertLatexToUnicode } from './latexToUnicode.ts';

/** Clean markup before converting formulas, without interpreting literal code. */
export function prepareHandwritingText(source: string, tableMode: TableMode = 'latex'): string {
  return cleanMarkdown(source, { tableMode, transformMath: convertLatexToUnicode });
}
