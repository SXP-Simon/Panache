import { create } from 'zustand';
import type { FinePreview } from './fineEditModel';
import type { DocumentData } from '@/features/document/store';
import type { SettingsData } from '@/features/settings/store';

export type PreviewSource = { draft: DocumentData; settings: SettingsData; fine: boolean };

interface PreviewState {
  images: string[];
  inkLayers: string[];
  latinInkLayers: (string | null)[];
  fineEdit: (FinePreview & { text: string | null }) | null;
  source: PreviewSource | null;
  revision: number;
  currentPage: number;
  pdfBytes: number;
  savedPath: string;
  setImages: (
    images: string[],
    inkLayers?: string[],
    page?: number,
    latinInkLayers?: (string | null)[],
    fineEdit?: FinePreview & { text: string | null },
    source?: PreviewSource,
  ) => void;
  setPage: (currentPage: number) => void;
  setDownload: (values: { savedPath?: string; pdfBytes?: number }) => void;
}
export const usePreviewStore = create<PreviewState>()((set) => ({
  images: [],
  inkLayers: [],
  latinInkLayers: [],
  fineEdit: null,
  source: null,
  revision: 0,
  currentPage: 0,
  pdfBytes: 0,
  savedPath: '',
  setImages: (images, inkLayers = [], page = 0, latinInkLayers = [], fineEdit, source) =>
    set((state) => ({
      images,
      inkLayers,
      latinInkLayers,
      fineEdit: fineEdit ?? null,
      source: source ?? null,
      revision: state.revision + 1,
      currentPage: Math.max(0, Math.min(page, images.length - 1)),
    })),
  setPage: (currentPage) => set({ currentPage }),
  setDownload: (values) => set(values),
}));
