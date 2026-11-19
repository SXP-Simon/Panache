export type PaperArea = { left: number; first: number; right: number; last: number };
export type PaperSize = { width: number; height: number };

export function paperAreaLayout(area: PaperArea, size: PaperSize, rows: number, enclosed = false) {
  if (!Number.isInteger(rows) || rows < 2 || rows > 500) return null;
  const spacing = enclosed
    ? Math.floor((Math.floor(area.last) - Math.ceil(area.first)) / (rows + 0.25))
    : Math.round((area.last - area.first) / (rows - 1));
  const top = enclosed ? Math.ceil(area.first) : Math.round(area.first) - spacing;
  const bottom = top + spacing * rows;
  const left = enclosed ? Math.ceil(area.left) : Math.round(area.left);
  const right = size.width - (enclosed ? Math.floor(area.right) : Math.round(area.right));
  if (spacing < 8 || top < 0 || bottom >= size.height || size.width - left - right < 8) return null;
  return {
    left_margin: left,
    right_margin: right,
    top_margin: top,
    bottom_margin: Math.max(0, size.height - bottom - Math.ceil(spacing / 4)),
    line_spacing: spacing,
  };
}
