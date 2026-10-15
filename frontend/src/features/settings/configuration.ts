import * as v from 'valibot';
import { allFields, validNumber, validPaper } from '@/models';
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
  for (const field of allFields) {
    const value = parsed[field.key];
    if (value !== undefined) {
      if (
        typeof value !== 'number' ||
        !Number.isFinite(value) ||
        (mode === 'preset' && !validNumber(field.key, value))
      )
        throw new Error('Invalid numeric configuration');
      settings.numbers[field.key] = value;
    }
  }
  if (mode === 'preset' && !validPaper(settings.numbers))
    throw new Error('Invalid paper configuration');
  if (typeof parsed['font'] === 'string') settings.selectedFont = parsed['font'];
  if (typeof parsed['underlined'] === 'boolean') settings.underlined = parsed['underlined'];
  if (typeof parsed['englishSpacing'] === 'boolean')
    settings.englishSpacing = parsed['englishSpacing'];
  if (typeof parsed['fullPreview'] === 'boolean') settings.fullPreview = parsed['fullPreview'];
  if (typeof parsed['ink'] === 'string' && /^#[\da-f]{6}$/i.test(parsed['ink']))
    settings.ink = parsed['ink'];
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
    underlined: settings.underlined,
    englishSpacing: settings.englishSpacing,
    ink: settings.ink,
    fullPreview: settings.fullPreview,
    textFileName,
  };
}
