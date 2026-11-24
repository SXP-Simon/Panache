//! Vertical placement of buffered ink, including formulas spanning multiple paper rulings.
use super::LineUnit;
use crate::{LayoutStyle, Parameters};
use image::GrayImage;

pub(super) struct LineLayout {
    top: f32,
    bottom: f32,
    gap: f32,
    spacing: f32,
    ruled: bool,
    min_y: i32,
    max_y: i32,
}

impl LineLayout {
    pub(super) fn fit(units: &mut [LineUnit], p: &Parameters, page_height: u32) -> Self {
        let top = p.top_margin;
        let bottom = page_height as f32 - p.bottom_margin;
        let available = (bottom - top).max(1.);
        let ruled = ((p.underlined || p.paper_pattern.is_some()) && p.width.is_some())
            || p.background_ruled;
        let mut gap = (p.font_size * 0.12).round().max(2.);
        let (mut min_y, mut max_y) = ink_bounds(units);
        if (max_y - min_y) as f32 > available {
            let factor = available / (max_y - min_y) as f32;
            scale_units(units, min_y, factor, f32::floor);
            (min_y, max_y) = ink_bounds(units);
        }
        if ruled && p.layout_style == LayoutStyle::Standard {
            gap = gap.min((p.line_spacing - p.font_size).max(2.));
            let height = (p.line_spacing - gap).floor() as i32;
            let descent = (p.font_size * 0.30).round() as i32;
            if fit_standard_ruled_row(units, min_y, max_y, height, descent) {
                (min_y, max_y) = ink_bounds(units);
            }
        }
        Self {
            top,
            bottom,
            gap,
            spacing: p.line_spacing,
            ruled,
            min_y,
            max_y,
        }
    }

    pub(super) fn baseline(&self, cursor: f32, previous_bottom: Option<f32>) -> f32 {
        let mut anchor = cursor.max(self.top - self.min_y as f32);
        if let Some(bottom) = previous_bottom {
            anchor = anchor.max(bottom + self.gap - self.min_y as f32);
        }
        if self.ruled {
            // A tall formula can span several rows. The following baseline stays on the paper grid.
            self.top
                + (((anchor - self.top) / self.spacing) - 0.00001)
                    .ceil()
                    .max(1.)
                    * self.spacing
        } else {
            anchor
        }
    }

    pub(super) fn ink_bottom(&self, anchor: f32) -> f32 {
        anchor + self.max_y as f32
    }

    pub(super) fn overflows(&self, anchor: f32) -> bool {
        self.ink_bottom(anchor) > self.bottom
    }

    pub(super) fn fit_empty_page(&mut self, units: &mut [LineUnit]) -> f32 {
        if !self.ruled {
            return self.bottom - self.max_y as f32;
        }
        // Use the first ruling that allows the largest scale on an otherwise empty page.
        let mut best = (0f32, self.top + self.spacing);
        for row in 1usize.. {
            let baseline = self.top + row as f32 * self.spacing;
            if baseline >= self.bottom {
                break;
            }
            let above = if self.min_y < 0 {
                ((baseline - self.top - 1.) / -(self.min_y as f32)).max(0.)
            } else {
                1.
            };
            let below = if self.max_y > 0 {
                ((self.bottom - baseline - 1.) / self.max_y as f32).max(0.)
            } else {
                1.
            };
            let factor = above.min(below).min(1.);
            if factor > best.0 {
                best = (factor, baseline);
            }
        }
        scale_units(units, 0, best.0, f32::round);
        (self.min_y, self.max_y) = ink_bounds(units);
        best.1
    }
}

fn ink_bounds(units: &[LineUnit]) -> (i32, i32) {
    units
        .iter()
        .filter(|unit| unit.glyph.ink)
        .map(|unit| (unit.glyph.top + unit.dy, unit.glyph.bottom() + unit.dy))
        .reduce(|(top, bottom), (next_top, next_bottom)| {
            (top.min(next_top), bottom.max(next_bottom))
        })
        .unwrap_or((0, 0))
}

// Page-height fitting starts at the visible top; fitting to a ruling preserves the baseline.
fn scale_units(units: &mut [LineUnit], origin: i32, factor: f32, round: fn(f32) -> f32) {
    for unit in units {
        let offset = unit.glyph.top + unit.dy - origin;
        let width = unit.glyph.mask.width() as f32 * factor;
        let height = (unit.glyph.mask.height() as f32 * factor).max(1.);
        unit.glyph.fit_in_place(width, height);
        unit.dy = round(offset as f32 * factor) as i32 - unit.glyph.top;
    }
}

fn fit_standard_ruled_row(
    units: &mut [LineUnit],
    min_y: i32,
    max_y: i32,
    height: i32,
    descent: i32,
) -> bool {
    let ink_height = max_y - min_y;
    let top = descent - height;
    if height <= 0
        || ink_height <= 0
        || ink_height as f32 > height as f32 * 1.2
        || (min_y >= top && max_y <= descent)
    {
        return false;
    }
    // 2026-11-17：轻微越界先在同一行格内纵向适配，保留横向字距和高公式的跨行避让。
    let fit_height = height.min(ink_height);
    let start = min_y.clamp(top, descent - fit_height);
    for unit in units.iter_mut().filter(|unit| unit.glyph.ink) {
        let offset = unit.glyph.top + unit.dy - min_y;
        let end = offset + unit.glyph.mask.height() as i32;
        let first = offset * fit_height / ink_height;
        let last = (end * fit_height + ink_height - 1) / ink_height;
        let new_height = (last - first) as u32;
        if new_height != unit.glyph.mask.height() {
            let mut mask = GrayImage::new(unit.glyph.mask.width(), new_height);
            // 2026-11-17：合并缩小后落在同一行的像素，保留分数线等细笔画。
            for (x, y, pixel) in unit.glyph.mask.enumerate_pixels() {
                let row = (y * new_height) / unit.glyph.mask.height();
                mask[(x, row)][0] = mask[(x, row)][0].max(pixel[0]);
            }
            unit.glyph.mask = mask;
        }
        unit.dy = start + first - unit.glyph.top;
    }
    true
}
