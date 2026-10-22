//! 2026-10-22：电路作为刚性手写结构，统一笔宽、精确端点，不抖动拓扑连接。
use super::*;
use crate::text::circuit::{Circuit, Point};
use std::f32::consts::PI;

struct Drawing {
    paths: Vec<Path>,
    thickness: i32,
    scale: f32,
    holes: Vec<Point>,
}
impl Drawing {
    fn point(&self, p: Point) -> (i32, i32) {
        (
            (p.0 * self.scale).round() as i32,
            (-p.1 * self.scale).round() as i32,
        )
    }
    fn path(&mut self, points: Vec<Point>) {
        self.paths.push((
            points.into_iter().map(|p| self.point(p)).collect(),
            self.thickness,
        ));
    }
    fn line(&mut self, a: Point, b: Point) {
        self.path(vec![a, b]);
    }
    fn circle(&mut self, c: Point, r: f32) {
        self.path(
            (0..=40)
                .map(|i| {
                    Point(
                        c.0 + r * (i as f32 * PI / 20.).cos(),
                        c.1 + r * (i as f32 * PI / 20.).sin(),
                    )
                })
                .collect(),
        );
    }
    fn dot(&mut self, c: Point, open: bool) {
        if open {
            self.holes.push(c);
        } else {
            let radius = (self.scale * 0.055).round().max(2.) as i32;
            let (x, y) = self.point(c);
            for dy in -radius..=radius {
                let dx = ((radius * radius - dy * dy) as f32).sqrt().round() as i32;
                self.paths
                    .push((vec![(x - dx, y + dy), (x + dx, y + dy)], 1));
            }
        }
    }
    fn finish(mut self) -> Vec<Path> {
        // 2026-10-22：在合成前裁剪空心端口内的导线；保持透明背景与真实拓扑。
        for center in &self.holes {
            let (cx, cy) = self.point(*center);
            let radius = (self.scale * 0.055).max(2.);
            let mut paths = Vec::new();
            for (points, thickness) in self.paths {
                for pair in points.windows(2) {
                    let (a, b) = (pair[0], pair[1]);
                    let dx = (b.0 - a.0) as f32;
                    let dy = (b.1 - a.1) as f32;
                    let fx = (a.0 - cx) as f32;
                    let fy = (a.1 - cy) as f32;
                    let aa = dx * dx + dy * dy;
                    if aa == 0. {
                        continue;
                    }
                    let bb = 2. * (fx * dx + fy * dy);
                    let cc = fx * fx + fy * fy - radius * radius;
                    let delta = bb * bb - 4. * aa * cc;
                    let intervals = if delta <= 0. {
                        if cc >= 0. { vec![(0., 1.)] } else { Vec::new() }
                    } else {
                        let low = ((-bb - delta.sqrt()) / (2. * aa)).clamp(0., 1.);
                        let high = ((-bb + delta.sqrt()) / (2. * aa)).clamp(0., 1.);
                        let mut intervals = Vec::new();
                        if low > 0. {
                            intervals.push((0., low));
                        }
                        if high < 1. {
                            intervals.push((high, 1.));
                        }
                        intervals
                    };
                    for (low, high) in intervals {
                        let point = |t: f32| {
                            (
                                (a.0 as f32 + dx * t).round() as i32,
                                (a.1 as f32 + dy * t).round() as i32,
                            )
                        };
                        paths.push((vec![point(low), point(high)], thickness));
                    }
                }
            }
            self.paths = paths;
        }
        for center in self.holes.clone() {
            self.circle(center, 0.055);
        }
        self.paths
    }
    fn arrow(&mut self, a: Point, b: Point) {
        self.line(a, b);
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let len = dx.hypot(dy);
        if len > 0. {
            let ux = dx / len;
            let uy = dy / len;
            self.path(vec![
                Point(b.0 - ux * 0.1 - uy * 0.055, b.1 - uy * 0.1 + ux * 0.055),
                b,
                Point(b.0 - ux * 0.1 + uy * 0.055, b.1 - uy * 0.1 - ux * 0.055),
            ]);
        }
    }
}
impl Glyphs<'_> {
    pub(super) fn circuit(&mut self, circuit: &Circuit, size: f32, depth: usize) -> Result<Glyph> {
        let mut bounds = (
            f32::INFINITY,
            f32::INFINITY,
            f32::NEG_INFINITY,
            f32::NEG_INFINITY,
        );
        for p in circuit.segments.iter().flat_map(|s| [s.start, s.end]) {
            bounds.0 = bounds.0.min(p.0);
            bounds.1 = bounds.1.min(p.1);
            bounds.2 = bounds.2.max(p.0);
            bounds.3 = bounds.3.max(p.1);
        }
        let span = (bounds.2 - bounds.0).max(bounds.3 - bounds.1).max(1.);
        let scale = (size * 1.75).clamp(10., 160.).min(1800. / span);
        let thickness = (size * 0.025).round().max(1.) as i32;
        let mut draw = Drawing {
            paths: Vec::new(),
            thickness,
            scale,
            holes: Vec::new(),
        };
        let mut labels: Vec<(String, Point, i32)> = Vec::new();
        for segment in &circuit.segments {
            let a = segment.start;
            let b = segment.end;
            let dx = b.0 - a.0;
            let dy = b.1 - a.1;
            let length = dx.hypot(dy);
            let ux = dx / length;
            let uy = dy / length;
            let mid = Point((a.0 + b.0) / 2., (a.1 + b.1) / 2.);
            let half = 0.38f32.min(length * 0.32);
            let h = 0.15f32.min(half * 0.6);
            let p = |x: f32, y: f32| Point(mid.0 + ux * x - uy * y, mid.1 + uy * x + ux * y);
            let kind = segment.kind.as_str();
            if kind == "short" {
                draw.line(a, b);
            } else if kind != "open" {
                draw.line(a, p(-half, 0.));
                draw.line(p(half, 0.), b);
                match kind {
                    "R" if circuit.american => {
                        let mut points = vec![p(-half, 0.)];
                        for i in 0..7 {
                            points.push(p(
                                -half + half * (i as f32 + 0.5) / 3.5,
                                if i % 2 == 0 { h } else { -h },
                            ));
                        }
                        points.push(p(half, 0.));
                        draw.path(points);
                    }
                    "R" => draw.path(vec![
                        p(-half, 0.),
                        p(-half, h),
                        p(half, h),
                        p(half, -h),
                        p(-half, -h),
                        p(-half, 0.),
                    ]),
                    "C" => {
                        draw.line(p(-half, 0.), p(-0.055, 0.));
                        draw.line(p(0.055, 0.), p(half, 0.));
                        draw.line(p(-0.055, -h * 1.5), p(-0.055, h * 1.5));
                        draw.line(p(0.055, -h * 1.5), p(0.055, h * 1.5));
                    }
                    "L" => {
                        let radius = half / 4.;
                        let mut points = Vec::new();
                        for loop_index in 0..4 {
                            for i in 0..=12 {
                                let t = PI - i as f32 * PI / 12.;
                                points.push(p(
                                    -half
                                        + radius * (2. * loop_index as f32 + 1.)
                                        + radius * t.cos(),
                                    radius * t.sin() * 1.9,
                                ));
                            }
                        }
                        draw.path(points);
                    }
                    "V" | "I" | "sV" => {
                        let radius = 0.32f32.min(half);
                        draw.line(p(-half, 0.), p(-radius, 0.));
                        draw.line(p(radius, 0.), p(half, 0.));
                        draw.circle(mid, radius);
                        if kind == "I" {
                            draw.arrow(p(-radius * 0.55, 0.), p(radius * 0.55, 0.));
                        } else if kind == "V" {
                            let plus = p(radius * 0.48, 0.);
                            let minus = p(-radius * 0.48, 0.);
                            let mark = h * 0.36;
                            draw.line(Point(plus.0 - mark, plus.1), Point(plus.0 + mark, plus.1));
                            draw.line(Point(plus.0, plus.1 - mark), Point(plus.0, plus.1 + mark));
                            draw.line(
                                Point(minus.0 - mark, minus.1),
                                Point(minus.0 + mark, minus.1),
                            );
                        } else {
                            draw.path(
                                (0..=24)
                                    .map(|i| {
                                        let x = -radius * 0.6 + i as f32 * radius * 1.2 / 24.;
                                        // 2026-10-22：交流波形保持正立，仅支路引线与端子随方向旋转。
                                        Point(
                                            mid.0 + x,
                                            mid.1 + (i as f32 * 2. * PI / 24.).sin() * h * 0.7,
                                        )
                                    })
                                    .collect(),
                            );
                        }
                    }
                    "battery1" => {
                        draw.line(p(-half, 0.), p(-0.055, 0.));
                        draw.line(p(0.055, 0.), p(half, 0.));
                        draw.line(p(0.055, -h * 1.5), p(0.055, h * 1.5));
                        draw.line(p(-0.055, -h * 0.75), p(-0.055, h * 0.75));
                    }
                    "D" | "led" => {
                        draw.line(p(-half, 0.), p(-h, 0.));
                        draw.line(p(h, 0.), p(half, 0.));
                        draw.path(vec![p(-h, -h), p(h, 0.), p(-h, h), p(-h, -h)]);
                        draw.line(p(h, -h), p(h, h));
                        if kind == "led" {
                            draw.arrow(p(0., h * 1.7), p(h * 0.9, h * 2.6));
                            draw.arrow(p(h * 0.9, h * 1.7), p(h * 1.8, h * 2.6));
                        }
                    }
                    "switch" | "closing switch" | "opening switch" => {
                        draw.dot(p(-half, 0.), true);
                        draw.dot(p(half, 0.), true);
                        draw.line(p(-half + 0.055, 0.), p(half - 0.055, h * 1.7));
                        if kind != "switch" {
                            let (a, b) = if kind == "closing switch" {
                                (p(0., h * 2.5), p(0., h * 0.8))
                            } else {
                                (p(0., h * 0.8), p(0., h * 2.5))
                            };
                            draw.arrow(a, b);
                        }
                    }
                    _ => return Err(Error::new("invalid_layout", "不支持的电路元件")),
                }
            }
            for (point, mark) in [(a, segment.marks.0), (b, segment.marks.1)] {
                if mark == '*' || mark == 'o' {
                    draw.dot(point, mark == 'o');
                }
            }
            let mut lanes = std::collections::HashMap::<i32, usize>::new();
            for label in &segment.labels {
                let side = if label.kind == 'a' {
                    -label.side
                } else {
                    label.side
                };
                let occupied = lanes.entry(if side > 0. { 1 } else { -1 }).or_default();
                let base =
                    if side > 0. && matches!(kind, "led" | "closing switch" | "opening switch") {
                        0.85
                    } else {
                        0.48
                    };
                let offset = base + *occupied as f32 * 0.55;
                *occupied += 1;
                let pos = if matches!(label.kind, 'i' | 'v') {
                    p(0., (offset + 0.34) * side)
                } else {
                    p(0., offset * side)
                };
                let anchor = if uy.abs() > 0.5 {
                    if -uy * side < 0. { -1 } else { 1 }
                } else {
                    0
                };
                labels.push((label.text.clone(), pos, anchor));
                if matches!(label.kind, 'i' | 'v') {
                    draw.arrow(
                        p(-half * 1.1 * label.direction, (offset + 0.05) * side),
                        p(half * 1.1 * label.direction, (offset + 0.05) * side),
                    );
                }
            }
        }
        for decoration in &circuit.decorations {
            let p = decoration.point;
            match decoration.kind.as_str() {
                "circ" => draw.dot(p, false),
                "ocirc" => draw.dot(p, true),
                "ground" => {
                    draw.line(p, Point(p.0, p.1 - 0.18));
                    for i in 0..3 {
                        let h = 0.2 - i as f32 * 0.06;
                        let y = p.1 - 0.18 - i as f32 * 0.07;
                        draw.line(Point(p.0 - h, y), Point(p.0 + h, y));
                    }
                }
                "rground" => {
                    draw.line(p, Point(p.0, p.1 - 0.18));
                    draw.path(vec![
                        Point(p.0 - 0.2, p.1 - 0.18),
                        Point(p.0, p.1 - 0.48),
                        Point(p.0 + 0.2, p.1 - 0.18),
                        Point(p.0 - 0.2, p.1 - 0.18),
                    ]);
                }
                _ => {
                    let pos = match decoration.kind.as_str() {
                        "above" => Point(p.0, p.1 + 0.3),
                        "below" => Point(p.0, p.1 - 0.3),
                        "left" => Point(p.0 - 0.45, p.1),
                        "above left" => Point(p.0 - 0.35, p.1 + 0.3),
                        "above right" => Point(p.0 + 0.35, p.1 + 0.3),
                        "below left" => Point(p.0 - 0.35, p.1 - 0.3),
                        "below right" => Point(p.0 + 0.35, p.1 - 0.3),
                        "right" => Point(p.0 + 0.45, p.1),
                        _ => p,
                    };
                    let anchor = if decoration.kind.contains("left") {
                        -1
                    } else if decoration.kind.contains("right") {
                        1
                    } else {
                        0
                    };
                    labels.push((decoration.text.clone(), pos, anchor));
                }
            }
        }
        let mut children = Vec::new();
        for (text, p, anchor) in labels {
            let g = self.sequence_at(&crate::text::parse(&text), size * 0.69, depth + 1)?;
            let (x, y) = draw.point(p);
            let x = match anchor {
                -1 => x - g.right(),
                1 => x - g.left,
                _ => x - (g.left + g.right()) / 2,
            };
            let y = y - (g.top + g.bottom()) / 2;
            children.push((g, x, y));
        }
        let mut result = Self::compose(0., children, draw.finish())?;
        result.left = 0;
        result.top = -(result.mask.height() as i32) / 2;
        result.advance = result.mask.width() as f32 + size * 0.2;
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn glyph(kind: &str) -> Glyph {
        glyph_to(kind, "4,0")
    }
    fn glyph_to(kind: &str, end: &str) -> Glyph {
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../assets/font_assets/霞鹜文楷.ttf");
        static BOOK: std::sync::OnceLock<FontBook> = std::sync::OnceLock::new();
        let book = BOOK.get_or_init(|| FontBook::new(&std::fs::read(dir).unwrap(), &[]).unwrap());
        let source = format!(
            "{}\\draw (0,0) to[{kind}] ({end});{}",
            crate::text::circuit::BEGIN,
            crate::text::circuit::END
        );
        let circuit = crate::text::circuit::parse(&source).unwrap();
        Glyphs::new(book).circuit(&circuit, 40., 0).unwrap()
    }
    #[test]
    fn common_components_have_distinct_actual_ink() {
        let mut fingerprints = std::collections::HashSet::new();
        for kind in [
            "R",
            "C",
            "L",
            "V",
            "I",
            "sV",
            "battery1",
            "D",
            "led",
            "short",
            "switch",
            "closing switch",
            "opening switch",
        ] {
            let g = glyph(kind);
            assert!(
                g.ink && g.mask.pixels().filter(|p| p[0] > 127).count() > 30,
                "{kind}"
            );
            assert!(
                fingerprints.insert((g.mask.width(), g.mask.height(), g.mask.into_raw())),
                "same component silhouette {kind}"
            );
        }
    }
    #[test]
    fn voltage_positive_terminal_follows_the_path_end_with_upright_signs() {
        let g = glyph("V");
        let center_y = g.mask.height() as i32 / 2;
        let center_x = g.mask.width() as i32 / 2;
        let delta = (40f32 * 1.75 * 0.38 * 0.48).round() as i32;
        let count = |cx| {
            let mut ink = 0;
            for y in center_y - 5..=center_y + 5 {
                for x in cx - 5..=cx + 5 {
                    if g.mask[(x as u32, y as u32)][0] > 127 {
                        ink += 1;
                    }
                }
            }
            ink
        };
        assert!(count(center_x + delta) > count(center_x - delta));
    }
    #[test]
    fn ac_wave_stays_upright_for_all_four_branch_directions() {
        let mut reference = None;
        for end in ["4,0", "-4,0", "0,4", "0,-4"] {
            let g = glyph_to("sV", end);
            let cx = g.mask.width() / 2;
            let cy = g.mask.height() / 2;
            let wave = image::imageops::crop_imm(&g.mask, cx - 15, cy - 10, 31, 21).to_image();
            let mut bounds = (31, 21, 0, 0);
            for (x, y, pixel) in wave.enumerate_pixels() {
                if pixel[0] > 127 {
                    bounds.0 = bounds.0.min(x);
                    bounds.1 = bounds.1.min(y);
                    bounds.2 = bounds.2.max(x);
                    bounds.3 = bounds.3.max(y);
                }
            }
            assert!(
                bounds.2 - bounds.0 > bounds.3 - bounds.1,
                "{end}: wave must be horizontal"
            );
            if let Some(expected) = &reference {
                assert_eq!(&wave, expected, "{end}: internal wave rotated");
            } else {
                reference = Some(wave);
            }
        }
    }
    #[test]
    fn open_terminals_have_transparent_centers_even_on_a_wire() {
        let g = glyph("short,o-o");
        let y = g.mask.height() / 2;
        assert_eq!(g.mask[(4, y)][0], 0);
        assert_eq!(g.mask[(g.mask.width() - 5, y)][0], 0);
        assert!(g.mask[(g.mask.width() / 2, y)][0] > 0);
    }
}
