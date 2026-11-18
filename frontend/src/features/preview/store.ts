import { create } from 'zustand';

interface PreviewState {
  images: string[];
  inkLayers: string[];
  latinInkLayers: (string | null)[];
  currentPage: number;
  pdfBytes: number;
  savedPath: string;
  setImages: (
    images: string[],
    inkLayers?: string[],
    page?: number,
    latinInkLayers?: (string | null)[],
  ) => void;
  setPage: (currentPage: number) => void;
  setDownload: (values: { savedPath?: string; pdfBytes?: number }) => void;
}
export const usePreviewStore = create<PreviewState>()((set) => ({
  images: [],
  inkLayers: [],
  latinInkLayers: [],
  currentPage: 0,
  pdfBytes: 0,
  savedPath: '',
  setImages: (images, inkLayers = [], page = 0, latinInkLayers = []) =>
    set({
      images,
      inkLayers,
      latinInkLayers,
      currentPage: Math.max(0, Math.min(page, images.length - 1)),
    }),
  setPage: (currentPage) => set({ currentPage }),
  setDownload: (values) => set(values),
}));
