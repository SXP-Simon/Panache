import { create } from 'zustand';
import { defaultNumbers } from '@/models';
import type { NumericKey } from '@/models';

export interface SettingsData {
  numbers: typeof defaultNumbers;
  selectedFont: string;
  fontFile: File | null;
  background: File | null;
  backgroundRuled: boolean;
  backgroundUrl: string;
  layoutStyle: 'standard' | 'homework';
  underlined: boolean;
  englishSpacing: boolean;
  fullPreview: boolean;
  ink: string;
  selectedPreset: string;
}
interface SettingsState extends SettingsData {
  patch: (values: Partial<SettingsData>) => void;
  setNumber: (key: NumericKey, value: number) => void;
  reset: (font: string) => void;
  applyPreset: (value: string, fonts: readonly string[]) => boolean;
}
export const initialSettings: SettingsData = {
  numbers: { ...defaultNumbers },
  selectedFont: '',
  fontFile: null,
  background: null,
  backgroundRuled: false,
  backgroundUrl: '',
  layoutStyle: 'standard',
  underlined: true,
  englishSpacing: false,
  fullPreview: false,
  ink: '#26322a',
  selectedPreset: '',
};
export const useSettingsStore = create<SettingsState>()((set, get) => ({
  ...initialSettings,
  patch: (values) => set(values),
  setNumber: (key, value) => set((state) => ({ numbers: { ...state.numbers, [key]: value } })),
  reset: (font) => set({ ...initialSettings, numbers: { ...defaultNumbers }, selectedFont: font }),
  applyPreset: (value, fonts) => {
    const state = get();
    if (state.background) return false;
    const numbers = { ...defaultNumbers };
    let selectedFont = state.selectedFont;
    let underlined = state.underlined;
    if (value === 'smallUnderlined') {
      Object.assign(numbers, {
        font_size: 70,
        line_spacing: 100,
        width: 2481,
        height: 3507,
        top_margin: 150,
        bottom_margin: 150,
        left_margin: 150,
        right_margin: 150,
        line_spacing_sigma: 1,
        font_size_sigma: 1,
        word_spacing_sigma: 2,
        perturb_x_sigma: 1,
        perturb_y_sigma: 1,
        perturb_theta_sigma: 0.05,
        word_spacing: 2,
        strikethrough_probability: 0,
      });
      selectedFont = fonts.find((font) => font === '云烟体.ttf') ?? selectedFont;
      underlined = true;
    } else if (value === 'clean') {
      Object.assign(numbers, {
        font_size_sigma: 0,
        word_spacing_sigma: 0,
        perturb_x_sigma: 0,
        perturb_y_sigma: 0,
        perturb_theta_sigma: 0,
        strikethrough_probability: 0,
      });
    }
    set({
      numbers,
      selectedFont,
      underlined,
      selectedPreset: value,
      ...(value === 'smallUnderlined' ? { englishSpacing: false, fontFile: null } : {}),
    });
    return true;
  },
}));
