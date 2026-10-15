import { MAX_ASSET_BYTES, validateAsset, validateAssetId } from './contracts';

const DATABASE = 'handwriting-studio';
const STORE = 'assets';
let database: Promise<IDBDatabase> | undefined;

function openDatabase(): Promise<IDBDatabase> {
  database ??= new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => {
        db.close();
        database = undefined;
      };
      resolve(db);
    };
    request.onerror = () => {
      database = undefined;
      reject(request.error ?? new Error('Cannot open asset storage'));
    };
    request.onblocked = () => {
      database = undefined;
      reject(new Error('Asset storage is blocked by another application tab'));
    };
  });
  return database;
}

async function transaction<T>(
  mode: IDBTransactionMode,
  operation: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await openDatabase();
  return new Promise<T>((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const request = operation(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(request.result);
    tx.onabort = () => reject(tx.error ?? new Error('Asset storage transaction was aborted'));
    tx.onerror = () => reject(tx.error ?? new Error('Asset storage transaction failed'));
  });
}

export async function readWebAsset(id: string): Promise<Blob | null> {
  validateAssetId(id);
  const value: unknown = await transaction('readonly', (store) => store.get(id));
  if (value === undefined) return null;
  if (!(value instanceof Blob) || value.size > MAX_ASSET_BYTES)
    throw new Error('Invalid stored asset');
  return value;
}

export async function writeWebAsset(id: string, blob: Blob): Promise<void> {
  validateAssetId(id);
  validateAsset(blob);
  await transaction('readwrite', (store) => store.put(blob, id));
}

export async function removeWebAsset(id: string): Promise<void> {
  validateAssetId(id);
  await transaction('readwrite', (store) => store.delete(id));
}
