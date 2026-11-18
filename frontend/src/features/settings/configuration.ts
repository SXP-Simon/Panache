import * as v from 'valibot';
import { allFields, sliderFields, isLatinFont, validNumber, validPaper } from '@/models';
import type { SettingsData } from './store';

const schema = v.record(v.string(), v.union([v.number(), v.string(), v.boolean()]));
export interface RestoredConfiguration {
  settings: SettingsData;
  text?: string;
  textFileName?: string;
}
export function parseConfiguration(
  raw: string,
  previous: SettingsData,
  mode: 'draft' | 'preset' = 'preset',
): RestoredConfiguration {
  const parsed = v.parse(schema, JSON.parse(raw));
  const settings = { ...previous, numbers: { ...previous.numbers } };
  settings.numbers.latin_font_scale = 100;
  settings.backgroundRuled = parsed['backgroundRuled'] === true;
  if (
    parsed['layoutStyle'] !== undefined &&
    !['standard', 'homework'].includes(String(parsed['layoutStyle']))
  )
    throw new Error('Invalid layout style');
  settings.layoutStyle = parsed['layoutStyle'] === 'homework' ? 'homework' : 'standard';
  settings.firstLineIndent = parsed['firstLineIndent'] === true;
  settings.monospaced = parsed['monospaced'] === true;
  for (const field of allFields) {
    const value = parsed[field.key];
    if (value !== undefined) {
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        ((mode === 'preset' || sliderFields.some((slider) => slider.key === field.key)) &&
          !validNumber(field.key, value))
      )
        throw new Error('Invalid numeric configuration');
      settings.numbers[field.key] = value;
    }
  }
  if (mode === 'preset' && !validPaper(settings.numbers))
    throw new Error('Invalid paper configuration');
  if (typeof parsed['font'] === 'string') settings.selectedFont = parsed['font'];
  const latin = parsed['latinFont'];
  settings.selectedLatinFont = isLatinFont(latin) ? latin : '';
  settings.digitFont = parsed['digitFont'] === 'latin' ? 'latin' : 'primary';
  settings.separateLatinInk = parsed['separateLatinInk'] === true;
  if (typeof parsed['underlined'] === 'boolean') settings.underlined = parsed['underlined'];
  const pattern = parsed['paperPattern'];
  settings.paperPattern = pattern === 'grid' || pattern === 'dots' ? pattern : '';
  if (typeof parsed['englishSpacing'] === 'boolean')
    settings.englishSpacing = parsed['englishSpacing'];
  if (typeof parsed['fullPreview'] === 'boolean') settings.fullPreview = parsed['fullPreview'];
  if (typeof parsed['ink'] === 'string' && /^#[\da-f]{6}$/i.test(parsed['ink']))
    settings.ink = parsed['ink'];
  if (typeof parsed['latinInk'] === 'string' && /^#[\da-f]{6}$/i.test(parsed['latinInk']))
    settings.latinInk = parsed['latinInk'];
  return {
    settings,
    ...(typeof parsed['text'] === 'string' ? { text: parsed['text'] } : {}),
    ...(typeof parsed['textFileName'] === 'string' ? { textFileName: parsed['textFileName'] } : {}),
  };
}
export function serializeConfiguration(settings: SettingsData, textFileName: string) {
  return {
    ...settings.numbers,
    font: settings.selectedFont,
    latinFont: settings.selectedLatinFont,
    digitFont: settings.digitFont,
    underlined: settings.underlined,
    paperPattern: settings.paperPattern,
    backgroundRuled: settings.backgroundRuled,
    layoutStyle: settings.layoutStyle,
    firstLineIndent: settings.firstLineIndent,
    monospaced: settings.monospaced,
    englishSpacing: settings.englishSpacing,
    ink: settings.ink,
    separateLatinInk: settings.separateLatinInk,
    latinInk: settings.latinInk,
    fullPreview: settings.fullPreview,
    textFileName,
  };
}
