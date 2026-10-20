import { create } from 'zustand';
import { DEFAULT_THEME_COLOR } from './themeColors';
import type { Locale } from '@/i18n';
import type { TableMode } from '@/utils/cleanMarkdown';

export interface PreferencesData {
  locale: Locale;
  theme: 'light' | 'dark';
  tableMode: TableMode;
  themeColor: string;
  autoCheckUpdates: boolean;
}
interface PreferencesState extends PreferencesData {
  patch: (values: Partial<PreferencesData>) => void;
  toggleLocale: () => void;
  toggleTheme: () => void;
}
export const usePreferencesStore = create<PreferencesState>()((set) => ({
  locale: 'cn',
  theme: 'light',
  tableMode: 'latex',
  themeColor: DEFAULT_THEME_COLOR,
  autoCheckUpdates: true,
  patch: (values) => set(values),
  toggleLocale: () => set((state) => ({ locale: state.locale === 'cn' ? 'en' : 'cn' })),
  toggleTheme: () => set((state) => ({ theme: state.theme === 'dark' ? 'light' : 'dark' })),
}));
