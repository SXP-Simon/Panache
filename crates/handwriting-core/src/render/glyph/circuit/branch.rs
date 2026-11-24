//! Circuit symbols and annotations use coordinates relative to the directed branch.
use super::{Drawing, Point};
use crate::{Error, Result, text::circuit::Segment};
use std::f32::consts::PI;

pub(super) fn draw(
    draw: &mut Drawing,
    segment: &Segment,
    american: bool,
    labels: &mut Vec<(String, Point, i32)>,
) -> Result<()> {
    let a = segment.start;
    let b = segment.end;
    let frame = BranchFrame::between(a, b);
    match segment.kind.as_str() {
        "short" => {
            draw.line(a, b);
            if segment.end_arrow {
                draw.arrowhead(a, b);
            }
        }
        "open" => (),
        kind => {
            draw.line(a, frame.point(-frame.half, 0.));
            draw.line(frame.point(frame.half, 0.), b);
            frame.symbol(draw, kind, american)?;
        }
    }
    for (point, mark) in [(a, segment.marks.0), (b, segment.marks.1)] {
        if mark == '*' || mark == 'o' {
            draw.dot(point, mark == 'o');
        }
    }
    frame.annotate(draw, segment, labels);
    Ok(())
}

struct BranchFrame {
    mid: Point,
    ux: f32,
    uy: f32,
    half: f32,
    height: f32,
}

impl BranchFrame {
    fn between(a: Point, b: Point) -> Self {
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let length = dx.hypot(dy);
        let half = 0.38f32.min(length * 0.32);
        Self {
            mid: Point((a.0 + b.0) / 2., (a.1 + b.1) / 2.),
            ux: dx / length,
            uy: dy / length,
            half,
            height: 0.15f32.min(half * 0.6),
        }
    }

    fn point(&self, x: f32, y: f32) -> Point {
        Point(
            self.mid.0 + self.ux * x - self.uy * y,
            self.mid.1 + self.uy * x + self.ux * y,
        )
    }

    fn symbol(&self, draw: &mut Drawing, kind: &str, american: bool) -> Result<()> {
        let (half, h) = (self.half, self.height);
        match kind {
            "R" if american => {
                let mut points = vec![self.point(-half, 0.)];
                for i in 0..7 {
                    points.push(self.point(
                        -half + half * (i as f32 + 0.5) / 3.5,
                        if i % 2 == 0 { h } else { -h },
                    ));
                }
                points.push(self.point(half, 0.));
                draw.path(points);
            }
            "R" => draw.path(vec![
                self.point(-half, 0.),
                self.point(-half, h),
                self.point(half, h),
                self.point(half, 0.),
                self.point(half, -h),
                self.point(-half, -h),
                self.point(-half, 0.),
            ]),
            "C" => self.plates(draw, [(-0.055, h * 1.5), (0.055, h * 1.5)]),
            "L" => self.coil(draw),
            "V" | "I" | "sV" => self.source(draw, kind),
            "battery1" => self.plates(draw, [(0.055, h * 1.5), (-0.055, h * 0.75)]),
            "D" | "led" => {
                draw.line(self.point(-half, 0.), self.point(-h, 0.));
                draw.line(self.point(h, 0.), self.point(half, 0.));
                draw.path(vec![
                    self.point(-h, -h),
                    self.point(h, 0.),
                    self.point(-h, h),
                    self.point(-h, 0.),
                    self.point(-h, -h),
                ]);
                draw.line_through(self.point(h, -h), self.point(h, 0.), self.point(h, h));
                if kind == "led" {
                    draw.arrow(self.point(0., h * 1.7), self.point(h * 0.9, h * 2.6));
                    draw.arrow(self.point(h * 0.9, h * 1.7), self.point(h * 1.8, h * 2.6));
                }
            }
            "switch" | "closing switch" | "opening switch" => {
                draw.dot(self.point(-half, 0.), true);
                draw.dot(self.point(half, 0.), true);
                draw.line(
                    self.point(-half + 0.055, 0.),
                    self.point(half - 0.055, h * 1.7),
                );
                if kind != "switch" {
                    let (a, b) = if kind == "closing switch" {
                        (self.point(0., h * 2.5), self.point(0., h * 0.8))
                    } else {
                        (self.point(0., h * 0.8), self.point(0., h * 2.5))
                    };
                    draw.arrow(a, b);
                }
            }
            _ => return Err(Error::new("invalid_layout", "不支持的电路元件")),
        }
        Ok(())
    }

    fn plates(&self, draw: &mut Drawing, plates: [(f32, f32); 2]) {
        draw.line(self.point(-self.half, 0.), self.point(-0.055, 0.));
        draw.line(self.point(0.055, 0.), self.point(self.half, 0.));
        for (x, height) in plates {
            draw.line_through(
                self.point(x, -height),
                self.point(x, 0.),
                self.point(x, height),
            );
        }
    }

    fn coil(&self, draw: &mut Drawing) {
        let half = self.half;
        let radius = half / 4.;
        let mut points = Vec::new();
        for loop_index in 0..4 {
            for i in 0..=12 {
                let t = PI - i as f32 * PI / 12.;
                points.push(self.point(
                    -half + radius * (2. * loop_index as f32 + 1.) + radius * t.cos(),
                    radius * t.sin() * 1.9,
                ));
            }
        }
        draw.path(points);
    }

    fn source(&self, draw: &mut Drawing, kind: &str) {
        let (half, h) = (self.half, self.height);
        let radius = 0.32f32.min(half);
        draw.line(self.point(-half, 0.), self.point(-radius, 0.));
        draw.line(self.point(radius, 0.), self.point(half, 0.));
        draw.contact_circle(self.mid, radius, self.uy.atan2(self.ux));
        if kind == "I" {
            draw.arrow(
                self.point(-radius * 0.55, 0.),
                self.point(radius * 0.55, 0.),
            );
        } else if kind == "V" {
            let plus = self.point(radius * 0.48, 0.);
            let minus = self.point(-radius * 0.48, 0.);
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
                            self.mid.0 + x,
                            self.mid.1 + (i as f32 * 2. * PI / 24.).sin() * h * 0.7,
                        )
                    })
                    .collect(),
            );
        }
    }

    fn annotate(
        &self,
        draw: &mut Drawing,
        segment: &Segment,
        labels: &mut Vec<(String, Point, i32)>,
    ) {
        let kind = segment.kind.as_str();
        let half = self.half;
        let mut lanes = [0usize; 2];
        for label in &segment.labels {
            let side = if label.kind == 'a' {
                -label.side
            } else {
                label.side
            };
            let occupied = &mut lanes[usize::from(side > 0.)];
            let base = if side > 0. && matches!(kind, "led" | "closing switch" | "opening switch") {
                0.85
            } else {
                0.48
            };
            let offset = base + *occupied as f32 * 0.55;
            *occupied += 1;
            let has_arrow = matches!(label.kind, 'i' | 'v');
            let pos = if has_arrow {
                self.point(0., (offset + 0.34) * side)
            } else {
                self.point(0., offset * side)
            };
            let anchor = if self.uy.abs() > 0.5 {
                if -self.uy * side < 0. { -1 } else { 1 }
            } else {
                0
            };
            labels.push((label.text.clone(), pos, anchor));
            if has_arrow {
                draw.arrow(
                    self.point(-half * 1.1 * label.direction, (offset + 0.05) * side),
                    self.point(half * 1.1 * label.direction, (offset + 0.05) * side),
                );
            }
        }
    }
}
