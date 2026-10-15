import { create } from 'zustand';
import type { MessageKey } from '@/i18n';

export type Notice = { key: MessageKey } | { text: string };
interface NotificationState {
  notice: Notice | null;
  error: Notice | null;
  inform: (key: MessageKey) => void;
  fail: (key: MessageKey) => void;
  failText: (text: string) => void;
  clear: () => void;
}
export const useNotificationStore = create<NotificationState>()((set) => ({
  notice: null,
  error: null,
  inform: (key) => set({ notice: { key }, error: null }),
  fail: (key) => set({ error: { key }, notice: null }),
  failText: (text) => set({ error: { text }, notice: null }),
  clear: () => set({ notice: null, error: null }),
}));
