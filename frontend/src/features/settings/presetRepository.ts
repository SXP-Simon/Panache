import * as v from 'valibot';
import { readRecord, writeRecord } from '@/persistence';
import { collapseInlineImages } from '@/utils/inlineImageManager';
import type { DocumentData } from '@/features/document/store';
import type { SettingsData } from './store';
import { parseConfiguration, serializeConfiguration } from './configuration';
import { migrateLegacySettings } from './legacy';
import {
  assetSnapshotSchema,
  captureAssets,
  disableResourceCollection,
  releaseSnapshot,
  restoreAssets,
  setResourceRecord,
} from '@/persistence/assetSnapshots';

const presetSchema = v.object({
  version: v.literal(2),
  configuration: v.string(),
  text: v.string(),
  assets: assetSnapshotSchema,
});
export interface RestoredPreset {
  settings: SettingsData;
  document: DocumentData | null;
  replaceBackground: boolean;
}
let saves: Promise<void> = Promise.resolve();
export async function registerPresetResources(): Promise<void> {
  try {
    const raw = await readRecord('studio.preset');
    if (!raw) {
      setResourceRecord('preset', null);
      return;
    }
    const decoded: unknown = JSON.parse(raw);
    const modern = v.safeParse(presetSchema, decoded);
    if (modern.success) setResourceRecord('preset', modern.output.assets);
    else {
      const legacy = v.parse(v.record(v.string(), v.unknown()), decoded);
      if ('version' in legacy || 'assets' in legacy) throw new Error('Unknown preset format');
      setResourceRecord('preset', null);
    }
  } catch {
    disableResourceCollection();
  }
}
export function savePreset(document: DocumentData, settings: SettingsData): Promise<void> {
  const save = saves
    .catch(() => {})
    .then(async () => {
      const assets = await captureAssets(document, settings);
      let committed = false;
      try {
        await writeRecord(
          'studio.preset',
          JSON.stringify({
            version: 2,
            configuration: JSON.stringify(serializeConfiguration(settings, document.textFileName)),
            text: document.text,
            assets,
          }),
        );
        committed = true;
      } catch (cause) {
        disableResourceCollection();
        throw cause;
      } finally {
        releaseSnapshot(assets, committed ? 'preset' : undefined);
      }
    });
  saves = save;
  return save;
}
export async function loadPreset(
  previous: SettingsData,
  fonts: readonly string[],
): Promise<RestoredPreset | null> {
  try {
    return await restorePreset(previous, fonts);
  } catch (cause) {
    disableResourceCollection();
    throw cause;
  }
}
async function restorePreset(
  previous: SettingsData,
  fonts: readonly string[],
): Promise<RestoredPreset | null> {
  await saves.catch(() => {});
  const raw = await readRecord('studio.preset');
  if (!raw) return null;
  const decoded: unknown = JSON.parse(raw);
  const modern = v.safeParse(presetSchema, decoded);
  const legacyShape = v.safeParse(v.record(v.string(), v.unknown()), decoded);
  if (
    !modern.success &&
    legacyShape.success &&
    ('version' in legacyShape.output || 'assets' in legacyShape.output)
  )
    throw new Error('Invalid saved preset');
  const legacy =
    legacyShape.success &&
    ('fontSize' in legacyShape.output || 'selectedOption' in legacyShape.output);
  const configuration = parseConfiguration(
    modern.success ? modern.output.configuration : legacy ? migrateLegacySettings(raw, fonts) : raw,
    previous,
  );
  let document: DocumentData | null = null;
  if (modern.success) {
    const restored = await restoreAssets(modern.output.assets);
    configuration.settings.background = restored.background;
    configuration.settings.backgroundUrl = '';
    configuration.settings.fontFile = restored.fontFile;
    document = {
      text: modern.output.text,
      imageStore: restored.imageStore,
      textFileName: configuration.textFileName ?? '',
    };
    setResourceRecord('preset', modern.output.assets);
  } else if (configuration.text !== undefined) {
    const draft = collapseInlineImages(configuration.text);
    document = {
      text: draft.collapsedText,
      imageStore: draft.imageStore,
      textFileName: configuration.textFileName ?? '',
    };
  }
  if (
    fonts.length &&
    !configuration.settings.fontFile &&
    !fonts.includes(configuration.settings.selectedFont)
  )
    configuration.settings.selectedFont = fonts[0] ?? '';
  return { settings: configuration.settings, document, replaceBackground: modern.success };
}
