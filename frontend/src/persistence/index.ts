import {
  validateAsset,
  validateAssetId,
  validateRecord,
  validateRecordKey,
  MAX_ASSET_BYTES,
} from './contracts';
import type { RecordKey } from './contracts';
import { readWebAsset, removeWebAsset, writeWebAsset } from './web';
export type { RecordKey } from './contracts';
export { MAX_ASSET_BYTES, MAX_RECORD_BYTES, recordKeys } from './contracts';

const legacySettingKeys = [
  'fontSize',
  'lineSpacing',
  'wordSpacing',
  'width',
  'height',
  'marginTop',
  'marginBottom',
  'marginLeft',
  'marginRight',
  'lineSpacingSigma',
  'fontSizeSigma',
  'wordSpacingSigma',
  'perturbXSigma',
  'perturbYSigma',
  'perturbThetaSigma',
  'ink_depth_sigma',
  'strikethrough_probability',
  'strikethrough_length_sigma',
  'strikethrough_angle_sigma',
  'strikethrough_width_sigma',
  'strikethrough_width',
  'isUnderlined',
  'enableEnglishSpacing',
  'enableFullPreview',
  'selectedOption',
  'fill',
  'text',
  'selectedTextFileName',
] as const;

/** Reads the old browser store only; desktop operations never accept arbitrary keys or paths. */
export function readLegacyLocalRecord(key: string): string | null {
  return localStorage.getItem(key);
}

function readLegacySettings(): string | null {
  const values: Record<string, string | number | boolean> = {};
  for (const key of legacySettingKeys) {
    const raw = readLegacyLocalRecord(key);
    if (raw === null) continue;
    try {
      const value: unknown = JSON.parse(raw);
      if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean')
        values[key] = value;
    } catch {
      // A damaged field must not discard the rest of a legacy workspace.
    }
  }
  return Object.keys(values).length ? JSON.stringify(values) : null;
}

function readLocalRecord(key: RecordKey): string | null {
  const existing = localStorage.getItem(key);
  if (existing !== null) return existing;
  if (key === 'studio.legacy') return readLegacySettings();
  return key === 'studio.draft'
    ? localStorage.getItem('text')
    : key === 'studio.preset'
      ? localStorage.getItem('myPreset')
      : null;
}

let desktopOperation: Promise<unknown> = Promise.resolve();
function desktopCall<T>(operation: () => Promise<T>): Promise<T> {
  const next = desktopOperation.catch(() => {}).then(operation);
  desktopOperation = next;
  return next;
}

export async function readRecord(key: RecordKey): Promise<string | null> {
  validateRecordKey(key);
  const storage = window.handwritingDesktop?.storage;
  if (storage) {
    const stored = await desktopCall(() => storage.readRecord(key));
    if (stored !== null) {
      validateRecord(stored);
      return stored;
    }
    const legacy = readLocalRecord(key);
    if (legacy !== null) {
      validateRecord(legacy);
      await storage.writeRecord(key, legacy);
    }
    return legacy;
  }
  const value = readLocalRecord(key);
  if (value !== null) validateRecord(value);
  return value;
}

export async function writeRecord(key: RecordKey, value: string): Promise<void> {
  validateRecordKey(key);
  validateRecord(value);
  const storage = window.handwritingDesktop?.storage;
  // Dispatch small records immediately so pagehide does not leave them behind a resource queue.
  if (storage) await storage.writeRecord(key, value);
  else localStorage.setItem(key, value);
}

export async function removeRecord(key: RecordKey): Promise<void> {
  validateRecordKey(key);
  const storage = window.handwritingDesktop?.storage;
  if (storage) await storage.removeRecord(key);
  localStorage.removeItem(key);
  if (key === 'studio.draft') localStorage.removeItem('text');
  if (key === 'studio.preset') localStorage.removeItem('myPreset');
  if (key === 'studio.legacy')
    for (const legacyKey of legacySettingKeys) localStorage.removeItem(legacyKey);
}

export async function readAsset(id: string): Promise<Blob | null> {
  validateAssetId(id);
  const storage = window.handwritingDesktop?.storage;
  if (!storage) return readWebAsset(id);
  const asset = await desktopCall(() => storage.readAsset(id));
  if (asset === null) return null;
  const blob = new Blob([new Uint8Array(asset.bytes)], { type: asset.mimeType });
  validateAsset(blob);
  return blob;
}

export async function writeAsset(id: string, blob: Blob): Promise<void> {
  validateAssetId(id);
  validateAsset(blob);
  const storage = window.handwritingDesktop?.storage;
  if (storage)
    await desktopCall(async () => storage.writeAsset(id, await blob.arrayBuffer(), blob.type));
  else await writeWebAsset(id, blob);
}

export async function removeAsset(id: string): Promise<void> {
  validateAssetId(id);
  const storage = window.handwritingDesktop?.storage;
  if (storage) await desktopCall(() => storage.removeAsset(id));
  else await removeWebAsset(id);
}

export async function blobToDataUrl(blob: Blob): Promise<string> {
  validateAsset(blob);
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () =>
      typeof reader.result === 'string'
        ? resolve(reader.result)
        : reject(new Error('Cannot read stored asset'));
    reader.onerror = () => reject(reader.error ?? new Error('Cannot read stored asset'));
    reader.onabort = () => reject(new Error('Reading stored asset was aborted'));
    reader.readAsDataURL(blob);
  });
}

export function dataUrlToBlob(data: string): Blob {
  if (data.length > Math.ceil(MAX_ASSET_BYTES / 3) * 4 + 512)
    throw new Error('Storage asset exceeds 32 MiB');
  const match = /^data:([^;,]+);base64,([A-Za-z0-9+/=\s]*)$/.exec(data);
  if (!match?.[1] || match[2] === undefined) throw new Error('Invalid binary data URL');
  const binary = atob(match[2].replace(/\s/g, ''));
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  const blob = new Blob([bytes], { type: match[1] });
  validateAsset(blob);
  return blob;
}
