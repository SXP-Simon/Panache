import type { Adjustment, Adjustments, FinePage, Glyph } from './fineEditModel';
import { filterInk } from '@/utils/inkEffects';
import { affineCorners, inverseWarp, mapPoint, warpFits } from './fineTransform';
import type { InkShape } from '@/utils/inkEffects';

export interface Bounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

export function pose(glyph: Glyph, edit?: Adjustment) {
  const [, x, y, width, height] = glyph;
  const radians = ((edit?.angle ?? 0) * Math.PI) / 180;
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  const scale = (edit?.scale ?? 100) / 100;
  const cx = x + width / 2 + (edit?.dx ?? 0);
  const cy = y + height / 2 + (edit?.dy ?? 0);
  const rx = (scale * (Math.abs(cos) * width + Math.abs(sin) * height)) / 2;
  const ry = (scale * (Math.abs(sin) * width + Math.abs(cos) * height)) / 2;
  const warp = edit?.warp;
  if (warp) {
    const corners = affineCorners(width, height, scale, cos, sin);
    if (warpFits(warp, corners)) {
      const matrix = [...warp, 1] as const;
      const points = corners.map(({ x, y }) => mapPoint(matrix, x, y));
      const center = mapPoint(matrix, 0, 0);
      return {
        cx,
        cy,
        centerX: cx + center.x,
        centerY: cy + center.y,
        cos,
        sin,
        scale,
        inverse: inverseWarp(warp),
        left: cx + Math.min(...points.map((point) => point.x)),
        right: cx + Math.max(...points.map((point) => point.x)),
        top: cy + Math.min(...points.map((point) => point.y)),
        bottom: cy + Math.max(...points.map((point) => point.y)),
      };
    }
  }
  return {
    cx,
    cy,
    centerX: cx,
    centerY: cy,
    cos,
    sin,
    scale,
    inverse: undefined,
    left: cx - rx,
    top: cy - ry,
    right: cx + rx,
    bottom: cy + ry,
  };
}

export function hitGlyph(
  glyph: Glyph,
  edit: Adjustment | undefined,
  point: { x: number; y: number },
  slop: number,
) {
  const { cx, cy, cos, sin, scale, left, top, right, bottom, inverse } = pose(glyph, edit);
  if (
    point.x < left - slop ||
    point.x > right + slop ||
    point.y < top - slop ||
    point.y > bottom + slop
  )
    return false;
  if (!inverse) return true;
  const { x, y } = mapPoint(inverse, point.x - cx, point.y - cy);
  return (
    Math.abs(x * cos + y * sin) <= (glyph[3] * scale) / 2 + slop &&
    Math.abs(-x * sin + y * cos) <= (glyph[4] * scale) / 2 + slop
  );
}

export function overlaps(a: Bounds, b: Bounds) {
  return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
}

export function union(a: Bounds, b: Bounds): Bounds {
  return {
    left: Math.min(a.left, b.left),
    top: Math.min(a.top, b.top),
    right: Math.max(a.right, b.right),
    bottom: Math.max(a.bottom, b.bottom),
  };
}

type Rgb = [number, number, number];
export type FineInk = InkShape & { color: string; opacity: number };
type MaskPair = [Uint8Array, Uint8Array];
type FilteredGlyph = { thickness: number; softness: number; masks: MaskPair };
function rgb(hex: string): Rgb {
  const n = Number.parseInt(hex.slice(1), 16);
  return [Math.floor(n / 65536), Math.floor(n / 256) % 256, n % 256];
}

function drawGlyph(
  target: ImageData,
  masks: MaskPair,
  glyph: Glyph,
  colors: [Rgb, Rgb],
  dirty: Bounds,
  edit?: Adjustment,
) {
  const [, , , width, height] = glyph;
  const { cx, cy, cos, sin, scale, inverse, left, top, right, bottom } = pose(glyph, edit);
  const override = edit?.color ? rgb(edit.color) : null;
  const opacity = edit?.opacity ?? 100;
  const pixels = target.data;
  const epsilon = 1e-9; // Matches the backend at integer sample boundaries.
  const startX = Math.max(dirty.left, Math.floor(left));
  const endX = Math.min(dirty.right, Math.ceil(right));
  for (
    let y = Math.max(dirty.top, Math.floor(top));
    y < Math.min(dirty.bottom, Math.ceil(bottom));
    y += 1
  ) {
    for (let x = startX; x < endX; x += 1) {
      let dx = x + 0.5 - cx,
        dy = y + 0.5 - cy;
      if (inverse) ({ x: dx, y: dy } = mapPoint(inverse, dx, dy));
      const sx = Math.floor((dx * cos + dy * sin) / scale + width / 2 + epsilon);
      const sy = Math.floor((-dx * sin + dy * cos) / scale + height / 2 + epsilon);
      if (!(sx >= 0 && sy >= 0 && sx < width && sy < height)) continue;
      const source = sy * width + sx;
      const offset = (y * target.width + x) * 4;
      for (const channel of [0, 1] as const) {
        const alpha = Math.floor(((masks[channel][source] ?? 0) * opacity + 50) / 100);
        if (alpha === 0) continue;
        const color = override ?? colors[channel];
        for (const component of [0, 1, 2] as const) {
          const index = offset + component;
          pixels[index] = Math.floor(
            (color[component] * alpha + (pixels[index] ?? 0) * (255 - alpha) + 127) / 255,
          );
        }
      }
    }
  }
}

export class FineRaster {
  private previous: Adjustments | null = null;
  private readonly image: ImageData;
  private readonly paper: ImageData;
  private readonly atlas: ImageData;
  private readonly filtered = new Map<number, FilteredGlyph>();
  private styles: [FineInk, FineInk] | null = null;
  private readonly context: CanvasRenderingContext2D;

  constructor(
    canvas: HTMLCanvasElement,
    paper: HTMLImageElement,
    atlas: HTMLImageElement,
    private readonly page: FinePage,
  ) {
    canvas.width = paper.naturalWidth;
    canvas.height = paper.naturalHeight;
    const context = canvas.getContext('2d', { willReadFrequently: true, alpha: false });
    const atlasCanvas = document.createElement('canvas');
    atlasCanvas.width = atlas.naturalWidth;
    atlasCanvas.height = atlas.naturalHeight;
    const source = atlasCanvas.getContext('2d', { willReadFrequently: true });
    if (!context || !source) throw new Error('Could not open the editing canvas');
    this.context = context;
    context.drawImage(paper, 0, 0);
    this.paper = context.getImageData(0, 0, canvas.width, canvas.height);
    this.image = context.createImageData(canvas.width, canvas.height);
    source.drawImage(atlas, 0, 0);
    this.atlas = source.getImageData(0, 0, atlasCanvas.width, atlasCanvas.height);
  }

  private masks(glyph: Glyph, styles: [FineInk, FineInk], edit?: Adjustment): MaskPair {
    const [id, , , width, height, ax, ay] = glyph;
    const thickness = edit?.thickness ?? 0;
    const softness = edit?.softness ?? 0;
    const previous = this.filtered.get(id);
    if (previous?.thickness === thickness && previous.softness === softness) return previous.masks;
    const channel = (index: 0 | 1) => {
      const input = new Uint8Array(width * height);
      let visible = false;
      for (let y = 0; y < height; y += 1) {
        const row = ((ay + y) * this.atlas.width + ax) * 4 + index;
        for (let x = 0; x < width; x += 1) {
          const alpha = this.atlas.data[row + x * 4] ?? 0;
          input[y * width + x] = alpha;
          visible ||= alpha !== 0;
        }
      }
      const style = styles[index];
      if (!visible) return input;
      const shape = filterInk(input, width, height, {
        thickness: Math.max(-2, Math.min(2, style.thickness + thickness / 10)),
        softness: Math.max(0, Math.min(2, style.softness + softness / 10)),
      });
      return style.opacity === 100
        ? shape
        : shape.map((alpha) => Math.floor((alpha * style.opacity + 50) / 100));
    };
    const masks: MaskPair = [channel(0), channel(1)];
    this.filtered.set(id, { thickness, softness, masks });
    return masks;
  }

  draw(edits: Adjustments, styles: [FineInk, FineInk]) {
    const previous = this.styles;
    const styleChanged = previous !== styles;
    if (edits === this.previous && !styleChanged) return;
    if (styleChanged) {
      if (
        !previous ||
        styles.some((style, index) => {
          const before = previous[index === 0 ? 0 : 1];
          return (
            before.opacity !== style.opacity ||
            before.thickness !== style.thickness ||
            before.softness !== style.softness
          );
        })
      )
        this.filtered.clear();
      this.styles = styles;
    }
    const { width, height, data } = this.image;
    const colors: [Rgb, Rgb] = [rgb(styles[0].color), rgb(styles[1].color)];
    let dirty: Bounds | undefined;
    if (!this.previous || styleChanged) dirty = { left: 0, top: 0, right: width, bottom: height };
    else {
      for (const glyph of this.page.glyphs) {
        const next = edits.get(glyph[0]);
        const previous = this.previous.get(glyph[0]);
        if (next === previous) continue;
        const moved = union(pose(glyph, next), pose(glyph, previous));
        dirty = dirty ? union(dirty, moved) : moved;
      }
    }
    this.previous = edits;
    if (!dirty) return;
    const clip = {
      left: Math.max(0, Math.floor(dirty.left)),
      top: Math.max(0, Math.floor(dirty.top)),
      right: Math.min(width, Math.ceil(dirty.right)),
      bottom: Math.min(height, Math.ceil(dirty.bottom)),
    };
    if (clip.right <= clip.left || clip.bottom <= clip.top) return;
    for (let y = clip.top; y < clip.bottom; y += 1) {
      const from = (y * width + clip.left) * 4;
      const end = (y * width + clip.right) * 4;
      data.set(this.paper.data.subarray(from, end), from);
    }
    for (const glyph of this.page.glyphs) {
      const edit = edits.get(glyph[0]);
      if (overlaps(pose(glyph, edit), clip))
        drawGlyph(this.image, this.masks(glyph, styles, edit), glyph, colors, clip, edit);
    }
    this.context.putImageData(
      this.image,
      0,
      0,
      clip.left,
      clip.top,
      clip.right - clip.left,
      clip.bottom - clip.top,
    );
  }

  png(edits: Adjustments, styles: [FineInk, FineInk]): Promise<Blob> {
    this.draw(edits, styles);
    return new Promise((resolve, reject) => {
      this.context.canvas.toBlob(
        (image) => (image ? resolve(image) : reject(new Error('Could not encode the preview'))),
        'image/png',
      );
    });
  }
}
