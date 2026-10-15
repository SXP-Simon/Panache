import { removeAsset } from './index';
import type { AssetSnapshot } from './assetSnapshots';

export type ResourceOwner = 'workspace' | 'preset';
const records = new Map<ResourceOwner, ReadonlySet<string>>();
const knownAssets = new Set<string>();
const deletingAssets = new Set<string>();
const reservations = new Map<symbol, ReadonlySet<string>>();
const capturedSnapshots = new WeakMap<AssetSnapshot, symbol>();
let operations: Promise<unknown> = Promise.resolve();
// Web tabs do not share these leases. Reclaim only through the single-window desktop bridge.
let collectionAllowed = Boolean(window.handwritingDesktop?.storage);
let collectionScheduled = false;

function snapshotIds(snapshot: AssetSnapshot): ReadonlySet<string> {
  return new Set([
    ...Object.values(snapshot.images),
    ...(snapshot.font ? [snapshot.font.id] : []),
    ...(snapshot.background ? [snapshot.background.id] : []),
  ]);
}

/** Serializes binary IO with reclamation, including captures not yet assigned a hash. */
export function withResourceOperation<T>(operation: () => Promise<T>): Promise<T> {
  const pending = operations.catch(() => {}).then(operation);
  operations = pending;
  return pending;
}

export function hasPersistedAsset(id: string): boolean {
  return knownAssets.has(id) && !deletingAssets.has(id);
}

export function notePersistedAsset(id: string): void {
  knownAssets.add(id);
}

/** Fail closed for this run: an unreadable or failed record must never authorize deletion. */
export function disableResourceCollection(): void {
  collectionAllowed = false;
}

export function isProtectedAsset(id: string): boolean {
  for (const references of records.values()) if (references.has(id)) return true;
  for (const references of reservations.values()) if (references.has(id)) return true;
  return false;
}

export function collectUnusedAssets(): Promise<void> {
  return withResourceOperation(async () => {
    if (!collectionAllowed || !records.has('workspace') || !records.has('preset')) return;
    for (const id of [...knownAssets]) {
      if (!collectionAllowed) return;
      // Only application hashes observed during this run are candidates; never enumerate files.
      if (!/^asset-[a-f0-9]{64}$/.test(id) || isProtectedAsset(id)) continue;
      deletingAssets.add(id);
      try {
        await removeAsset(id);
        knownAssets.delete(id);
      } finally {
        deletingAssets.delete(id);
      }
    }
  });
}

function scheduleCollection(): void {
  if (collectionScheduled || !collectionAllowed) return;
  collectionScheduled = true;
  queueMicrotask(() => {
    collectionScheduled = false;
    // A cleanup failure keeps its candidate tracked for a later retry, without failing a saved draft.
    void collectUnusedAssets().catch(() => {});
  });
}

/** Call only after the fixed record was successfully read and parsed, or atomically committed. */
export function setResourceRecord(owner: ResourceOwner, snapshot: AssetSnapshot | null): void {
  records.set(owner, snapshot ? snapshotIds(snapshot) : new Set());
  scheduleCollection();
}

export function retainCapturedSnapshot(snapshot: AssetSnapshot): void {
  const token = Symbol('captured assets');
  reservations.set(token, snapshotIds(snapshot));
  capturedSnapshots.set(snapshot, token);
}

/** A capture remains protected until its record write commits or the caller discards it. */
export function releaseSnapshot(snapshot: AssetSnapshot, committedTo?: ResourceOwner): void {
  if (committedTo) records.set(committedTo, snapshotIds(snapshot));
  const token = capturedSnapshots.get(snapshot);
  if (token) {
    reservations.delete(token);
    capturedSnapshots.delete(snapshot);
  }
  scheduleCollection();
}

/** Restores reserve their source IDs before waiting for the binary IO lock. */
export function reserveRestoringSnapshot(snapshot: AssetSnapshot): () => void {
  const token = Symbol('restoring assets');
  reservations.set(token, snapshotIds(snapshot));
  return () => {
    reservations.delete(token);
    scheduleCollection();
  };
}
