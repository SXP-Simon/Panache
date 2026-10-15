import { create } from 'zustand';
import { collapseInlineImages } from '@/utils/inlineImageManager';
import type { ImageStore } from '@/utils/inlineImageManager';

export interface DocumentData {
  text: string;
  imageStore: ImageStore;
  textFileName: string;
}
interface DocumentState extends DocumentData {
  setText: (text: string) => void;
  replace: (document: DocumentData) => void;
  setFileName: (name: string) => void;
}
export const useDocumentStore = create<DocumentState>()((set) => ({
  text: '',
  imageStore: {},
  textFileName: '',
  setText: (text) =>
    set((state) => {
      if (!text.includes('data:image/')) return { text };
      const draft = collapseInlineImages(text, state.imageStore);
      return { text: draft.collapsedText, imageStore: draft.imageStore };
    }),
  replace: (document) => set(document),
  setFileName: (textFileName) => set({ textFileName }),
}));
