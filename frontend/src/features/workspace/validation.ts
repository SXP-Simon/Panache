import { allFields, validNumber } from '@/models';
import type { GenerationSnapshot } from '@/api/types';
import type { MessageKey } from '@/i18n';

export function validateGeneration(snapshot: GenerationSnapshot): MessageKey | null {
  const { numbers: n } = snapshot;
  if (!snapshot.text.trim()) return 'emptyText';
  if (n.font_size > n.line_spacing) return 'invalidSize';
  if (!allFields.every((field) => validNumber(field.key, n[field.key]))) return 'invalidNumber';
  if (!snapshot.background) {
    if (n.left_margin + n.right_margin + n.font_size > n.width) return 'invalidPaperWidth';
    if (n.top_margin + n.bottom_margin + n.line_spacing > n.height) return 'invalidPaper';
    if (n.width * n.height > 16_000_000) return 'invalidPaperArea';
  }
  if (n.word_spacing <= -n.font_size / 2) return 'invalidNumber';
  return null;
}
