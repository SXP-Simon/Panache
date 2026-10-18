export const DEFAULT_THEME_COLOR = '#a3f635';
export function applyThemeColor(color: string, dark: boolean): void {
  const root = document.documentElement;
  const channel = (start: number) => {
    const value = Number.parseInt(color.slice(start, start + 2), 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  const luminance = 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5);
  const palette: Record<string, string> = {
    '--primary': color,
    '--primary-foreground': luminance > 0.179 ? '#000000' : '#ffffff',
    '--green-ink': `oklch(from ${color} ${dark ? '.83 .10' : '.40 .12'} h)`,
    '--green-border': `oklch(from ${color} ${dark ? '.38 .05' : '.86 .05'} h)`,
    '--accent': `oklch(from ${color} ${dark ? '.26 .035' : '.98 .018'} h)`,
    '--background': `oklch(from ${color} ${dark ? '.14 .012' : '.99 .005'} h)`,
    '--surface-heading': `oklch(from ${color} ${dark ? '.23 .025' : '.98 .018'} h)`,
    '--surface-toolbar': `oklch(from ${color} ${dark ? '.27 .035' : '.96 .03'} h)`,
    '--surface-footer': `oklch(from ${color} ${dark ? '.235 .025' : '.98 .02'} h)`,
    '--surface-input': `oklch(from ${color} ${dark ? '.185 .018' : '.99 .009'} h)`,
    '--surface-hover': `oklch(from ${color} ${dark ? '.31 .04' : '.94 .05'} h)`,
    '--surface-canvas': `oklch(from ${color} ${dark ? '.165 .018' : '.967 .014'} h)`,
  };
  for (const [key, value] of Object.entries(palette)) {
    if (color.toLowerCase() === DEFAULT_THEME_COLOR) root.style.removeProperty(key);
    else root.style.setProperty(key, value);
  }
}
