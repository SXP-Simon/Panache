//! 2026-10-24：根钩沿主字体的起笔/转折比例绘制，正文、根指数及顶线覆盖坐标保持不变。
use super::{Glyph, Glyphs};
use crate::Result;

pub(super) struct RootShape {
    start_y: f32,
    lead_y: f32,
    foot_x: f32,
}
impl RootShape {
    pub fn sample(font: &fontdue::Font) -> Self {
        let fallback = Self {
            start_y: 0.66,
            lead_y: 0.57,
            foot_x: 0.40,
        };
        if font.lookup_glyph_index('√') == 0 {
            return fallback;
        }
        let (m, data) = font.rasterize('√', 96.);
        if m.width < 8 || m.height < 12 {
            return fallback;
        }
        let ink: Vec<_> = data
            .iter()
            .enumerate()
            .filter(|(_, p)| **p >= 128)
            .map(|(i, _)| ((i % m.width) as f32, (i / m.width) as f32))
            .collect();
        if ink.len() < 8 {
            return fallback;
        }
        let min_x = ink.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
        let max_y = ink.iter().map(|p| p.1).fold(0., f32::max);
        // 多数手写字库的√只有钩部，并不自带顶线；从上升臂最高点取得接点。
        let roof_y = ink.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
        let upper: Vec<_> = ink.iter().filter(|p| p.1 <= roof_y + 1.).collect();
        let roof_x = upper.iter().map(|p| p.0).sum::<f32>() / upper.len() as f32;
        if max_y - roof_y < 8. || roof_x - min_x < 4. {
            return fallback;
        }
        let left: Vec<_> = ink.iter().filter(|p| p.0 <= min_x + 1.).collect();
        let start_y = left.iter().map(|p| p.1).sum::<f32>() / left.len() as f32;
        let lowest: Vec<_> = ink.iter().filter(|p| p.1 >= max_y - 1.).collect();
        let foot = lowest.iter().map(|p| p.0).sum::<f32>() / lowest.len() as f32;
        let lead_x = min_x + (foot - min_x) * 0.45;
        let lead_y = ink
            .iter()
            .filter(|p| (p.0 - lead_x).abs() <= 1.5)
            .map(|p| p.1)
            .fold(start_y, f32::min);
        Self {
            start_y: ((start_y - roof_y) / (max_y - roof_y)).clamp(0.45, 0.83),
            lead_y: ((lead_y - roof_y) / (max_y - roof_y)).clamp(0.42, 0.82),
            foot_x: ((foot - min_x) / (roof_x - min_x)).clamp(0.26, 0.60),
        }
    }
}
impl Glyphs<'_> {
    pub(super) fn radical_stroke(
        &self,
        size: f32,
        offset: i32,
        stem: i32,
        top: i32,
        bottom: i32,
        right: i32,
    ) -> Result<Glyph> {
        let h = (bottom - top) as f32;
        let width = (stem - 3) as f32;
        let origin = (offset + 1) as f32;
        let shape = &self.pen.root;
        let start = (origin, top as f32 + h * shape.start_y);
        let foot = (origin + width * shape.foot_x, bottom as f32 - 1.);
        let control = (
            origin + width * shape.foot_x * 0.45,
            top as f32 + h * shape.lead_y,
        );
        let join = ((offset + stem - 2) as f32, top as f32);
        let mut points = Vec::new();
        for i in 0..=24 {
            let t = i as f32 / 24.;
            let u = 1. - t;
            points.push((
                u * u * start.0 + 2. * u * t * control.0 + t * t * foot.0,
                u * u * start.1 + 2. * u * t * control.1 + t * t * foot.1,
            ));
        }
        // 上升臂在原字体比例内柔和展开，两个端点仍固定在根底与顶线接点。
        let a = (foot.0 + width * 0.12, foot.1 - h * 0.18);
        let b = (join.0 - width * 0.13, join.1);
        for i in 1..=32 {
            let t = i as f32 / 32.;
            let u = 1. - t;
            points.push((
                u * u * u * foot.0
                    + 3. * u * u * t * a.0
                    + 3. * u * t * t * b.0
                    + t * t * t * join.0,
                u * u * u * foot.1
                    + 3. * u * u * t * a.1
                    + 3. * u * t * t * b.1
                    + t * t * t * join.1,
            ));
        }
        points.push((right as f32, top as f32));
        self.pen.draw(size, right as f32 + size * 0.08, &[points])
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
    #[test]
    fn sampled_root_hooks_follow_fonts_and_keep_one_connected_roof_at_all_heights() {
        let mut profiles = HashSet::new();
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
            let profile = RootShape::sample(book.primary());
            profiles.insert((
                (profile.start_y * 1000.).round() as i32,
                (profile.foot_x * 1000.).round() as i32,
            ));
            for size in [18_f32, 36., 72., 124.] {
                for factor in [0.8, 1.5, 3.] {
                    let top = -(size * factor) as i32;
                    let stem = (size * 0.46).round().max(10.) as i32;
                    for strength in [0., 1.] {
                        let gs = Glyphs::with_parameters(
                            &book,
                            &Parameters {
                                perturb_x_sigma: strength * 3.,
                                perturb_y_sigma: strength * 3.,
                                perturb_theta_sigma: strength * 0.05,
                                ..Parameters::default()
                            },
                        );
                        let g = gs
                            .radical_stroke(size, 4, stem, top, 0, stem + size as i32 * 4)
                            .unwrap();
                        let ink: HashSet<_> = g
                            .mask
                            .enumerate_pixels()
                            .filter(|(_, _, p)| p[0] >= 128)
                            .map(|(x, y, _)| (x, y))
                            .collect();
                        let start = *ink.iter().next().unwrap();
                        let mut seen = HashSet::from([start]);
                        let mut queue = VecDeque::from([start]);
                        while let Some((x, y)) = queue.pop_front() {
                            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                                let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                                if xx >= 0
                                    && yy >= 0
                                    && ink.contains(&(xx as u32, yy as u32))
                                    && seen.insert((xx as u32, yy as u32))
                                {
                                    queue.push_back((xx as u32, yy as u32));
                                }
                            }
                        }
                        assert_eq!(
                            ink.len(),
                            seen.len(),
                            "{name} root disconnect at {size}/{factor}/{strength}"
                        );
                        let join = ((4 + stem - 2 - g.left) as u32, (top - g.top) as u32);
                        assert!(g.mask[join][0] >= 128, "root and roof must meet exactly");
                        assert!(g.advance >= g.right() as f32);
                    }
                }
            }
        }
        assert!(
            profiles.len() >= 2,
            "native root proportions must not collapse to one geometric template"
        );
    }
}
