import { create } from 'zustand';
import type { UpdateState } from './contracts';
export interface UpdatePrompt {
  key: string;
  update: UpdateState;
  manual: boolean;
}
interface UpdatesStore {
  update: UpdateState;
  prompt: UpdatePrompt | null;
  pendingPrompt: UpdatePrompt | null;
  seen: readonly string[];
  replace: (next: UpdateState) => void;
  requestPrompt: (update: UpdateState, key: string, manual?: boolean) => void;
  showPending: () => void;
  dismissPrompt: () => void;
}
export const useUpdatesStore = create<UpdatesStore>()((set) => ({
  update: { status: 'idle' },
  prompt: null,
  pendingPrompt: null,
  seen: [],
  replace: (update) =>
    set((state) => ({
      update,
      pendingPrompt:
        update.status === 'available' &&
        (update.version ? `release:${update.version}` : update.deploymentId) ===
          state.pendingPrompt?.key
          ? state.pendingPrompt
          : null,
    })),
  requestPrompt: (update, key, manual = false) =>
    set((state) => {
      if ((!manual && state.seen.includes(key)) || state.prompt?.key === key) return state;
      if (state.pendingPrompt?.key === key)
        return manual && !state.pendingPrompt.manual
          ? { pendingPrompt: { ...state.pendingPrompt, manual: true } }
          : state;
      return { pendingPrompt: { key, update, manual } };
    }),
  showPending: () =>
    set((state) => {
      if (!state.pendingPrompt || state.prompt) return state;
      const key = state.update.version
        ? `release:${state.update.version}`
        : state.update.deploymentId;
      if (
        key !== state.pendingPrompt.key ||
        !['available', 'ready', 'downloading', 'cancelled', 'launched'].includes(
          state.update.status,
        )
      )
        return { pendingPrompt: null };
      return {
        prompt: state.pendingPrompt,
        pendingPrompt: null,
        seen: [...new Set([...state.seen, state.pendingPrompt.key])],
      };
    }),
  dismissPrompt: () => set({ prompt: null, pendingPrompt: null }),
}));
