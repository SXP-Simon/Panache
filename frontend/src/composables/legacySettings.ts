import * as v from 'valibot';
import { allFields } from '../models';
import type { NumericKey } from '../models';
const aliases: Readonly<Partial<Record<NumericKey, string>>> = {
  font_size: 'fontSize',
  line_spacing: 'lineSpacing',
  word_spacing: 'wordSpacing',
  top_margin: 'marginTop',
  bottom_margin: 'marginBottom',
  left_margin: 'marginLeft',
  right_margin: 'marginRight',
  line_spacing_sigma: 'lineSpacingSigma',
  font_size_sigma: 'fontSizeSigma',
  word_spacing_sigma: 'wordSpacingSigma',
  perturb_x_sigma: 'perturbXSigma',
  perturb_y_sigma: 'perturbYSigma',
  perturb_theta_sigma: 'perturbThetaSigma',
};
const legacyKeys = [
  ...allFields.map((field) => aliases[field.key] ?? field.key),
  'isUnderlined',
  'enableEnglishSpacing',
  'enableFullPreview',
  'selectedOption',
  'fill',
  'text',
  'selectedTextFileName',
];
export function readLegacySettings(): string | null {
  const values: Record<string, string | number | boolean> = {};
  for (const key of legacyKeys) {
    try {
      const raw = localStorage.getItem(key);
      if (raw === null) continue;
      const value: unknown = JSON.parse(raw);
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean')
        values[key] = value;
    } catch {
      /* A damaged legacy field does not prevent reading the remaining fields. */
    }
  }
  return Object.keys(values).length ? JSON.stringify(values) : null;
}
export function migrateLegacySettings(raw: string, fonts: readonly string[]): string {
  const legacy = v.parse(v.record(v.string(), v.unknown()), JSON.parse(raw));
  const values: Record<string, string | number | boolean> = {};
  for (const field of allFields) {
    const value = legacy[aliases[field.key] ?? field.key];
    if (typeof value === 'number') values[field.key] = value;
    else if (typeof value === 'string' && value.trim()) values[field.key] = Number(value);
  }
  for (const [oldKey, key] of [
    ['isUnderlined', 'underlined'],
    ['enableEnglishSpacing', 'englishSpacing'],
    ['enableFullPreview', 'fullPreview'],
    ['text', 'text'],
    ['selectedTextFileName', 'textFileName'],
  ]) {
    if (!oldKey || !key) continue;
    const value = legacy[oldKey];
    if (typeof value === 'string' || typeof value === 'boolean') values[key] = value;
  }
  const selected = legacy['selectedOption'];
  const index =
    typeof selected === 'number' || typeof selected === 'string' ? Number(selected) - 1 : -1;
  const font = Number.isInteger(index) ? fonts[index] : undefined;
  if (font) values['font'] = font;
  const fill = legacy['fill'];
  if (typeof fill === 'string') {
    const channels = fill
      .match(/^\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/)
      ?.slice(1)
      .map(Number);
    if (channels?.length === 3 && channels.every((channel) => channel >= 0 && channel <= 255))
      values['ink'] =
        `#${channels.map((channel) => channel.toString(16).padStart(2, '0')).join('')}`;
  }
  return JSON.stringify(values);
}
