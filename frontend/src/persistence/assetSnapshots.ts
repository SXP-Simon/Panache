import * as v from 'valibot';
import { blobToDataUrl, dataUrlToBlob, readAsset, writeAsset } from './index';
import type { DocumentData } from '@/features/document/store';
import type { SettingsData } from '@/features/settings/store';
import {
  disableResourceCollection,
  hasPersistedAsset,
  isProtectedAsset,
  notePersistedAsset,
  reserveRestoringSnapshot,
  retainCapturedSnapshot,
  withResourceOperation,
} from './resourceLifecycle';
export {
  collectUnusedAssets,
  disableResourceCollection,
  releaseSnapshot,
  setResourceRecord,
} from './resourceLifecycle';
export type { ResourceOwner } from './resourceLifecycle';

const fileSchema = v.object({
  id: v.string(),
  name: v.string(),
  type: v.string(),
  lastModified: v.number(),
});
export const assetSnapshotSchema = v.object({
  version: v.literal(1),
  images: v.record(v.string(), v.string()),
  font: v.nullable(fileSchema),
  background: v.nullable(fileSchema),
});
export type AssetSnapshot = v.InferOutput<typeof assetSnapshotSchema>;
const imageIds = new Map<string, Promise<string>>();
const fileIds = new WeakMap<File, Promise<string>>();
const preparedImages = new Map<string, string>();
const preparedFiles = new WeakMap<File, string>();
const writes = new Map<string, Promise<void>>();

async function hashBlob(blob: Blob): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
  return `asset-${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}
async function ensureAsset(id: string, blob: Blob): Promise<void> {
  if (hasPersistedAsset(id)) return;
  let pending = writes.get(id);
  if (!pending) {
    pending = writeAsset(id, blob)
      .then(() => notePersistedAsset(id))
      .finally(() => writes.delete(id));
    writes.set(id, pending);
  }
  await pending;
}
async function saveImage(data: string): Promise<string> {
  data = data.trim();
  let blob: Blob | undefined;
  let pending = imageIds.get(data);
  if (!pending) {
    blob = dataUrlToBlob(data);
    pending = hashBlob(blob).catch((error: unknown) => {
      imageIds.delete(data);
      throw error;
    });
    imageIds.set(data, pending);
  }
  const id = await pending;
  if (!hasPersistedAsset(id)) await ensureAsset(id, blob ?? dataUrlToBlob(data));
  preparedImages.set(data, id);
  return id;
}
async function saveFile(file: File | null): Promise<v.InferOutput<typeof fileSchema> | null> {
  if (!file) return null;
  let pending = fileIds.get(file);
  if (!pending) {
    pending = hashBlob(file).catch((error: unknown) => {
      fileIds.delete(file);
      throw error;
    });
    fileIds.set(file, pending);
  }
  const id = await pending;
  await ensureAsset(id, file);
  preparedFiles.set(file, id);
  return { id, name: file.name, type: file.type, lastModified: file.lastModified };
}

function preparedFile(file: File | null): AssetSnapshot['font'] | undefined {
  if (!file) return null;
  const id = preparedFiles.get(file);
  if (!id || !hasPersistedAsset(id)) return undefined;
  return { id, name: file.name, type: file.type, lastModified: file.lastModified };
}

/** Builds a leased snapshot synchronously, after the upload's capture has prepared its bytes. */
export function preparedSnapshot(
  document: DocumentData,
  settings: SettingsData,
): AssetSnapshot | null {
  const images: Record<string, string> = {};
  for (const [key, data] of Object.entries(document.imageStore)) {
    const id = preparedImages.get(data.trim());
    if (!id || !hasPersistedAsset(id)) return null;
    images[key] = id;
  }
  const font = preparedFile(settings.fontFile);
  const background = preparedFile(settings.background);
  if (font === undefined || background === undefined) return null;
  const snapshot: AssetSnapshot = { version: 1, images, font, background };
  retainCapturedSnapshot(snapshot);
  return snapshot;
}
export async function captureAssets(
  document: DocumentData,
  settings: SettingsData,
): Promise<AssetSnapshot> {
  return withResourceOperation(async () => {
    try {
      // Keep the entire store: an undo can restore a currently unreferenced image placeholder.
      const imagesInMemory = Object.entries(document.imageStore);
      const activeData = new Set(imagesInMemory.map(([, data]) => data.trim()));
      for (const data of imageIds.keys()) {
        const id = preparedImages.get(data);
        if (!activeData.has(data) && (!id || !isProtectedAsset(id))) {
          imageIds.delete(data);
          preparedImages.delete(data);
        }
      }
      const [images, font, background] = await Promise.all([
        Promise.all(imagesInMemory.map(async ([id, data]) => [id, await saveImage(data)] as const)),
        saveFile(settings.fontFile),
        saveFile(settings.background),
      ]);
      const snapshot: AssetSnapshot = {
        version: 1,
        images: Object.fromEntries(images),
        font,
        background,
      };
      retainCapturedSnapshot(snapshot);
      return snapshot;
    } catch (error) {
      disableResourceCollection();
      throw error;
    }
  });
}
async function requireAsset(id: string): Promise<Blob> {
  const blob = await readAsset(id);
  if (!blob) throw new Error('Saved resource is missing');
  notePersistedAsset(id);
  return blob;
}
async function restoreFile(file: v.InferOutput<typeof fileSchema> | null): Promise<File | null> {
  if (!file) return null;
  const restored = new File([await requireAsset(file.id)], file.name, {
    type: file.type,
    lastModified: file.lastModified,
  });
  fileIds.set(restored, Promise.resolve(file.id));
  preparedFiles.set(restored, file.id);
  return restored;
}
export async function restoreAssets(snapshot: AssetSnapshot) {
  const release = reserveRestoringSnapshot(snapshot);
  try {
    return await withResourceOperation(async () => {
      const [images, fontFile, background] = await Promise.all([
        Promise.all(
          Object.entries(snapshot.images).map(async ([key, id]) => {
            const data = await blobToDataUrl(await requireAsset(id));
            imageIds.set(data, Promise.resolve(id));
            preparedImages.set(data, id);
            return [key, data] as const;
          }),
        ),
        restoreFile(snapshot.font),
        restoreFile(snapshot.background),
      ]);
      return { imageStore: Object.fromEntries(images), fontFile, background };
    });
  } catch (error) {
    disableResourceCollection();
    throw error;
  } finally {
    release();
  }
}
