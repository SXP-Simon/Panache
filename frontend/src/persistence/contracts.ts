export const recordKeys = [
  'studio.workspace',
  'studio.draft',
  'studio.settings',
  'studio.preset',
  'studio.assets',
  'studio.generation',
  'studio.locale',
  'studio.theme',
  'markdownTableMode',
  'studio.legacy',
] as const;

export type RecordKey = (typeof recordKeys)[number];
export const MAX_RECORD_BYTES = 8 * 1024 * 1024;
export const MAX_ASSET_BYTES = 32 * 1024 * 1024;

export function validateRecordKey(key: string): asserts key is RecordKey {
  if (!recordKeys.some((allowed) => allowed === key)) throw new Error('Invalid storage record');
}

export function validateRecord(value: string): void {
  if (new TextEncoder().encode(value).byteLength > MAX_RECORD_BYTES)
    throw new Error('Storage record exceeds 8 MiB');
}

export function validateAssetId(id: string): void {
  if (!/^[a-z0-9][a-z0-9_-]{0,95}$/.test(id) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/.test(id))
    throw new Error('Invalid storage asset ID');
}

export function validateAsset(blob: Blob): void {
  if (blob.size > MAX_ASSET_BYTES) throw new Error('Storage asset exceeds 32 MiB');
}
