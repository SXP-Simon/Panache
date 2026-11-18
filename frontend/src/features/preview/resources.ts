import { useSettingsStore } from '@/features/settings/store';
import { usePreviewStore } from './store';

export function clearPreview(): void {
  replacePreview([]);
}
export function replacePreview(
  images: string[],
  inkLayers?: string[],
  keepPage = false,
  latinInkLayers?: (string | null)[],
): void {
  const previous = usePreviewStore.getState();
  previous.setImages(images, inkLayers, keepPage ? previous.currentPage : 0, latinInkLayers);
  for (const url of previous.images)
    if (url.startsWith('blob:') && !images.includes(url)) URL.revokeObjectURL(url);
}
export function changeBackground(file: File | null, ruled = false): void {
  const previous = useSettingsStore.getState().backgroundUrl;
  if (previous) URL.revokeObjectURL(previous);
  useSettingsStore.getState().patch({
    background: file,
    backgroundRuled: Boolean(file && ruled),
    backgroundUrl: file ? URL.createObjectURL(file) : '',
  });
  clearPreview();
}
