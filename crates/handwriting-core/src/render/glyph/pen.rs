//! 2026-10-24：数学连接笔画采样所选主字体；轻微曲线固定端点，不改变公式拓扑。
use super::{Glyph, Glyphs, Path};
use crate::Result;
use image::GrayImage;

pub(super) struct MathPen {
    width: f32,
    axis: f32,
    height: f32,
    slant: f32,
    chevrons: [Option<GrayImage>; 2],
    pub(super) root: super::radical::RootShape,
    pub naturalness: f32,
    pub seed: u64,
}

impl MathPen {
    pub fn sample(font: &fontdue::Font) -> Self {
        let size = 96.;
        let mut widths = Vec::new();
        for c in ['n', 'x', '1', '十', '口'] {
            if font.lookup_glyph_index(c) == 0 {
                continue;
            }
            let (m, data) = font.rasterize(c, size);
            let mut area = 0.;
            let mut perimeter = 0.;
            for y in 0..m.height {
                for x in 0..m.width {
                    if data[y * m.width + x] < 96 {
                        continue;
                    }
                    area += 1.;
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                        if xx < 0
                            || yy < 0
                            || xx >= m.width as i32
                            || yy >= m.height as i32
                            || data[yy as usize * m.width + xx as usize] < 96
                        {
                            perimeter += 1.;
                        }
                    }
                }
            }
            if perimeter > 0. {
                widths.push(2. * area / perimeter / size);
            }
        }
        widths.sort_by(f32::total_cmp);
        let width = widths
            .get(widths.len() / 2)
            .copied()
            .unwrap_or(0.025)
            .clamp(0.009, 0.065);
        let (x, _) = font.rasterize('x', size);
        let height = if x.height > 0 {
            (x.height as f32 / size).clamp(0.30, 0.70)
        } else {
            0.48
        };
        let axis = if x.height > 0 {
            -(x.height as f32 / 2. + x.ymin as f32) / size
        } else {
            -0.27
        };
        let (m, data) = font.rasterize('1', size);
        let mut centers = Vec::new();
        for y in m.height / 3..m.height * 2 / 3 {
            let xs: Vec<_> = (0..m.width)
                .filter(|x| data[y * m.width + x] >= 128)
                .collect();
            if !xs.is_empty() {
                centers.push((y as f32, xs.iter().sum::<usize>() as f32 / xs.len() as f32));
            }
        }
        let slant = if let (Some(a), Some(b)) = (centers.first(), centers.last()) {
            ((a.1 - b.1) / (b.0 - a.0).max(1.)).clamp(-0.12, 0.12)
        } else {
            0.
        };
        Self {
            width,
            axis: axis.clamp(-0.4, -0.16),
            height,
            slant,
            chevrons: ['<', '>'].map(|c| Self::sample_chevron(font, c)),
            root: super::radical::RootShape::sample(font),
            naturalness: 0.,
            seed: 0,
        }
    }
    pub fn thickness(&self, size: f32) -> f32 {
        (self.width * size).max(0.75)
    }
    fn sample_chevron(font: &fontdue::Font, c: char) -> Option<GrayImage> {
        if font.lookup_glyph_index(c) == 0 {
            return None;
        }
        let (m, data) = font.rasterize(c, 96.);
        if m.width < 3 || m.height < 3 {
            return None;
        }
        let g = Glyphs::trim(Glyph {
            mask: GrayImage::from_raw(m.width as u32, m.height as u32, data)?,
            advance: m.advance_width,
            left: 0,
            top: 0,
            ink: true,
        });
        let mask = g.mask;
        let mut bands = [(0., 0.); 3];
        for (x, y, p) in mask.enumerate_pixels() {
            if p[0] >= 96 {
                let band = (y * 3 / mask.height()).min(2) as usize;
                bands[band].0 += x as f32;
                bands[band].1 += 1.;
            }
        }
        if bands.iter().any(|b| b.1 == 0.) {
            return None;
        }
        let outer = (bands[0].0 / bands[0].1 + bands[2].0 / bands[2].1) / 2.;
        let middle = bands[1].0 / bands[1].1;
        let direction = if c == '<' {
            outer - middle
        } else {
            middle - outer
        };
        (direction > mask.width() as f32 * 0.12).then_some(mask)
    }
    fn inequality(&self, c: char, size: f32) -> Result<Option<Glyph>> {
        let Some(source) = &self.chevrons[usize::from(c == '≥')] else {
            return Ok(None);
        };
        let width = (source.width() as f32 * size / 96.).round().max(3.) as u32;
        let height = (source.height() as f32 * size / 96.).round().max(3.) as u32;
        let mut mask =
            image::imageops::resize(source, width, height, image::imageops::FilterType::Triangle);
        // 2026-10-24：缩小字体原笔画时保留墨迹，不能把草写尖角平均成断续小点。
        if size < 96. {
            for (x, y, p) in source.enumerate_pixels() {
                let xx = x * width / source.width();
                let yy = y * height / source.height();
                mask[(xx, yy)][0] = mask[(xx, yy)][0].max(p[0]);
            }
        }
        let gap = (size * 0.06).max(3.);
        let stroke = self.thickness(size);
        let total = height as f32 + gap + stroke;
        let top = (self.axis * size - total / 2.).round() as i32;
        let native = Glyph {
            mask,
            advance: width as f32,
            left: 0,
            top,
            ink: true,
        };
        let y = top as f32 + height as f32 + gap + stroke / 2.;
        let advance = width as f32 + size * 0.08;
        let line = self.draw(
            size,
            advance,
            &[vec![
                (0., y),
                (width as f32 - 1., y - self.slant * size * 0.08),
            ]],
        )?;
        Ok(Some(Glyphs::compose(
            advance,
            vec![(native, 0, 0), (line, 0, 0)],
            vec![],
        )?))
    }

    pub fn symbol(&self, c: char, size: f32) -> Result<Option<Glyph>> {
        if !"¬→←↔⇒⇐⇔≤≥≠".contains(c) {
            return Ok(None);
        }
        if matches!(c, '≤' | '≥')
            && let Some(glyph) = self.inequality(c, size)?
        {
            return Ok(Some(glyph));
        }
        let axis = self.axis * size;
        let h = (self.height * size * 0.33).max(2.5);
        let w = (size * (self.height + 0.18)).max(6.);
        let mut paths: Vec<Vec<(f32, f32)>> = Vec::new();
        let mut width = w;
        match c {
            '¬' => {
                width = w * 0.76;
                paths.push(vec![(0., axis), (width, axis), (width, axis + h * 0.8)]);
            }
            '→' | '←' | '↔' | '⇒' | '⇐' | '⇔' => {
                let double = "⇒⇐⇔".contains(c);
                let left = "←↔⇐⇔".contains(c);
                let right = "→↔⇒⇔".contains(c);
                let head = w * 0.28;
                let separation = (h * 0.42).max(self.thickness(size) + 1.2);
                for y in if double {
                    vec![axis - separation, axis + separation]
                } else {
                    vec![axis]
                } {
                    let inset = if double { head * separation / h } else { 0. };
                    paths.push(vec![
                        (if left { inset } else { 0. }, y),
                        (w - if right { inset } else { 0. }, y),
                    ]);
                }
                if left {
                    paths.push(vec![(head, axis - h), (0., axis), (head, axis + h)]);
                }
                if right {
                    paths.push(vec![(w - head, axis - h), (w, axis), (w - head, axis + h)]);
                }
            }
            '≤' | '≥' => {
                width = w * 0.74;
                let less = "<≤".contains(c);
                let equal = "≤≥".contains(c);
                let center = axis - if equal { h * 0.35 } else { 0. };
                let tip = if less { 0. } else { width };
                let end = width - tip;
                // 2026-10-24：缺字回退也保留不对称收笔，避免理想镜面对称的印刷折角。
                paths.push(vec![
                    (end, center - h * 0.92),
                    (tip, center + h * 0.08),
                    (end - width * 0.04, center + h),
                ]);
                if equal {
                    let bar = center + h + (h * 0.85).max(self.thickness(size) + 2.5);
                    paths.push(vec![(0., bar), (width, bar)]);
                }
            }
            '≠' => {
                width = w * 0.78;
                for y in [axis - h * 0.45, axis + h * 0.45] {
                    paths.push(vec![(0., y), (width, y)]);
                }
                paths.push(vec![
                    (width * 0.2, axis + h * 1.25),
                    (width * 0.8, axis - h * 1.25),
                ]);
            }
            _ => unreachable!(),
        }
        for path in &mut paths {
            for p in path {
                p.0 += (axis - p.1) * self.slant;
            }
        }
        Ok(Some(self.draw(size, width + size * 0.08, &paths)?))
    }

    pub(super) fn draw(&self, size: f32, advance: f32, paths: &[Vec<(f32, f32)>]) -> Result<Glyph> {
        // 2026-10-24：超长公式仍遵守原栅格预算，不因抗锯齿四倍采样提前拒绝。
        let bounds = paths
            .iter()
            .flatten()
            .fold((0f32, 0f32, 0f32, 0f32), |b, p| {
                (b.0.min(p.0), b.1.min(p.1), b.2.max(p.0), b.3.max(p.1))
            });
        let span = (
            bounds.2 - bounds.0 + size * 0.15 + 8.,
            bounds.3 - bounds.1 + size * 0.15 + 8.,
        );
        let scale = if span.0 * 4. <= 32768.
            && span.1 * 4. <= 8192.
            && span.0 * span.1 * 16. <= 16_000_000.
        {
            4
        } else {
            1
        };
        let stroke = self.thickness(size);
        let mut dense = Vec::new();
        for (index, path) in paths.iter().enumerate() {
            let mut points = Vec::new();
            for pair in path.windows(2) {
                let (a, b) = (pair[0], pair[1]);
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let length = dx.hypot(dy).max(1.);
                let steps = (length * 2.).ceil() as usize;
                let polarity = if (self.seed.wrapping_add(index as u64)) & 1 == 0 {
                    1.
                } else {
                    -1.
                };
                let bow = (size * 0.018).min(1.4).min(length * 0.035) * self.naturalness * polarity;
                for i in 0..=steps {
                    let t = i as f32 / steps as f32;
                    let bend = (std::f32::consts::PI * t).sin() * bow;
                    points.push((
                        ((a.0 + dx * t - dy / length * bend) * scale as f32).round() as i32,
                        ((a.1 + dy * t + dx / length * bend) * scale as f32).round() as i32,
                    ));
                }
            }
            dense.push((points, (stroke * scale as f32).round().max(1.) as i32));
        }
        let centers: Vec<Vec<_>> = dense
            .iter()
            .map(|(path, _)| {
                path.iter()
                    .map(|(x, y)| {
                        (
                            (*x as f32 / scale as f32).round() as i32,
                            (*y as f32 / scale as f32).round() as i32,
                        )
                    })
                    .collect()
            })
            .collect();
        let high = Glyphs::compose(advance * scale as f32, vec![], dense)?;
        let left = (high.left as f32 / scale as f32).floor() as i32;
        let top = (high.top as f32 / scale as f32).floor() as i32;
        let right = (high.right() as f32 / scale as f32).ceil() as i32;
        let bottom = (high.bottom() as f32 / scale as f32).ceil() as i32;
        let mut padded = GrayImage::new(
            ((right - left) * scale) as u32,
            ((bottom - top) * scale) as u32,
        );
        super::paste_mask(
            &mut padded,
            &high.mask,
            high.left - left * scale,
            high.top - top * scale,
        );
        let mut mask = image::imageops::resize(
            &padded,
            (right - left) as u32,
            (bottom - top) as u32,
            image::imageops::FilterType::Triangle,
        );
        // 2026-10-24：小字号抗锯齿不能把箭头尖和根钩断开；仅补四连通中心，不膨胀外缘。
        for path in centers {
            for pair in path.windows(2) {
                for (x, y) in [pair[0], (pair[1].0, pair[0].1), pair[1]] {
                    let (x, y) = (x - left, y - top);
                    if x >= 0 && y >= 0 && x < mask.width() as i32 && y < mask.height() as i32 {
                        mask[(x as u32, y as u32)][0] = mask[(x as u32, y as u32)][0].max(160);
                    }
                }
            }
        }
        Ok(Glyphs::trim(Glyph {
            mask,
            advance: advance.max(right as f32),
            left,
            top,
            ink: true,
        }))
    }
}

impl Glyphs<'_> {
    pub(super) fn math_compose(
        &self,
        size: f32,
        advance: f32,
        mut children: Vec<(Glyph, i32, i32)>,
        paths: Vec<Path>,
    ) -> Result<Glyph> {
        let paths: Vec<_> = paths
            .into_iter()
            .map(|(points, _)| {
                points
                    .into_iter()
                    .map(|(x, y)| (x as f32, y as f32))
                    .collect()
            })
            .collect();
        children.push((self.pen.draw(size, advance, &paths)?, 0, 0));
        Self::compose(advance, children, vec![])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FontBook;
    use std::{
        collections::{HashSet, VecDeque},
        path::PathBuf,
    };
    fn components(g: &Glyph) -> usize {
        let mut unseen: HashSet<_> = g
            .mask
            .enumerate_pixels()
            .filter(|(_, _, p)| p[0] >= 128)
            .map(|(x, y, _)| (x, y))
            .collect();
        let mut count = 0;
        while let Some(&start) = unseen.iter().next() {
            count += 1;
            unseen.remove(&start);
            let mut queue = VecDeque::from([start]);
            while let Some((x, y)) = queue.pop_front() {
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                    if nx >= 0 && ny >= 0 && unseen.remove(&(nx as u32, ny as u32)) {
                        queue.push_back((nx as u32, ny as u32));
                    }
                }
            }
        }
        count
    }
    #[test]
    fn font_sampled_math_keeps_connectivity_and_separate_inequality_bars() {
        let mut widths = Vec::new();
        for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
            let bytes = std::fs::read(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join(format!("../../assets/font_assets/{name}.ttf")),
            )
            .unwrap();
            let font = FontBook::load(&bytes).unwrap();
            let mut pen = MathPen::sample(&font);
            widths.push((pen.width * 10000.).round() as i32);
            for naturalness in [0., 0.35, 1.] {
                pen.naturalness = naturalness;
                for size in [18., 36., 72., 124.] {
                    for c in "¬→←↔⇒⇐⇔≤≥≠".chars() {
                        let g = pen.symbol(c, size).unwrap().unwrap();
                        assert_eq!(
                            components(&g),
                            if "≤≥".contains(c) { 2 } else { 1 },
                            "{name} {c} {size} {naturalness}"
                        );
                        assert!(g.advance >= g.right() as f32);
                        assert!((g.mask.width() as f32) < size * 1.2);
                        assert!((g.mask.height() as f32) < size);
                        assert_eq!(g.mask, pen.symbol(c, size).unwrap().unwrap().mask);
                        if "→←↔⇒⇐⇔".contains(c) {
                            let x = g.mask.width() / 2;
                            let mut runs = 0;
                            let mut previous = false;
                            for y in 0..g.mask.height() {
                                let ink = g.mask[(x, y)][0] >= 128;
                                if ink && !previous {
                                    runs += 1;
                                }
                                previous = ink;
                            }
                            assert_eq!(
                                runs,
                                if "⇒⇐⇔".contains(c) { 2 } else { 1 },
                                "{name} {c} must preserve shaft count at {size}"
                            );
                        }
                    }
                }
            }
        }
        widths.sort_unstable();
        widths.dedup();
        assert!(
            widths.len() >= 3,
            "font sampling must not collapse to a fixed pen width"
        );
    }
    #[test]
    fn zero_naturalness_ignores_seed_and_curves_keep_fixed_endpoints() {
        let font = FontBook::load(include_bytes!(
            "../../../../../assets/font_assets/云烟体.ttf"
        ))
        .unwrap();
        let mut pen = MathPen::sample(&font);
        let straight = pen.symbol('→', 72.).unwrap().unwrap();
        pen.seed = 5;
        assert_eq!(straight.mask, pen.symbol('→', 72.).unwrap().unwrap().mask);
        pen.naturalness = 1.;
        let curved = pen.symbol('→', 72.).unwrap().unwrap();
        assert_ne!(straight.mask, curved.mask);
        assert_eq!(components(&curved), 1);
        assert!((straight.left - curved.left).abs() <= 2);
        assert!((straight.right() - curved.right()).abs() <= 2);
    }
    #[test]
    fn inequalities_reuse_the_font_chevron_and_never_warp_its_outline() {
        for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
            let font = FontBook::load(
                &std::fs::read(
                    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                        .join(format!("../../assets/font_assets/{name}.ttf")),
                )
                .unwrap(),
            )
            .unwrap();
            let mut pen = MathPen::sample(&font);
            for c in ['≤', '≥'] {
                assert!(
                    pen.chevrons[usize::from(c == '≥')].is_some(),
                    "{name} {c} must reuse its native chevron"
                );
                let straight = pen.symbol(c, 72.).unwrap().unwrap();
                pen.naturalness = 1.;
                let curved = pen.symbol(c, 72.).unwrap().unwrap();
                // 上部字体原笔画保持逐像素相同；仅下方独立横线接受有界自然度。
                let source = pen.chevrons[usize::from(c == '≥')].as_ref().unwrap();
                let height = (source.height() as f32 * 72. / 96.).round() as i32;
                for y in straight.top..straight.top + height {
                    for x in 0..(source.width() as f32 * 72. / 96.).round() as i32 {
                        assert_eq!(
                            straight.mask[((x - straight.left) as u32, (y - straight.top) as u32)],
                            curved.mask[((x - curved.left) as u32, (y - curved.top) as u32)]
                        );
                    }
                }
                pen.naturalness = 0.;
            }
        }
    }
    #[test]
    fn long_fraction_paths_fit_the_existing_budget_and_non_math_frames_stay_rigid() {
        let font = FontBook::load(
            &std::fs::read(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../assets/font_assets/云烟体.ttf"),
            )
            .unwrap(),
        )
        .unwrap();
        let book = FontBook::from_fonts(font.clone(), vec![]);
        let pen = MathPen::sample(&font);
        let long = pen
            .draw(64., 12000., &[vec![(0., -20.), (11999., -20.)]])
            .unwrap();
        assert!(long.mask.width() >= 12000);
        let mut quiet = Glyphs::new(&book);
        let mut natural = Glyphs::with_parameters(
            &book,
            &crate::Parameters {
                perturb_x_sigma: 100.,
                perturb_y_sigma: 100.,
                perturb_theta_sigma: 100.,
                ..crate::Parameters::default()
            },
        );
        for source in ["⟦ A | 1 | 2; B | 3 | 4 ⟧", "⟦ matrix: 1  0 ; 0  1 ⟧"] {
            let nodes = crate::text::parse(source);
            assert_eq!(
                quiet.sequence(&nodes, 40.).unwrap().mask,
                natural.sequence(&nodes, 40.).unwrap().mask
            );
        }
    }
}
