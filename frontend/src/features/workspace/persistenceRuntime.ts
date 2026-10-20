import * as v from 'valibot';
import { DEFAULT_THEME_COLOR } from '@/features/preferences/themeColors';
import { readRecord, writeRecord } from '@/persistence';
import type { RecordKey } from '@/persistence';
import { useDocumentStore } from '@/features/document/store';
import { useSettingsStore } from '@/features/settings/store';
import { usePreferencesStore } from '@/features/preferences/store';
import { useNotificationStore } from '@/features/notifications/store';
import { changeBackground } from '@/features/preview/resources';
import { parseConfiguration, serializeConfiguration } from '@/features/settings/configuration';
import { migrateLegacySettings } from '@/features/settings/legacy';
import { registerPresetResources } from '@/features/settings/presetRepository';
import { collapseInlineImages } from '@/utils/inlineImageManager';
import {
  assetSnapshotSchema,
  captureAssets,
  disableResourceCollection,
  releaseSnapshot,
  preparedSnapshot,
  restoreAssets,
  setResourceRecord,
} from '@/persistence/assetSnapshots';
import type { AssetSnapshot } from '@/persistence/assetSnapshots';
import { useSaveStatus } from './saveStatus';

export const generationRecordSchema = v.object({
  version: v.literal(1),
  taskId: v.string(),
  mode: v.picklist(['preview', 'zip', 'pdf']),
});
export type GenerationRecord = v.InferOutput<typeof generationRecordSchema>;
const preferencesSchema = v.object({
  autoCheckUpdates: v.optional(v.boolean(), true),
  locale: v.picklist(['cn', 'en']),
  theme: v.picklist(['light', 'dark']),
  themeColor: v.optional(
    v.fallback(v.pipe(v.string(), v.regex(/^#[0-9a-fA-F]{6}$/)), DEFAULT_THEME_COLOR),
    DEFAULT_THEME_COLOR,
  ),
  tableMode: v.optional(v.picklist(['latex', 'list', 'aligned', 'raw_pipe', 'clean']), 'latex'),
});
const workspaceSchema = v.object({
  version: v.literal(2),
  text: v.string(),
  configuration: v.string(),
  assets: assetSnapshotSchema,
  preferences: preferencesSchema,
  legacyFontIndex: v.nullable(v.number()),
});
let restoredGeneration: GenerationRecord | null = null;
let legacyFontIndex: number | null = null;
let restoredAssets: AssetSnapshot | null = null;
let hydrationBlocked = false;
let lastCheckpoint: string | null = null;
let flushActive: (() => Promise<void>) | null = null;
export function flushWorkspaceNow(): Promise<void> {
  return flushActive?.() ?? Promise.resolve();
}

export function takeRestoredGeneration(): GenerationRecord | null {
  const result = restoredGeneration;
  restoredGeneration = null;
  return result;
}
export function reconcileFontSelection(fonts: readonly string[]): void {
  const settings = useSettingsStore.getState();
  let selectedFont = settings.selectedFont;
  if (legacyFontIndex !== null) {
    selectedFont = fonts[legacyFontIndex] ?? selectedFont;
    legacyFontIndex = null;
  }
  if (settings.fontFile?.name !== selectedFont && !fonts.includes(selectedFont))
    selectedFont = fonts[0] ?? '';
  if (selectedFont !== settings.selectedFont) settings.patch({ selectedFont });
}
async function hydrateCheckpoint(raw: string): Promise<void> {
  const checkpoint = v.parse(workspaceSchema, JSON.parse(raw));
  const configuration = parseConfiguration(
    checkpoint.configuration,
    useSettingsStore.getState(),
    'draft',
  );
  const assets = await restoreAssets(checkpoint.assets);
  const draft = collapseInlineImages(checkpoint.text, assets.imageStore);
  useDocumentStore.getState().replace({
    text: draft.collapsedText,
    imageStore: draft.imageStore,
    textFileName: configuration.textFileName ?? '',
  });
  useSettingsStore.getState().patch({ ...configuration.settings, fontFile: assets.fontFile });
  changeBackground(assets.background);
  usePreferencesStore.getState().patch(checkpoint.preferences);
  restoredAssets = checkpoint.assets;
  legacyFontIndex = checkpoint.legacyFontIndex;
  lastCheckpoint = raw;
  setResourceRecord('workspace', checkpoint.assets);
}
async function hydrateLegacy(): Promise<void> {
  const keys: RecordKey[] = [
    'studio.draft',
    'studio.settings',
    'studio.assets',
    'studio.legacy',
    'studio.locale',
    'studio.theme',
    'markdownTableMode',
  ];
  const records = new Map(
    await Promise.all(keys.map(async (key) => [key, await readRecord(key)] as const)),
  );
  const rawDraft = records.get('studio.draft');
  if (rawDraft) useDocumentStore.getState().setText(v.parse(v.string(), JSON.parse(rawDraft)));
  const rawSettings = records.get('studio.settings');
  const legacy = records.get('studio.legacy');
  if (rawSettings || legacy) {
    const configuration = parseConfiguration(
      rawSettings ?? migrateLegacySettings(legacy ?? '{}', []),
      useSettingsStore.getState(),
      'draft',
    );
    useSettingsStore.getState().patch(configuration.settings);
    if (configuration.textFileName)
      useDocumentStore.getState().setFileName(configuration.textFileName);
    if (!rawDraft && configuration.text !== undefined)
      useDocumentStore.getState().setText(configuration.text);
    if (!rawSettings && legacy) {
      const fields = v.parse(v.record(v.string(), v.unknown()), JSON.parse(legacy));
      const selected = fields['selectedOption'];
      const index =
        typeof selected === 'string' || typeof selected === 'number' ? Number(selected) - 1 : -1;
      if (Number.isInteger(index) && index >= 0) legacyFontIndex = index;
    }
  }
  const rawAssets = records.get('studio.assets');
  if (rawAssets) {
    const snapshot = v.parse(assetSnapshotSchema, JSON.parse(rawAssets));
    const assets = await restoreAssets(snapshot);
    const document = useDocumentStore.getState();
    document.replace({
      text: document.text,
      imageStore: { ...assets.imageStore, ...document.imageStore },
      textFileName: document.textFileName,
    });
    changeBackground(assets.background);
    useSettingsStore.getState().patch({ fontFile: assets.fontFile });
    restoredAssets = snapshot;
  }
  setResourceRecord('workspace', restoredAssets);
  const rawMode = records.get('markdownTableMode');
  let mode: unknown = 'latex';
  try {
    if (rawMode) mode = JSON.parse(rawMode);
  } catch {
    disableResourceCollection();
    /* Keep the default table mode. */
  }
  usePreferencesStore.getState().patch({
    locale: records.get('studio.locale') === 'en' ? 'en' : 'cn',
    theme: records.get('studio.theme') === 'dark' ? 'dark' : 'light',
    tableMode:
      mode === 'list' || mode === 'aligned' || mode === 'raw_pipe' || mode === 'clean'
        ? mode
        : 'latex',
  });
}
export async function hydrateWorkspace(): Promise<void> {
  try {
    const checkpoint = await readRecord('studio.workspace');
    if (checkpoint) await hydrateCheckpoint(checkpoint);
    else await hydrateLegacy();
  } catch {
    disableResourceCollection();
    hydrationBlocked = true;
    useSaveStatus.setState({ status: 'error' });
    useNotificationStore.getState().fail('restoreFailed');
  }
  await registerPresetResources();
  const preferences = usePreferencesStore.getState();
  document.documentElement.dataset['theme'] = preferences.theme;
  document.documentElement.lang = preferences.locale === 'cn' ? 'zh-CN' : 'en';
  try {
    const raw = await readRecord('studio.generation');
    if (raw) {
      const parsed = v.safeParse(generationRecordSchema, JSON.parse(raw));
      if (parsed.success) restoredGeneration = parsed.output;
    }
  } catch {
    useNotificationStore.getState().fail('restoreFailed');
  }
}

export function startWorkspacePersistence(): () => void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let disposed = false;
  let tail: Promise<void> = Promise.resolve();
  let revision = 0;
  let previousImages = useDocumentStore.getState().imageStore;
  let previousFont = useSettingsStore.getState().fontFile;
  let previousBackground = useSettingsStore.getState().background;
  let assetSnapshot = restoredAssets;
  if (!assetSnapshot && !Object.keys(previousImages).length && !previousFont && !previousBackground)
    assetSnapshot = { version: 1, images: {}, font: null, background: null };
  const failure = (failedRevision: number) => {
    disableResourceCollection();
    if (failedRevision !== revision) return;
    useSaveStatus.setState({ status: 'error' });
    useNotificationStore.getState().fail('storageUnavailable');
  };
  const flush = (): Promise<void> => {
    clearTimeout(timer);
    if (hydrationBlocked) {
      useSaveStatus.setState({ status: 'error' });
      return Promise.resolve();
    }
    const currentRevision = revision;
    const document = useDocumentStore.getState();
    const settings = useSettingsStore.getState();
    const preferences = usePreferencesStore.getState();
    const saveAssets =
      !assetSnapshot ||
      document.imageStore !== previousImages ||
      settings.fontFile !== previousFont ||
      settings.background !== previousBackground;
    const commit = (assets: AssetSnapshot): Promise<void> => {
      // One atomic metadata record refers only to fully committed binary assets.
      const serialized = JSON.stringify({
        version: 2,
        text: document.text,
        configuration: JSON.stringify(serializeConfiguration(settings, document.textFileName)),
        assets,
        preferences: {
          locale: preferences.locale,
          theme: preferences.theme,
          themeColor: preferences.themeColor,
          autoCheckUpdates: preferences.autoCheckUpdates,
          tableMode: preferences.tableMode,
        },
        legacyFontIndex,
      });
      const pending =
        serialized === lastCheckpoint
          ? Promise.resolve()
          : writeRecord('studio.workspace', serialized);
      return pending.then(() => {
        lastCheckpoint = serialized;
        setResourceRecord('workspace', assets);
        assetSnapshot = assets;
        previousImages = document.imageStore;
        previousFont = settings.fontFile;
        previousBackground = settings.background;
        if (!disposed && revision === currentRevision) useSaveStatus.setState({ status: 'saved' });
      });
    };
    const prepared = saveAssets ? preparedSnapshot(document, settings) : null;
    if (prepared) {
      return commit(prepared)
        .catch(() => failure(currentRevision))
        .finally(() => releaseSnapshot(prepared));
    } else if (!saveAssets && assetSnapshot) {
      // This reaches localStorage synchronously, so a pagehide flush keeps the final keystroke.
      return commit(assetSnapshot).catch(() => failure(currentRevision));
    } else {
      tail = tail
        .catch(() => {})
        .then(async () => {
          if (revision !== currentRevision) return;
          const assets = await captureAssets(document, settings);
          let committed = false;
          try {
            if (revision === currentRevision) {
              await commit(assets);
              committed = true;
            }
          } finally {
            releaseSnapshot(assets, committed ? 'workspace' : undefined);
          }
        })
        .catch(() => failure(currentRevision));
      return tail;
    }
  };
  flushActive = flush;
  const flushEvent = () => {
    void flush();
  };
  const schedule = () => {
    revision += 1;
    useSaveStatus.setState({ status: hydrationBlocked ? 'error' : 'saving' });
    clearTimeout(timer);
    if (!hydrationBlocked) timer = setTimeout(flushEvent, 250);
  };
  const unsubscribe = [
    useDocumentStore.subscribe(schedule),
    useSettingsStore.subscribe(schedule),
    usePreferencesStore.subscribe(schedule),
  ];
  const visibility = () => {
    if (document.visibilityState === 'hidden') flushEvent();
  };
  window.addEventListener('pagehide', flushEvent);
  window.addEventListener('blur', flushEvent);
  document.addEventListener('visibilitychange', visibility);
  schedule();
  return () => {
    flushEvent();
    disposed = true;
    if (flushActive === flush) flushActive = null;
    clearTimeout(timer);
    for (const stop of unsubscribe) stop();
    window.removeEventListener('pagehide', flushEvent);
    window.removeEventListener('blur', flushEvent);
    document.removeEventListener('visibilitychange', visibility);
  };
}
