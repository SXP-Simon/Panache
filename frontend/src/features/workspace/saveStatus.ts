import { create } from 'zustand';

export const useSaveStatus = create<{ status: 'saving' | 'saved' | 'error' }>(() => ({
  status: 'saved',
}));
