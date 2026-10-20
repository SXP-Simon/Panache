/// <reference types="vite/client" />
export {};
declare global {
  interface Window {
    handwritingDesktop?: {
      onDownloadFinished(callback: (payload: { file: string; state: string }) => void): () => void;
      revealLastDownload(): void;
      onBeforeClose(callback: (reason: 'close' | 'update') => Promise<void>): () => void;
      updates: {
        state(): Promise<import('./features/updates/contracts').UpdateState>;
        check(): Promise<import('./features/updates/contracts').UpdateState>;
        download(): Promise<import('./features/updates/contracts').UpdateState>;
        cancel(): Promise<import('./features/updates/contracts').UpdateState>;
        open(): Promise<import('./features/updates/contracts').UpdateState>;
        manual(): Promise<import('./features/updates/contracts').UpdateState>;
        healthy(): Promise<boolean>;
        subscribe(
          callback: (state: import('./features/updates/contracts').UpdateState) => void,
        ): () => void;
      };
      storage: {
        readRecord(key: import('./persistence/contracts').RecordKey): Promise<string | null>;
        writeRecord(key: import('./persistence/contracts').RecordKey, value: string): Promise<void>;
        removeRecord(key: import('./persistence/contracts').RecordKey): Promise<void>;
        readAsset(id: string): Promise<{ bytes: Uint8Array; mimeType: string } | null>;
        writeAsset(id: string, bytes: ArrayBuffer, mimeType: string): Promise<void>;
        removeAsset(id: string): Promise<void>;
      };
    };
  }
}
