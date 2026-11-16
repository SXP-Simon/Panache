import { create } from 'zustand';

interface PreviewState {
  images: string[];
  inkLayers: string[];
  currentPage: number;
  pdfBytes: number;
  savedPath: string;
  setImages: (images: string[], inkLayers?: string[]) => void;
  setPage: (currentPage: number) => void;
  setDownload: (values: { savedPath?: string; pdfBytes?: number }) => void;
}
export const usePreviewStore = create<PreviewState>()((set) => ({
  images: [],
  inkLayers: [],
  currentPage: 0,
  pdfBytes: 0,
  savedPath: '',
  setImages: (images, inkLayers = []) => set({ images, inkLayers, currentPage: 0 }),
  setPage: (currentPage) => set({ currentPage }),
  setDownload: (values) => set(values),
}));
