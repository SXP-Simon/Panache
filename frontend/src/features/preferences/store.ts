import { create } from 'zustand';
import type { Locale } from '@/i18n';
import type { TableMode } from '@/utils/cleanMarkdown';

export interface PreferencesData {
  locale: Locale;
  theme: 'light' | 'dark';
  tableMode: TableMode;
}
interface PreferencesState extends PreferencesData {
  patch: (values: Partial<PreferencesData>) => void;
  toggleLocale: () => void;
  toggleTheme: () => void;
}
export const usePreferencesStore = create<PreferencesState>()((set) => ({
  locale: 'cn',
  theme: 'light',
  tableMode: 'list',
  patch: (values) => set(values),
  toggleLocale: () => set((state) => ({ locale: state.locale === 'cn' ? 'en' : 'cn' })),
  toggleTheme: () => set((state) => ({ theme: state.theme === 'dark' ? 'light' : 'dark' })),
}));
