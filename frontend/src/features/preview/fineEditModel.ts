import * as v from 'valibot';
import type { SettingsData } from '@/features/settings/store';
import type { NumericKey } from '@/models';

const integer = v.pipe(v.number(), v.integer());
const bounded = (min: number, max: number) =>
  v.pipe(v.number(), v.integer(), v.minValue(min), v.maxValue(max));
const color = v.pipe(v.string(), v.regex(/^#[0-9a-f]{6}$/i));
const key = v.pipe(v.string(), v.regex(/^[0-9a-f]{64}$/));
const glyph = v.tuple([
  bounded(0, Number.MAX_SAFE_INTEGER),
  integer,
  integer,
  bounded(1, 65535),
  bounded(1, 65535),
  bounded(0, 65535),
  bounded(0, 65535),
  integer,
]);
const page = v.object({
  atlas: v.string(),
  glyphs: v.array(glyph),
  source_ranges: v.optional(v.array(v.nullable(v.tuple([integer, integer])))),
});
export const finePreviewSchema = v.object({ key, pages: v.array(page) });
export const adjustmentSchema = v.object({
  id: bounded(0, Number.MAX_SAFE_INTEGER),
  dx: bounded(-65535, 65535),
  dy: bounded(-65535, 65535),
  scale: bounded(50, 200),
  angle: bounded(-45, 45),
  opacity: bounded(0, 100),
  color: v.nullable(color),
});
export const fineEditsSchema = v.object({
  text: v.string(),
  key,
  glyphs: v.pipe(v.array(adjustmentSchema), v.maxLength(10_000)),
});
export type FinePreview = v.InferOutput<typeof finePreviewSchema>;
export type FinePage = v.InferOutput<typeof page>;
export type Glyph = v.InferOutput<typeof glyph>;
export type Adjustment = v.InferOutput<typeof adjustmentSchema>;
export type FineEdits = v.InferOutput<typeof fineEditsSchema>;
export const defaultAdjustment = { dx: 0, dy: 0, scale: 100, angle: 0, opacity: 100, color: null };
export type Adjustments = ReadonlyMap<number, Adjustment>;

export function isDefault(adjustment: Adjustment) {
  return Object.entries(defaultAdjustment).every(
    ([key, value]) => adjustment[key as keyof typeof defaultAdjustment] === value,
  );
}

const layoutFields = [
  'selectedFont',
  'selectedLatinFont',
  'digitFont',
  'fontFile',
  'background',
  'backgroundRuled',
  'layoutStyle',
  'firstLineIndent',
  'monospaced',
  'underlined',
  'paperPattern',
  'englishSpacing',
] as const satisfies readonly (keyof SettingsData)[];

export function sameFineLayout(a: SettingsData, b: SettingsData) {
  return (
    layoutFields.every((field) => a[field] === b[field]) &&
    (Object.keys(a.numbers) as NumericKey[]).every(
      (field) =>
        /^(latin_)?ink_(opacity|thickness|softness)$/.test(field) ||
        a.numbers[field] === b.numbers[field],
    )
  );
}
