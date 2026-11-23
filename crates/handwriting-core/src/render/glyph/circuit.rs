//! 2026-10-22：电路作为刚性手写结构，统一笔宽、精确端点，不抖动拓扑连接。
use super::*;
use crate::text::circuit::{Circuit, Point};
use rand::RngExt;
use rand_chacha::ChaCha8Rng;
use std::f32::consts::{PI, TAU};

mod branch;

#[derive(Clone, Copy)]
enum Stroke {
    Pen,
    DotFill,
}
type CircuitPath = (Vec<(i32, i32)>, Stroke);

struct Drawing {
    paths: Vec<CircuitPath>,
    scale: f32,
    naturalness: f32,
    rng: ChaCha8Rng,
    holes: Vec<Point>,
    contacts: Vec<Point>,
}
impl Drawing {
    fn point(&self, p: Point) -> (i32, i32) {
        (
            (p.0 * self.scale).round() as i32,
            (-p.1 * self.scale).round() as i32,
        )
    }
    fn path(&mut self, points: Vec<Point>) {
        if points.len() < 2 {
            return;
        }
        let mut screen_points: Vec<(i32, i32)> = Vec::new();
        let max_dev = (self.scale * 0.03).min(2.25);
        for pair in points.windows(2) {
            let (p1, p2) = (self.point(pair[0]), self.point(pair[1]));
            let dx = (p2.0 - p1.0) as f32;
            let dy = (p2.1 - p1.1) as f32;
            let dist = dx.hypot(dy);
            if dist < 16.0 {
                if screen_points.is_empty() {
                    screen_points.push(p1);
                }
                screen_points.push(p2);
                continue;
            }
            let nx = -dy / dist;
            let ny = dx / dist;
            let phase1 = self.rng.random::<f32>() * TAU;
            let phase2 = self.rng.random::<f32>() * TAU;
            let dev = (dist * 0.022).min(max_dev) * self.naturalness;
            let steps = (dist / 9.0).round().max(3.0) as usize;
            if screen_points.is_empty() {
                screen_points.push(p1);
            }
            for i in 1..steps {
                let t = i as f32 / steps as f32;
                let envelope = (t * PI).sin();
                let wobble = (0.75 * (t * 2.0 * PI + phase1).sin()
                    + 0.25 * (t * 3.0 * PI + phase2).sin())
                    * envelope
                    * dev;
                let x = (p1.0 as f32 + dx * t + nx * wobble).round() as i32;
                let y = (p1.1 as f32 + dy * t + ny * wobble).round() as i32;
                screen_points.push((x, y));
            }
            screen_points.push(p2);
        }
        self.paths.push((screen_points, Stroke::Pen));
    }
    fn line(&mut self, a: Point, b: Point) {
        // 2026-10-23：长导线中间的 T 形分支同样固定，避免微扰把接点画离母线。
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let length_squared = dx * dx + dy * dy;
        let mut interior = Vec::new();
        if length_squared > 0. {
            for point in &self.contacts {
                let px = point.0 - a.0;
                let py = point.1 - a.1;
                let t = (px * dx + py * dy) / length_squared;
                let cross = px * dy - py * dx;
                if t > 0. && t < 1. && cross.abs() <= length_squared.sqrt() * 0.00001 {
                    interior.push((t, *point));
                }
            }
        }
        interior.sort_by(|a, b| a.0.total_cmp(&b.0));
        interior.dedup_by(|a, b| a.1 == b.1);
        let points = std::iter::once(a)
            .chain(interior.into_iter().map(|(_, point)| point))
            .chain(std::iter::once(b))
            .collect();
        self.path(points);
    }
    fn line_through(&mut self, a: Point, contact: Point, b: Point) {
        self.line(a, contact);
        self.line(contact, b);
    }
    fn circle(&mut self, c: Point, r: f32) {
        self.contact_circle(c, r, 0.);
    }
    fn contact_circle(&mut self, c: Point, r: f32, contact_angle: f32) {
        // 2026-10-23：只在端子之间扰动，任意方向的引线端点都与圆周精确重合。
        let radius = (r * self.scale).round().max(1.0);
        let p1 = self.rng.random::<f32>() * TAU;
        let p2 = self.rng.random::<f32>() * TAU;
        let w_dev = (radius * 0.022).clamp(0.4, 1.2) * self.naturalness;
        let steps = 40;
        let mut screen_points = Vec::new();
        for i in 0..steps {
            let local = i as f32 * 2.0 * PI / steps as f32;
            let ang = local + contact_angle;
            let envelope = (local * 2.).sin().powi(2);
            let dr =
                (0.7 * (ang * 2.0 + p1).sin() + 0.3 * (ang * 3.0 + p2).sin()) * w_dev * envelope;
            let rr = r + dr / self.scale;
            screen_points.push(self.point(Point(c.0 + rr * ang.cos(), c.1 + rr * ang.sin())));
        }
        if let Some(&first) = screen_points.first() {
            screen_points.push(first);
        }
        self.paths.push((screen_points, Stroke::Pen));
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
                    .push((vec![(x - dx, y + dy), (x + dx, y + dy)], Stroke::DotFill));
            }
        }
    }
    fn finish(mut self) -> Vec<CircuitPath> {
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
        self.arrowhead(a, b);
    }
    fn arrowhead(&mut self, a: Point, b: Point) {
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let len = dx.hypot(dy);
        if len > 0. {
            let ux = dx / len;
            let uy = dy / len;
            let back = 0.13_f32.min(len * 0.45);
            let wing = back * 0.47;
            self.path(vec![
                Point(b.0 - ux * back - uy * wing, b.1 - uy * back + ux * wing),
                b,
                Point(b.0 - ux * back + uy * wing, b.1 - uy * back - ux * wing),
            ]);
        }
    }
}
// 2026-11-22：按字体采样的小数笔宽覆盖像素，避免整数笔刷把两像素线扩成三像素。
fn pen_paths(paths: Vec<CircuitPath>, width: f32) -> Result<Option<Glyph>> {
    let mut points = paths.iter().flat_map(|(points, _)| points);
    let Some(&(x, y)) = points.next() else {
        return Ok(None);
    };
    let (x0, y0, x1, y1) = points.fold((x, y, x, y), |b, &(x, y)| {
        (b.0.min(x), b.1.min(y), b.2.max(x), b.3.max(y))
    });
    let pad = (width * 0.5 + 0.5).ceil() as i32;
    let (left, top) = (x0 - pad, y0 - pad);
    let (w, h) = ((x1 - left + pad + 1) as u32, (y1 - top + pad + 1) as u32);
    Glyphs::check_size(w, h)?;
    let mut mask = GrayImage::new(w, h);
    for (points, pen) in paths {
        let diameter = match pen {
            Stroke::Pen => width,
            Stroke::DotFill => 1.,
        };
        let reach = (diameter + 1.) * 0.5;
        for pair in points.windows(2) {
            let ((ax, ay), (bx, by)) = (pair[0], pair[1]);
            let (dx, dy) = ((bx - ax) as f32, (by - ay) as f32);
            let length_sq = (dx * dx + dy * dy).max(1.);
            for y in ay.min(by) - pad..=ay.max(by) + pad {
                for x in ax.min(bx) - pad..=ax.max(bx) + pad {
                    let (px, py) = ((x - ax) as f32, (y - ay) as f32);
                    let t = ((px * dx + py * dy) / length_sq).clamp(0., 1.);
                    let distance = (px - t * dx).hypot(py - t * dy);
                    let alpha =
                        ((reach - distance).clamp(0., diameter.min(1.)) * 255.).round() as u8;
                    // 刚性图在 128 取墨；亚像素细笔的中心线也要能通过这个阈值。
                    let alpha = if diameter < 1. && distance <= 0.5 {
                        alpha.max(128)
                    } else {
                        alpha
                    };
                    let value = &mut mask[((x - left) as u32, (y - top) as u32)][0];
                    *value = (*value).max(alpha);
                }
            }
        }
    }
    Ok(Some(Glyphs::trim(Glyph {
        mask,
        advance: 0.,
        left,
        top,
        ink: true,
    })))
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
        let mut draw = Drawing {
            paths: Vec::new(),
            scale,
            naturalness: self.pen.naturalness,
            rng: self.next_drawing_rng(),
            holes: Vec::new(),
            contacts: circuit
                .segments
                .iter()
                .flat_map(|s| [s.start, s.end])
                .chain(circuit.decorations.iter().map(|d| d.point))
                .collect(),
        };
        let mut labels: Vec<(String, Point, i32)> = Vec::new();
        for segment in &circuit.segments {
            branch::draw(&mut draw, segment, circuit.american, &mut labels)?;
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
                        draw.line_through(Point(p.0 - h, y), Point(p.0, y), Point(p.0 + h, y));
                    }
                }
                "rground" => {
                    draw.line(p, Point(p.0, p.1 - 0.18));
                    draw.path(vec![
                        Point(p.0 - 0.2, p.1 - 0.18),
                        Point(p.0, p.1 - 0.48),
                        Point(p.0 + 0.2, p.1 - 0.18),
                        Point(p.0, p.1 - 0.18),
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
        if let Some(ink) = pen_paths(draw.finish(), self.pen.thickness(size))? {
            children.push((ink, 0, 0));
        }
        let mut result = Self::compose(0., children, Vec::new())?;
        result.left = 0;
        result.top = -(result.mask.height() as i32) / 2;
        result.advance = result.mask.width() as f32 + size * 0.2;
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn drawing(scale: f32) -> Drawing {
        Drawing {
            paths: Vec::new(),
            scale,
            naturalness: 1.,
            rng: rand::SeedableRng::seed_from_u64(20261123),
            holes: Vec::new(),
            contacts: Vec::new(),
        }
    }
    #[test]
    fn bent_flow_arrow_has_one_small_open_head_on_its_last_leg() {
        let circuit = crate::text::circuit::parse(
            r"\begin{circuitikz}\draw[->] (0,0) -| (2,1); \draw (0,0) -- (1,0);\end{circuitikz}",
        )
        .unwrap();
        assert_eq!(
            circuit
                .segments
                .iter()
                .map(|s| s.end_arrow)
                .collect::<Vec<_>>(),
            [false, true, false]
        );
        let mut d = drawing(60.);
        d.arrowhead(circuit.segments[1].start, circuit.segments[1].end);
        let head = &d.paths[0].0;
        assert_eq!(head.len(), 3);
        assert_eq!(head[1], (120, -60));
        assert!(head[0].0 < 120 && head[2].0 > 120);
        assert!(head.iter().all(|p| (-60..=-51).contains(&p.1)));
    }

    #[test]
    fn horizontal_ink_coverage_tracks_fractional_pen_width() {
        for width in [0.75, 1., 1.4, 2., 2.8] {
            let ink = pen_paths(vec![(vec![(0, 0), (20, 0)], Stroke::Pen)], width)
                .unwrap()
                .unwrap();
            let coverage: f32 = (0..ink.mask.height())
                .map(|y| ink.mask[((10 - ink.left) as u32, y)][0] as f32 / 255.)
                .sum();
            assert!((coverage - width).abs() < 0.01, "{coverage} vs {width}");
        }
    }

    #[test]
    fn subpixel_wires_survive_the_page_ink_threshold() {
        use imageproc::region_labelling::{Connectivity, connected_components};
        for end in [(72, 31), (31, -72), (-72, -13), (-17, 72), (72, 0), (0, 72)] {
            let wire = pen_paths(vec![(vec![(0, 0), end], Stroke::Pen)], 0.75)
                .unwrap()
                .unwrap();
            let ink = GrayImage::from_fn(wire.mask.width(), wire.mask.height(), |x, y| {
                Luma([u8::from(wire.mask[(x, y)][0] >= 128)])
            });
            let labels = connected_components(&ink, Connectivity::Eight, Luma([0]));
            assert_eq!(labels.pixels().map(|p| p[0]).max(), Some(1), "{end:?}");
            for (x, y) in [(0, 0), end] {
                assert_eq!(ink[((x - wire.left) as u32, (y - wire.top) as u32)][0], 1);
            }
        }
    }

    #[test]
    fn natural_source_circles_pin_exact_contacts_for_rotated_and_fractional_centers() {
        for scale in [10., 24.5, 70., 122.5, 160.] {
            for angle in [0., PI / 2., PI, -PI / 2., PI / 4., -PI / 3.] {
                let mut draw = drawing(scale);
                let c = Point(0.123, -0.247);
                let r = 0.32;
                draw.contact_circle(c, r, angle);
                let points = &draw.paths[0].0;
                for (index, sign) in [(0, 1.), (20, -1.)] {
                    let expected = draw.point(Point(
                        c.0 + sign * r * angle.cos(),
                        c.1 + sign * r * angle.sin(),
                    ));
                    assert_eq!(points[index], expected, "scale={scale}, angle={angle}");
                }
                assert_eq!(points.first(), points.last());
                // 至少保留非端子位置的自然笔画，不能为保证连接退化为规则圆形。
                let ideal: Vec<_> = (0..40)
                    .map(|i| {
                        let a = angle + i as f32 * 2. * PI / 40.;
                        draw.point(Point(c.0 + r * a.cos(), c.1 + r * a.sin()))
                    })
                    .collect();
                if scale >= 70. {
                    assert!(points[..40].iter().zip(ideal).any(|(a, b)| *a != b));
                }
            }
        }
    }
    #[test]
    fn parallel_wires_vary_within_one_drawing_and_replay_with_the_same_seed() {
        let strokes = |naturalness| {
            let mut draw = drawing(80.);
            draw.naturalness = naturalness;
            for y in [0., 1.] {
                draw.line(Point(0., y), Point(6., y));
            }
            draw.paths
                .into_iter()
                .enumerate()
                .map(|(row, (path, _))| {
                    path.into_iter()
                        .map(|(_, y)| y + row as i32 * 80)
                        .collect::<Vec<_>>()
                })
                .collect::<Vec<_>>()
        };
        let lines = strokes(1.);
        assert_eq!(lines, strokes(1.));
        assert_ne!(lines[0], lines[1]);
        assert!(lines.iter().flatten().all(|y| y.abs() <= 3));
        assert!(strokes(0.).iter().flatten().all(|&y| y == 0));
    }

    #[test]
    fn natural_wires_keep_every_corner_and_both_endpoints() {
        for scale in [10., 70., 160.] {
            let mut draw = drawing(scale);
            let world = vec![
                Point(-2.3, 0.7),
                Point(-2.3, 3.4),
                Point(4.5, 3.4),
                Point(4.5, -0.1),
            ];
            let pinned: Vec<_> = world.iter().map(|p| draw.point(*p)).collect();
            draw.path(world);
            let points = &draw.paths[0].0;
            assert_eq!(points.first(), pinned.first());
            assert_eq!(points.last(), pinned.last());
            assert!(pinned.iter().all(|p| points.contains(p)));
        }
    }
    #[test]
    fn natural_wires_pin_interior_t_junctions_without_a_junction_dot() {
        for scale in [10., 70., 160.] {
            for (a, b, join) in [
                (Point(0., 3.), Point(6., 3.), Point(3., 3.)),
                (Point(6., 3.), Point(0., 3.), Point(3., 3.)),
                (Point(0., 0.), Point(0., 6.), Point(0., 2.)),
                (Point(-2., -2.), Point(4., 4.), Point(1., 1.)),
            ] {
                let mut draw = drawing(scale);
                // 接近导线但不在其上的标签或另一个端点不能把母线拉歪。
                draw.contacts = vec![join, Point(join.0 + 0.1, join.1 + 0.2), join];
                draw.line(a, b);
                let expected = draw.point(join);
                assert!(draw.paths[0].0.contains(&expected));
                assert_eq!(
                    draw.paths[0].0.iter().filter(|p| **p == expected).count(),
                    1
                );
            }
        }
    }
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
        Glyphs::with_parameters(book, &Parameters::default())
            .unwrap()
            .circuit(&circuit, 40., 0)
            .unwrap()
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
    fn actual_source_ink_keeps_both_leads_connected_to_the_outline() {
        for kind in ["V", "I", "sV"] {
            for end in ["4,0", "-4,0", "0,4", "0,-4", "4,4", "-4,4", "4,-4"] {
                let g = glyph_to(kind, end);
                let mut mask = g.mask.clone();
                let mut whole = (u32::MAX, u32::MAX, 0, 0);
                for (x, y, p) in mask.enumerate_pixels() {
                    if p[0] > 127 {
                        whole = (
                            whole.0.min(x),
                            whole.1.min(y),
                            whole.2.max(x),
                            whole.3.max(y),
                        );
                    }
                }
                let mut connected_outline = false;
                for y in 0..mask.height() {
                    for x in 0..mask.width() {
                        if mask[(x, y)][0] <= 127 {
                            continue;
                        }
                        let mut stack = vec![(x, y)];
                        let mut bounds = (x, y, x, y);
                        mask[(x, y)][0] = 0;
                        while let Some((x, y)) = stack.pop() {
                            bounds = (
                                bounds.0.min(x),
                                bounds.1.min(y),
                                bounds.2.max(x),
                                bounds.3.max(y),
                            );
                            for dy in -1..=1 {
                                for dx in -1..=1 {
                                    let (xx, yy) = (x as i32 + dx, y as i32 + dy);
                                    if xx >= 0
                                        && yy >= 0
                                        && xx < mask.width() as i32
                                        && yy < mask.height() as i32
                                    {
                                        let pixel = &mut mask[(xx as u32, yy as u32)];
                                        if pixel[0] > 127 {
                                            pixel[0] = 0;
                                            stack.push((xx as u32, yy as u32));
                                        }
                                    }
                                }
                            }
                        }
                        connected_outline |= bounds == whole;
                    }
                }
                assert!(
                    connected_outline,
                    "{kind} {end}: a source lead floats off its outline"
                );
            }
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
        assert!(
            (10..g.mask.width() - 10)
                .all(|x| { (y - 3..=y + 3).any(|row| g.mask[(x, row)][0] > 0) })
        );
    }
}
