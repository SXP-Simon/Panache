export const DEFAULT_THEME_COLOR = '#3c96ca';
export const DEFAULT_SECONDARY_COLOR = '#2f86bd';

export function restoreThemeColor(color: string): string {
  const normalized = color.toLowerCase();
  return normalized === '#a3f635' ? DEFAULT_THEME_COLOR : normalized;
}

export function applyThemeColors(primary: string, secondary: string): void {
  const root = document.documentElement;
  for (const [property, color, fallback] of [
    ['--primary', primary, DEFAULT_THEME_COLOR],
    ['--secondary', secondary, DEFAULT_SECONDARY_COLOR],
  ] as const) {
    if (color.toLowerCase() === fallback) root.style.removeProperty(property);
    else root.style.setProperty(property, color);
  }
}
