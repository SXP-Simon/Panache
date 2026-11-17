export type PaperArea = { left: number; first: number; right: number; last: number };
export type PaperSize = { width: number; height: number };

export function paperAreaLayout(area: PaperArea, size: PaperSize, rows: number) {
  if (!Number.isInteger(rows) || rows < 2 || rows > 500) return null;
  const spacing = Math.round((area.last - area.first) / (rows - 1));
  const top = Math.round(area.first) - spacing;
  const bottom = Math.round(area.first) + spacing * (rows - 1);
  const left = Math.round(area.left);
  const right = size.width - Math.round(area.right);
  if (spacing < 8 || top < 0 || bottom >= size.height || size.width - left - right < 8) return null;
  return {
    left_margin: left,
    right_margin: right,
    top_margin: top,
    bottom_margin: Math.max(0, size.height - bottom - Math.ceil(spacing / 4)),
    line_spacing: spacing,
  };
}
