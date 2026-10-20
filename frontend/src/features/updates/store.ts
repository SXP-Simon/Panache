import { create } from 'zustand';
import type { UpdateState } from './contracts';
interface UpdatesStore {
  update: UpdateState;
  replace: (next: UpdateState) => void;
}
export const useUpdatesStore = create<UpdatesStore>()((set) => ({
  update: { status: 'idle' },
  replace: (update) => set({ update }),
}));
