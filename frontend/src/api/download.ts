import type { DownloadMode } from './types.ts';

export function downloadResult(blob: Blob, mode: DownloadMode): () => void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = mode === 'pdf' ? 'images.pdf' : 'images.zip';
  document.body.append(link);
  link.click();
  link.remove();
  const timer = setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return () => {
    clearTimeout(timer);
    URL.revokeObjectURL(url);
  };
}
