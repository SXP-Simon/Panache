//! 2026-10-24：圈号内部数字沿用主手写字体，圈与数字始终作为一个完整字形。
use super::{Glyph, Glyphs};
use crate::{Result, text::Node};
use image::GrayImage;

// 2026-10-24：不等长弧段构成歪椭圆，保留连贯外圈而非正圆或花瓣波纹。
fn handwritten_ring(
    center: (f32, f32),
    width: f32,
    height: f32,
    phase: f32,
    strength: f32,
) -> Vec<(f32, f32)> {
    let curves = [
        [(0.30, 0.02), (0.60, -0.045), (0.94, 0.015), (1.00, 0.34)],
        [(1.00, 0.34), (1.045, 0.63), (0.88, 0.98), (0.60, 1.00)],
        [(0.60, 1.00), (0.29, 1.015), (0.06, 0.88), (0.02, 0.60)],
        [(0.02, 0.60), (-0.04, 0.35), (0.07, 0.105), (0.30, 0.02)],
    ];
    let mut ring = Vec::with_capacity(129);
    let shear = 0.14 + 0.04 * phase.sin();
    for (segment, curve) in curves.into_iter().enumerate() {
        for step in 0..32 {
            let t = step as f32 / 32.;
            let weights = [
                (1. - t).powi(3),
                3. * (1. - t).powi(2) * t,
                3. * (1. - t) * t * t,
                t.powi(3),
            ];
            let (mut x, mut y) = (0., 0.);
            for (weight, point) in weights.into_iter().zip(curve) {
                x += weight * point.0;
                y += weight * point.1;
            }
            let angle = std::f32::consts::TAU * (segment as f32 + t) / 4.;
            x = 0.5 + (x - 0.5) * (1. + 0.025 * phase.sin());
            x += strength * 0.01 * (2. * angle).sin();
            y += strength * 0.008 * angle.sin();
            ring.push((
                center.0 + width * (x - 0.5) + height * shear * (0.5 - y),
                center.1 + height * (y - 0.5),
            ));
        }
    }
    ring.push(ring[0]);
    ring
}

pub(super) fn number(c: char) -> Option<u32> {
    match c as u32 {
        0x24ea => Some(0),
        0x2460..=0x2473 => Some(c as u32 - 0x2460 + 1),
        0x3251..=0x325f => Some(c as u32 - 0x3251 + 21),
        0x32b1..=0x32bf => Some(c as u32 - 0x32b1 + 36),
        _ => None,
    }
}

impl Glyphs<'_> {
    pub(super) fn circled(&mut self, c: char, size: f32) -> Result<Option<Glyph>> {
        let Some(value) = number(c) else {
            return Ok(None);
        };
        let font = self.book.primary();
        if font.lookup_glyph_index(c) != 0 {
            let (m, data) = font.rasterize(c, size);
            // 2026-10-24：原生圈号优先；只有空字形或与缺字占位相同的墨迹才补绘。
            let (_, missing) = font.rasterize_indexed(0, size);
            if data.iter().any(|alpha| *alpha >= 128) && data != missing {
                return Ok(Some(Self::trim(Glyph {
                    mask: GrayImage::from_raw(m.width as u32, m.height as u32, data).unwrap(),
                    advance: m.advance_width.max((m.xmin + m.width as i32) as f32),
                    left: m.xmin,
                    top: -(m.height as i32) - m.ymin,
                    ink: true,
                })));
            }
        }
        self.fallback_circled(value, size).map(Some)
    }
    fn fallback_circled(&mut self, value: u32, size: f32) -> Result<Glyph> {
        let reference = self.glyph('0', size)?;
        let height = (size * 0.80)
            .max(reference.mask.height() as f32 * 1.16)
            .min(size * 0.94)
            .max(12.);
        let width = height * 1.20;
        let center = (width / 2., (reference.top + reference.bottom()) as f32 / 2.);
        let inner_size = size * if value < 10 { 0.64 } else { 0.52 };
        let nodes: Vec<_> = value.to_string().chars().map(Node::Char).collect();
        let digits = self
            .sequence(&nodes, inner_size.max(32.))?
            .fit(width * 0.52, height * 0.55);
        let x = (center.0 - digits.mask.width() as f32 / 2.).round() as i32 - digits.left;
        let y = (center.1 - digits.mask.height() as f32 / 2.).round() as i32 - digits.top;
        let phase = value as f32 * 0.71 + (self.pen.seed % 13) as f32 * 0.17;
        let ring = handwritten_ring(center, width, height, phase, self.pen.naturalness);
        let advance = width + size * 0.09;
        let outline = self.pen.draw(size, advance, &[ring])?;
        Self::compose(advance, vec![(outline, 0, 0), (digits, x, y)], vec![])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FontBook, Parameters};
    use std::{
        collections::{HashSet, VecDeque},
        path::PathBuf,
    };
    fn chars() -> Vec<char> {
        ['⓪']
            .into_iter()
            .chain(('①'..='⑳').chain('㉑'..='㉟').chain('㊱'..='㊿'))
            .collect()
    }
    #[test]
    fn fallback_outline_remains_visibly_oval_without_naturalness() {
        for value in 0..=50 {
            let ring = handwritten_ring((60., 50.), 120., 100., value as f32 * 0.71, 0.);
            assert_eq!(ring.first(), ring.last());
            let n = ring.len() as f32;
            let cx = ring.iter().map(|p| p.0).sum::<f32>() / n;
            let cy = ring.iter().map(|p| p.1).sum::<f32>() / n;
            let xx = ring.iter().map(|p| (p.0 - cx).powi(2)).sum::<f32>() / n;
            let yy = ring.iter().map(|p| (p.1 - cy).powi(2)).sum::<f32>() / n;
            let xy = ring.iter().map(|p| (p.0 - cx) * (p.1 - cy)).sum::<f32>() / n;
            let difference = ((xx - yy).powi(2) + 4. * xy * xy).sqrt();
            let ratio = ((xx + yy + difference) / (xx + yy - difference)).sqrt();
            assert!(ratio > 1.18, "{value}: outline is too circular ({ratio})");
        }
    }
    fn region(g: &Glyph, start: (u32, u32), ink: bool) -> HashSet<(u32, u32)> {
        let mut seen = HashSet::from([start]);
        let mut queue = VecDeque::from([start]);
        while let Some((x, y)) = queue.pop_front() {
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                if xx >= 0
                    && yy >= 0
                    && xx < g.mask.width() as i32
                    && yy < g.mask.height() as i32
                    && (g.mask[(xx as u32, yy as u32)][0] >= 128) == ink
                    && seen.insert((xx as u32, yy as u32))
                {
                    queue.push_back((xx as u32, yy as u32));
                }
            }
        }
        seen
    }
    #[test]
    fn unicode_circle_ranges_map_exactly_to_zero_through_fifty() {
        assert_eq!(
            chars()
                .into_iter()
                .map(|c| number(c).unwrap())
                .collect::<Vec<_>>(),
            (0..=50).collect::<Vec<_>>()
        );
        for c in ['0', '1', 'ⓐ', '❶', '㊀'] {
            assert_eq!(number(c), None);
        }
        for c in chars() {
            assert!(
                !super::super::super::units::keeps_grid_cell(&[Node::Char(c)]),
                "圈号必须按真实字宽步进：{c}"
            );
        }
    }
    #[test]
    fn primary_circle_ink_is_preserved_and_only_missing_characters_are_synthesized() {
        for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
            let book = FontBook::new(
                &std::fs::read(
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join(format!("../../assets/font_assets/{name}.ttf")),
                )
                .unwrap(),
                &[],
            )
            .unwrap();
            let mut gs = Glyphs::new(&book);
            for size in [18., 36., 72., 124.] {
                for c in '①'..='⑥' {
                    let (m, data) = book.primary().rasterize(c, size);
                    assert_ne!(book.primary().lookup_glyph_index(c), 0);
                    let expected = Glyphs::trim(Glyph {
                        mask: GrayImage::from_raw(m.width as u32, m.height as u32, data).unwrap(),
                        advance: m.advance_width.max((m.xmin + m.width as i32) as f32),
                        left: m.xmin,
                        top: -(m.height as i32) - m.ymin,
                        ink: true,
                    });
                    let actual = gs.glyph(c, size).unwrap();
                    assert_eq!(
                        actual.mask, expected.mask,
                        "{name} {c}/{size}: native strokes changed"
                    );
                    assert_eq!(
                        (actual.left, actual.top, actual.advance),
                        (expected.left, expected.top, expected.advance)
                    );
                }
                if ["云烟体", "华阳手写体"].contains(&name) {
                    for c in ['⓪', '㉑', '㊿'] {
                        assert_eq!(book.primary().lookup_glyph_index(c), 0);
                        assert_eq!(
                            gs.glyph(c, size).unwrap().mask,
                            gs.fallback_circled(number(c).unwrap(), size).unwrap().mask
                        );
                    }
                }
            }
        }
    }
    #[test]
    fn circled_digits_stay_separate_inside_closed_handwritten_rings() {
        for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
            let book = FontBook::new(
                &std::fs::read(
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join(format!("../../assets/font_assets/{name}.ttf")),
                )
                .unwrap(),
                &[],
            )
            .unwrap();
            for size in [18., 36., 72., 124.] {
                for strength in [0., 0.4, 1.] {
                    let p = Parameters {
                        perturb_x_sigma: strength * 3.,
                        perturb_y_sigma: strength * 3.,
                        perturb_theta_sigma: strength * 0.05,
                        ..Parameters::default()
                    };
                    let mut gs = Glyphs::with_parameters(&book, &p);
                    for c in ['⓪', '①', '⑧', '⑩', '⑪', '⑳', '㉑', '㉟', '㊱', '㊿']
                    {
                        let g = gs.fallback_circled(number(c).unwrap(), size).unwrap();
                        assert!(g.advance >= g.right() as f32);
                        assert!(
                            (g.mask.width() as f32) < size * 1.30,
                            "{name} {c}/{size}: oversized ring"
                        );
                        let edge = g
                            .mask
                            .enumerate_pixels()
                            .filter(|(_, _, p)| p[0] >= 128)
                            .min_by_key(|(x, _, _)| *x)
                            .map(|(x, y, _)| (x, y))
                            .unwrap();
                        let ring = region(&g, edge, true);
                        assert!(
                            ring.iter().any(|(_, y)| *y <= 2),
                            "{name} {c}/{size}: ring must close around top"
                        );
                        assert!(
                            ring.iter().any(|(_, y)| *y >= g.mask.height() - 3),
                            "{name} {c}/{size}: ring must close around bottom"
                        );
                        let inner: Vec<_> = g
                            .mask
                            .enumerate_pixels()
                            .filter(|(x, y, p)| p[0] >= 128 && !ring.contains(&(*x, *y)))
                            .collect();
                        assert!(
                            !inner.is_empty(),
                            "{name} {c}/{size}: digits must not touch their ring"
                        );
                        // 外部白色洪泛不得进入数字附近的空白，验证轮廓确实闭合。
                        let outside = region(&g, (0, 0), false);
                        assert!(inner.iter().all(|(x, y, _)| !outside.contains(&(*x, *y))));
                        let center = (g.mask.width() / 2, g.mask.height() / 2);
                        let internal_air = (center.0, (g.mask.height() as f32 * 0.79) as u32);
                        assert!(
                            !outside.contains(&internal_air),
                            "{name} {c}/{size}: circle has a gap"
                        );
                        assert_eq!(
                            g.mask,
                            gs.fallback_circled(number(c).unwrap(), size).unwrap().mask
                        );
                    }
                }
            }
        }
    }
}
