import { useSettingsStore } from '@/features/settings/store';
import { usePreviewStore } from './store';

export function clearPreview(): void {
  for (const url of usePreviewStore.getState().images)
    if (url.startsWith('blob:')) URL.revokeObjectURL(url);
  usePreviewStore.getState().setImages([]);
}
export function replacePreview(images: string[]): void {
  clearPreview();
  usePreviewStore.getState().setImages(images);
}
export function changeBackground(file: File | null): void {
  const previous = useSettingsStore.getState().backgroundUrl;
  if (previous) URL.revokeObjectURL(previous);
  useSettingsStore
    .getState()
    .patch({ background: file, backgroundUrl: file ? URL.createObjectURL(file) : '' });
  clearPreview();
}
