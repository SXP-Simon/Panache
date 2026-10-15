/// <reference types="vite/client" />
export {};
declare global {
  interface Window {
    handwritingDesktop?: {
      onDownloadFinished(callback: (payload: { file: string; state: string }) => void): void;
      revealLastDownload(): void;
    };
  }
}
