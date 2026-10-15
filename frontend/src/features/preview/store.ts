import { create } from 'zustand';

interface PreviewState {
  images: string[];
  currentPage: number;
  pdfBytes: number;
  savedPath: string;
  setImages: (images: string[]) => void;
  setPage: (currentPage: number) => void;
  setDownload: (values: { savedPath?: string; pdfBytes?: number }) => void;
}
export const usePreviewStore = create<PreviewState>()((set) => ({
  images: [],
  currentPage: 0,
  pdfBytes: 0,
  savedPath: '',
  setImages: (images) => set({ images, currentPage: 0 }),
  setPage: (currentPage) => set({ currentPage }),
  setDownload: (values) => set(values),
}));
