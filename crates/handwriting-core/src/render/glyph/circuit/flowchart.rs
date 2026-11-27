//! 2026-11-27：用正文字形定节点边框，以路径的原始中心坐标确定实际箭头接点。
use super::{Circuit, Drawing, Glyphs, Point, PositionedGlyph, Result, TAU};
use crate::{Error, text::circuit::Segment};

// 取字形前景像素所在的最短横截面；在转折、交叉处用中位数抑制局部膨大。
pub(super) fn pen_width(font: &fontdue::Font, size: f32, fallback: f32) -> f32 {
    let sample_size = size.round().clamp(1., 96.);
    let mut widths = Vec::new();
    for c in ['B', 'n', '1', '十', '口'] {
        if font.lookup_glyph_index(c) == 0 {
            continue;
        }
        let m = font.metrics(c, sample_size);
        if m.width > 192 || m.height > 192 || m.width * m.height > 16_384 {
            continue;
        }
        let (_, pixels) = font.rasterize(c, sample_size);
        if let Some(width) = stroke_section(&pixels, m.width, m.height) {
            widths.push(width);
        }
    }
    widths.sort_by(f32::total_cmp);
    widths
        .get(widths.len() / 2)
        .map_or(fallback, |w| w * size / sample_size)
        .max(1.)
}

fn stroke_section(pixels: &[u8], width: usize, height: usize) -> Option<f32> {
    let inside = |x: i32, y: i32| {
        x >= 0
            && y >= 0
            && (x as usize) < width
            && (y as usize) < height
            && pixels[y as usize * width + x as usize] >= 128
    };
    let mut sections = vec![f32::INFINITY; pixels.len()];
    for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
        let step = if dx * dy == 0 {
            1.
        } else {
            std::f32::consts::SQRT_2
        };
        for (i, &pixel) in pixels.iter().enumerate() {
            let (x, y) = ((i % width) as i32, (i / width) as i32);
            // 仅在线段起点扫描，使每个方向的总工作量与采样面积成正比。
            if pixel < 128 || inside(x - dx, y - dy) {
                continue;
            }
            let mut n = 1;
            while inside(x + n * dx, y + n * dy) {
                n += 1;
            }
            let thickness = n as f32 * step;
            for t in 0..n {
                let slot = &mut sections[(y + t * dy) as usize * width + (x + t * dx) as usize];
                *slot = slot.min(thickness);
            }
        }
    }
    sections.retain(|v| v.is_finite());
    if sections.is_empty() {
        return None;
    }
    let middle = sections.len() / 2;
    let (_, value, _) = sections.select_nth_unstable_by(middle, f32::total_cmp);
    Some(*value)
}

enum Shape {
    Circle,
    Rectangle,
    Diamond,
}

pub(super) struct Frame {
    shape: Shape,
    center: Point,
    half_width: f32,
    half_height: f32,
}

pub(super) fn nodes(
    glyphs: &mut Glyphs<'_>,
    circuit: &Circuit,
    draw: &Drawing,
    size: f32,
    depth: usize,
    children: &mut Vec<PositionedGlyph>,
) -> Result<Vec<Frame>> {
    let mut result = Vec::new();
    let mut label_pixels = 0;
    for node in &circuit.decorations {
        let shape = match node.kind.as_str() {
            "circle" => Shape::Circle,
            "rectangle" => Shape::Rectangle,
            "diamond" => Shape::Diamond,
            _ => continue,
        };
        if result.iter().any(|f: &Frame| f.center == node.point) {
            return Err(Error::new("invalid_layout", "流程图的节点中心不能重合"));
        }
        let label = glyphs.sequence_at(&crate::text::parse(&node.text), size, depth + 1)?;
        label_pixels += label.mask.len();
        if label_pixels > 16_000_000 {
            return Err(Error::new("invalid_layout", "流程图节点文字超过内存预算"));
        }
        let unit = |pixels: u32| (pixels as f32 / 2. + 0.18 * size) / draw.scale;
        let (w, h) = (unit(label.mask.width()), unit(label.mask.height()));
        let (half_width, half_height) = match shape {
            Shape::Circle => {
                let r = w.hypot(h);
                (r, r)
            }
            Shape::Rectangle => (w, h),
            Shape::Diamond => (2. * w, 2. * h),
        };
        let (x, y) = draw.point(node.point);
        let xy = (
            x - (label.left + label.right()) / 2,
            y - (label.top + label.bottom()) / 2,
        );
        children.push((label, xy.0, xy.1));
        result.push(Frame {
            shape,
            center: node.point,
            half_width,
            half_height,
        });
    }
    Ok(result)
}

impl Frame {
    fn boundary(&self, towards: Point) -> Point {
        let (dx, dy) = (towards.0 - self.center.0, towards.1 - self.center.1);
        let (x, y) = (dx.abs() / self.half_width, dy.abs() / self.half_height);
        let divisor = match self.shape {
            Shape::Circle => x.hypot(y),
            Shape::Rectangle => x.max(y),
            Shape::Diamond => x + y,
        };
        Point(self.center.0 + dx / divisor, self.center.1 + dy / divisor)
    }

    pub(super) fn outline(&self, draw: &mut Drawing) {
        let Point(x, y) = self.center;
        let (w, h) = (self.half_width, self.half_height);
        if let Shape::Circle = self.shape {
            // 在斜向箭头与圆的交点也采样，确保圆弧和箭尖共享同一像素。
            let mut angles: Vec<_> = (0..48).map(|i| TAU * i as f32 / 48.).collect();
            for p in &draw.contacts {
                let (dx, dy) = (p.0 - x, p.1 - y);
                if (dx.hypot(dy) - w).abs() < 0.0001 {
                    angles.push(dy.atan2(dx).rem_euclid(TAU));
                }
            }
            angles.sort_by(f32::total_cmp);
            angles.push(TAU);
            draw.path(
                angles
                    .into_iter()
                    .map(|a| Point(x + w * a.cos(), y + h * a.sin()))
                    .collect(),
            );
            return;
        }
        let corners = match self.shape {
            Shape::Rectangle => [
                Point(x - w, y - h),
                Point(x + w, y - h),
                Point(x + w, y + h),
                Point(x - w, y + h),
            ],
            _ => [
                Point(x - w, y),
                Point(x, y - h),
                Point(x + w, y),
                Point(x, y + h),
            ],
        };
        for i in 0..4 {
            draw.line(corners[i], corners[(i + 1) % 4]);
        }
    }
}

pub(super) fn clip(segment: &Segment, nodes: &[Frame]) -> Result<Segment> {
    let endpoint = |start: Point, end: Point| {
        nodes
            .iter()
            .find(|f| f.center == start)
            .map_or(start, |f| f.boundary(end))
    };
    let mut clipped = segment.clone();
    clipped.start = endpoint(segment.start, segment.end);
    clipped.end = endpoint(segment.end, segment.start);
    let (dx, dy) = (
        segment.end.0 - segment.start.0,
        segment.end.1 - segment.start.1,
    );
    if (clipped.end.0 - clipped.start.0) * dx + (clipped.end.1 - clipped.start.1) * dy <= 0. {
        return Err(Error::new(
            "invalid_layout",
            "流程图连线太短，请增大相邻节点或折点的间距",
        ));
    }
    Ok(clipped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FontBook, text};

    #[test]
    fn flowchart_labels_and_outlines_follow_the_selected_body_font_and_size() {
        let folder =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
        let chart = |s: &str| {
            text::circuit::parse(&format!(
                r"\begin{{circuitikz}}[flowchart]{s}\end{{circuitikz}}"
            ))
            .unwrap()
        };
        for font in ["华阳手写体.ttf", "李国夫手写体.ttf"] {
            let book = FontBook::new(&std::fs::read(folder.join(font)).unwrap(), &[]).unwrap();
            let mut glyphs = Glyphs::new(&book);
            for size in [24., 34., 48.] {
                let condition = "i ≤ 10";
                let label = glyphs
                    .circuit(
                        &chart(&format!(r"\draw (0,0) node[right]{{{condition}}};")),
                        size,
                        0,
                    )
                    .unwrap();
                let body = glyphs.sequence(&text::parse(condition), size).unwrap();
                assert_eq!(label.mask, body.mask, "{font} {size} condition");
                let body = glyphs.sequence(&text::parse("B6"), size).unwrap();
                let node = glyphs
                    .circuit(&chart(r"\draw (0,0) node[rectangle]{B6};"), size, 0)
                    .unwrap();
                let (w, h) = node.mask.dimensions();
                let (bw, bh) = body.mask.dimensions();
                assert!(
                    (0..=w - bw).any(|x| (0..=h - bh).any(|y| image::imageops::crop_imm(
                        &node.mask, x, y, bw, bh
                    )
                    .to_image()
                        == body.mask)),
                    "{font} {size} node label"
                );
                let border: f32 = (0..h)
                    .map(|y| f32::from(node.mask[(w / 2, y)][0]) / 255.)
                    .take_while(|v| *v > 0.)
                    .sum();
                let measured = pen_width(book.primary(), size, glyphs.pen.thickness(size));
                assert!(
                    (border - measured).abs() < 0.01,
                    "{font} {size} border: {border}"
                );
                let solid_width = (0..h)
                    .map(|y| node.mask[(w / 2, y)][0])
                    .take_while(|v| *v > 0)
                    .filter(|v| *v >= 128)
                    .count();
                assert_eq!(solid_width, measured.round() as usize, "{font} {size}");
            }
        }
    }

    #[test]
    fn edges_stop_at_shaped_boundaries_in_writing_direction() {
        let source = r"\begin{circuitikz}[flowchart]\draw[->] (0,0) -- (4,4);\end{circuitikz}";
        let segment = &text::circuit::parse(source).unwrap().segments[0];
        for (shape, first) in [
            (Shape::Circle, 2_f32.sqrt()),
            (Shape::Rectangle, 2.),
            (Shape::Diamond, 1.),
        ] {
            let nodes = [
                Frame {
                    shape,
                    center: Point(0., 0.),
                    half_width: 2.,
                    half_height: 2.,
                },
                Frame {
                    shape: Shape::Rectangle,
                    center: Point(4., 4.),
                    half_width: 0.5,
                    half_height: 0.75,
                },
            ];
            let clipped = clip(segment, &nodes).unwrap();
            assert!(
                (clipped.start.0 - first).abs() < 0.0001
                    && (clipped.start.1 - first).abs() < 0.0001
            );
            assert_eq!(clipped.end, Point(3.5, 3.5));
            assert!(clipped.end_arrow);
        }
    }
}
