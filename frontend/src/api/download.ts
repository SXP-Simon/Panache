import type { DownloadMode } from './types.ts';

export function downloadResult(blob: Blob, mode: DownloadMode | 'png'): () => void {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `images.${mode}`;
  document.body.append(link);
  link.click();
  link.remove();
  const timer = setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return () => {
    clearTimeout(timer);
    URL.revokeObjectURL(url);
  };
}
