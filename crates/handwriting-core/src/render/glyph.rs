//! 2026-10-15：测量与绘制共享基线坐标和真实墨迹边界；复合数学结构不依赖私用区字符。
use super::{FontBook, paste_mask};
use crate::{Error, Parameters, Result, text::Node};
use image::{GrayImage, Luma};
use std::collections::HashMap;

#[derive(Clone)]
pub(super) struct Glyph {
    pub mask: GrayImage,
    pub advance: f32,
    pub left: i32,
    pub top: i32,
    pub ink: bool,
}
impl Glyph {
    pub fn right(&self) -> i32 {
        self.left + self.mask.width() as i32
    }
    pub fn bottom(&self) -> i32 {
        self.top + self.mask.height() as i32
    }
    pub fn empty(advance: f32) -> Self {
        Self {
            mask: GrayImage::new(1, 1),
            advance,
            left: 0,
            top: 0,
            ink: false,
        }
    }
    pub(super) fn compact(mut self, size: f32) -> Self {
        self.left = 0;
        self.advance = if self.ink {
            self.mask.width() as f32 + (size * 0.045).round().max(1.)
        } else {
            (size * 0.25).round().max(1.)
        };
        self
    }
    pub(super) fn step(&self, unit: &[Node], p: &Parameters, extra: f32, compound: bool) -> f32 {
        if p.grid_layout && super::units::keeps_grid_cell(unit) {
            (p.font_size + p.word_spacing).max(1.)
        } else {
            let step = self.advance + p.word_spacing + extra;
            if compound {
                step.max(self.right() as f32).max(1.)
            } else {
                step.max(1.)
            }
        }
    }
    pub fn fit(mut self, width: f32, height: f32) -> Self {
        let footprint = self.advance.max(self.right() as f32) - self.left.min(0) as f32;
        let ratio = (width / footprint.max(1.))
            .min(height / self.mask.height() as f32)
            .min(1.);
        if ratio < 1. {
            let width = (self.mask.width() as f32 * ratio).floor().max(1.) as u32;
            let height = (self.mask.height() as f32 * ratio).floor().max(1.) as u32;
            let mut resized = GrayImage::new(width, height);
            // 2026-10-15：缩小时保留每一条墨迹，不能把单像素根顶/分数线平均成阈值以下而整式消失。
            for (x, y, p) in self.mask.enumerate_pixels() {
                let xx = (u64::from(x) * u64::from(width) / u64::from(self.mask.width())) as u32;
                let yy = (u64::from(y) * u64::from(height) / u64::from(self.mask.height())) as u32;
                resized[(xx, yy)][0] = resized[(xx, yy)][0].max(p[0]);
            }
            self.mask = resized;
            self.left = (self.left as f32 * ratio).floor() as i32;
            self.top = (self.top as f32 * ratio).floor() as i32;
            self.advance = (self.advance * ratio).floor().max(1.);
        }
        self
    }
}
pub(super) struct Glyphs<'a> {
    pub book: &'a FontBook,
    cache: HashMap<(char, u32), Glyph>,
    cache_bytes: usize,
}
type Path = (Vec<(i32, i32)>, i32);
impl<'a> Glyphs<'a> {
    pub fn new(book: &'a FontBook) -> Self {
        Self {
            book,
            cache: HashMap::new(),
            cache_bytes: 0,
        }
    }
    pub fn glyph(&mut self, c: char, size: f32) -> Result<Glyph> {
        let size = size.clamp(1., 2048.).round();
        let key = (c, size as u32);
        if let Some(g) = self.cache.get(&key) {
            return Ok(g.clone());
        }
        let (m, data) = self.book.for_char(c).rasterize(c, size);
        let advance = m.advance_width.max((m.xmin + m.width as i32) as f32);
        let mut glyph = if m.width == 0 || m.height == 0 {
            Glyph::empty(advance)
        } else {
            Self::check_size(m.width as u32, m.height as u32)?;
            Glyph {
                mask: GrayImage::from_raw(m.width as u32, m.height as u32, data).unwrap(),
                advance,
                left: m.xmin,
                top: -(m.height as i32) - m.ymin,
                ink: true,
            }
        };
        // 2026-10-15：裁去栅格化器的空白外缘，避免间距由透明 padding 决定。
        if glyph.ink {
            glyph = Self::trim(glyph);
        }
        if self.cache.len() >= 1024 || self.cache_bytes + glyph.mask.len() > 8 * 1024 * 1024 {
            self.cache.clear();
            self.cache_bytes = 0;
        }
        self.cache_bytes += glyph.mask.len();
        self.cache.insert(key, glyph.clone());
        Ok(glyph)
    }
    fn trim(mut g: Glyph) -> Glyph {
        let mut bounds = (g.mask.width(), g.mask.height(), 0, 0);
        for (x, y, p) in g.mask.enumerate_pixels() {
            if p[0] > 0 {
                bounds.0 = bounds.0.min(x);
                bounds.1 = bounds.1.min(y);
                bounds.2 = bounds.2.max(x + 1);
                bounds.3 = bounds.3.max(y + 1);
            }
        }
        if bounds.2 == 0 {
            return Glyph::empty(g.advance);
        }
        g.mask = image::imageops::crop_imm(
            &g.mask,
            bounds.0,
            bounds.1,
            bounds.2 - bounds.0,
            bounds.3 - bounds.1,
        )
        .to_image();
        g.left += bounds.0 as i32;
        g.top += bounds.1 as i32;
        g
    }
    fn check_size(w: u32, h: u32) -> Result<()> {
        if w > 32768 || h > 8192 || u64::from(w) * u64::from(h) > 16_000_000 {
            Err(Error::new("invalid_layout", "数学结构超过安全栅格化预算"))
        } else {
            Ok(())
        }
    }
    pub(super) fn compose(
        advance: f32,
        children: Vec<(Glyph, i32, i32)>,
        paths: Vec<Path>,
    ) -> Result<Glyph> {
        let mut bounds: Option<(i32, i32, i32, i32)> = None;
        let mut include = |b: (i32, i32, i32, i32)| {
            bounds = Some(match bounds {
                None => b,
                Some(a) => (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3)),
            });
        };
        for (g, x, y) in &children {
            if g.ink {
                include((g.left + x, g.top + y, g.right() + x, g.bottom() + y));
            }
        }
        for (points, thickness) in &paths {
            let pad = thickness / 2;
            for &(x, y) in points {
                include((x - pad, y - pad, x + pad + 1, y + pad + 1));
            }
        }
        let Some((left, top, right, bottom)) = bounds else {
            return Ok(Glyph::empty(advance));
        };
        Self::check_size((right - left) as u32, (bottom - top) as u32)?;
        let mut mask = GrayImage::new((right - left) as u32, (bottom - top) as u32);
        for (g, x, y) in children {
            paste_mask(&mut mask, &g.mask, g.left + x - left, g.top + y - top);
        }
        for (points, thickness) in paths {
            for pair in points.windows(2) {
                Self::stroke(
                    &mut mask,
                    (pair[0].0 - left, pair[0].1 - top),
                    (pair[1].0 - left, pair[1].1 - top),
                    thickness,
                );
            }
        }
        Ok(Self::trim(Glyph {
            mask,
            advance: advance.max(right as f32),
            left,
            top,
            ink: true,
        }))
    }
    // 2026-10-15：对角线使用四连通笔画，根钩和顶线在连通域扰动后仍保持连笔。
    fn stroke(mask: &mut GrayImage, a: (i32, i32), b: (i32, i32), thickness: i32) {
        let steps = (b.0 - a.0).abs().max((b.1 - a.1).abs()).max(1);
        let radius = thickness / 2;
        let mut previous = a;
        for step in 0..=steps {
            let t = step as f32 / steps as f32;
            let point = (
                (a.0 as f32 + (b.0 - a.0) as f32 * t).round() as i32,
                (a.1 as f32 + (b.1 - a.1) as f32 * t).round() as i32,
            );
            for center in [point, (point.0, previous.1)] {
                for dy in -radius..=radius {
                    for dx in -radius..=radius {
                        if dx * dx + dy * dy <= radius * radius {
                            let x = center.0 + dx;
                            let y = center.1 + dy;
                            if x >= 0
                                && y >= 0
                                && x < mask.width() as i32
                                && y < mask.height() as i32
                            {
                                mask[(x as u32, y as u32)] = Luma([255]);
                            }
                        }
                    }
                }
            }
            previous = point;
        }
    }
    pub fn unit(&mut self, nodes: &[Node], size: f32) -> Result<Glyph> {
        if nodes.len() == 1 {
            let mut glyph = self.node(&nodes[0], size)?;
            if matches!(nodes[0], Node::Char(_)) && !super::units::keeps_grid_cell(nodes) {
                glyph = glyph.compact(size);
            }
            Ok(glyph)
        } else {
            self.sequence(nodes, size)
        }
    }
    pub fn node(&mut self, n: &Node, size: f32) -> Result<Glyph> {
        self.node_at(n, size, 0)
    }
    fn node_at(&mut self, n: &Node, size: f32, depth: usize) -> Result<Glyph> {
        if depth > 64 {
            return Err(Error::new("invalid_layout", "数学结构嵌套过深"));
        }
        let small = (size * 0.76).round().max(10.).min(size);
        let gap = (size * 0.08).round().max(2.) as i32;
        let thickness = (size * 0.035).round().max(1.) as i32;
        match n {
            Node::Char(c) => self.glyph(*c, size),
            Node::Fraction(num, den) => {
                let a = self.sequence_at(num, small, depth + 1)?;
                let b = self.sequence_at(den, small, depth + 1)?;
                let x = self.glyph('x', size)?;
                let axis = (x.top + x.bottom()) / 2;
                let padding = (size * 0.12).round().max(3.) as i32;
                let width = a.mask.width().max(b.mask.width()) as i32 + padding * 2;
                let ax = (width - a.mask.width() as i32) / 2 - a.left;
                let bx = (width - b.mask.width() as i32) / 2 - b.left;
                let ay = axis - (thickness + 1) / 2 - gap - a.bottom();
                let by = axis + (thickness + 1) / 2 + gap + 1 - b.top;
                Self::compose(
                    (width + padding) as f32,
                    vec![(a, ax, ay), (b, bx, by)],
                    vec![(vec![(1, axis), (width - 1, axis)], thickness)],
                )
            }
            Node::Radical(body, index) => {
                let body = self.sequence_at(body, size, depth + 1)?;
                let gap = (size * 0.09).round().max(2.) as i32;
                let top = body.top - gap;
                let bottom = body.bottom().max(top + (size * 0.58).round() as i32);
                let height = bottom - top;
                let stem = (size * 0.46).round().max(10.) as i32;
                let mut children = Vec::new();
                let mut offset = 0;
                if !index.is_empty() {
                    let idx = self.sequence_at(
                        index,
                        (size * 0.46).round().max(8.).min(size),
                        depth + 1,
                    )?;
                    let idx_y = top + (height as f32 * 0.34).round() as i32 - idx.bottom();
                    offset = (idx.mask.width() as i32 - (size * 0.16).round() as i32).max(0);
                    let idx_x = -idx.left;
                    children.push((idx, idx_x, idx_y));
                }
                let body_x = offset + stem + (size * 0.04).round().max(1.) as i32 - body.left;
                let right = body_x + body.right() + gap;
                children.push((body, body_x, 0));
                let points = vec![
                    (offset + 1, top + (height as f32 * 0.63).round() as i32),
                    (
                        offset + (stem as f32 * 0.20).round() as i32,
                        top + (height as f32 * 0.55).round() as i32,
                    ),
                    (offset + (stem as f32 * 0.43).round() as i32, bottom - 1),
                    (offset + stem - 2, top),
                    (right, top),
                ];
                Self::compose((right + gap) as f32, children, vec![(points, thickness)])
            }
            Node::Scripts { upper, lower } => {
                let base = self.glyph('x', size)?;
                self.scripts(upper, lower, size, &base, depth)
            }
            Node::Accent(nodes, mark) => {
                let body = self.sequence_at(nodes, size, depth + 1)?;
                let mut left = body.left;
                let mut right = body.right() - 1;
                let gap = (size * 0.10).round().max(2.) as i32;
                let mut y = if *mark == '\u{0332}' {
                    body.bottom() + gap
                } else {
                    body.top - gap
                };
                let center = (left + right) / 2;
                let mut paths = Vec::new();
                if "\u{0302}\u{0303}\u{20d7}\u{0306}\u{0301}\u{0300}\u{030c}".contains(*mark) {
                    let extra = ((size * 0.34).round() as i32 - (right - left)).max(0);
                    left -= extra / 2;
                    right += extra - extra / 2;
                }
                match mark {
                    '\u{0302}' => paths.push((
                        vec![
                            (left, y),
                            (center, y - (size * 0.12).round().max(3.) as i32),
                            (right, y),
                        ],
                        thickness,
                    )),
                    '\u{20d7}' => {
                        let arrow = (size * 0.12).round().max(3.) as i32;
                        y -= arrow;
                        paths.push((vec![(left, y), (right, y)], thickness));
                        paths.push((
                            vec![
                                (right - arrow, y - arrow),
                                (right, y),
                                (right - arrow, y + arrow),
                            ],
                            thickness,
                        ));
                    }
                    '\u{0307}' | '\u{0308}' => {
                        let separation = if *mark == '\u{0308}' {
                            (size * 0.10).round().max(2.) as i32
                        } else {
                            0
                        };
                        for x in [center - separation, center + separation] {
                            paths.push((vec![(x, y), (x, y)], (thickness + 1).max(2)));
                        }
                    }
                    '\u{0303}' => paths.push((
                        vec![
                            (left, y),
                            (left + (right - left) / 3, y - 2),
                            (left + (right - left) * 2 / 3, y + 1),
                            (right, y - 1),
                        ],
                        thickness,
                    )),
                    '\u{030c}' => {
                        paths.push((vec![(left, y - 3), (center, y), (right, y - 3)], thickness))
                    }
                    '\u{0306}' => paths.push((
                        vec![
                            (left, y - 3),
                            (left + (right - left) / 3, y),
                            (left + (right - left) * 2 / 3, y),
                            (right, y - 3),
                        ],
                        thickness,
                    )),
                    '\u{0301}' => {
                        paths.push((vec![(center - 2, y), (center + 3, y - 5)], thickness))
                    }
                    '\u{0300}' => {
                        paths.push((vec![(center - 2, y - 5), (center + 3, y)], thickness))
                    }
                    _ => paths.push((vec![(left, y), (right, y)], thickness)),
                }
                Self::compose(body.advance, vec![(body, 0, 0)], paths)
            }
            _ => Ok(Glyph::empty(0.)),
        }
    }
}

mod sequence;
#[cfg(test)]
mod tests;
