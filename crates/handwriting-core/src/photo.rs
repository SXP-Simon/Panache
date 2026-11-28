//! Paper-space layout projected onto a photograph using the measured printed rulings.
use crate::{Cancellation, Result};
use image::RgbaImage;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub enum PaperProjection {
    Rotated {
        angle: f32,
        photo_center: [f32; 2],
        layout_center: [f32; 2],
    },
    Rulings {
        first: f32,
        step: f32,
        layout_edges: [f32; 2],
        columns: [f32; 9],
        rows: Vec<Ruling>,
    },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Ruling {
    pub edges: [f32; 2],
    pub heights: [f32; 9],
}

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

fn height(row: &Ruling, cols: &[f32; 9], x: f32) -> f32 {
    let i = cols
        .partition_point(|v| *v < x)
        .saturating_sub(1)
        .min(cols.len() - 2);
    lerp(
        row.heights[i],
        row.heights[i + 1],
        (x - cols[i]) / (cols[i + 1] - cols[i]),
    )
}

fn edges(a: &Ruling, b: &Ruling, t: f32) -> [f32; 2] {
    std::array::from_fn(|i| lerp(a.edges[i], b.edges[i], t.clamp(0., 1.)))
}
fn rotate([x, y]: [f32; 2], from: [f32; 2], to: [f32; 2], sin: f32, cos: f32) -> [f32; 2] {
    let (x, y) = (x - from[0], y - from[1]);
    [x * cos - y * sin + to[0], x * sin + y * cos + to[1]]
}
impl PaperProjection {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Rotated { .. } => "rotated",
            Self::Rulings { .. } => "tracked_rulings",
        }
    }
    pub fn photo_point(&self, x: f32, y: f32) -> [f32; 2] {
        match self {
            Self::Rotated {
                angle,
                photo_center,
                layout_center,
            } => {
                let (sin, cos) = angle.sin_cos();
                rotate([x, y], *layout_center, *photo_center, sin, cos)
            }
            Self::Rulings {
                first,
                step,
                layout_edges: [l, r],
                columns,
                rows,
            } => {
                let f = (y - first) / step;
                let i = (f.floor() as usize).min(rows.len() - 2);
                let t = f - i as f32;
                let (a, b) = (&rows[i], &rows[i + 1]);
                let [left, right] = edges(a, b, t);
                let px = lerp(left, right, (x - l) / (r - l));
                [px, lerp(height(a, columns, px), height(b, columns, px), t)]
            }
        }
    }

    /// Convert a photo-space target to the layout coordinates used by glyph edits.
    pub fn paper_point(&self, [x, y]: [f32; 2]) -> [f32; 2] {
        match self {
            Self::Rotated {
                angle,
                photo_center,
                layout_center,
            } => {
                let (sin, cos) = (-angle).sin_cos();
                rotate([x, y], *photo_center, *layout_center, sin, cos)
            }
            Self::Rulings {
                first,
                step,
                layout_edges: [l, r],
                columns,
                rows,
            } => {
                let i = rows
                    .partition_point(|row| height(row, columns, x) < y)
                    .saturating_sub(1)
                    .min(rows.len() - 2);
                let ya = height(&rows[i], columns, x);
                let t = (y - ya) / (height(&rows[i + 1], columns, x) - ya);
                let [left, right] = edges(&rows[i], &rows[i + 1], t);
                [
                    lerp(*l, *r, (x - left) / (right - left)),
                    first + (i as f32 + t) * step,
                ]
            }
        }
    }

    /// Inverse-sample just the transparent handwriting and illustration layer.
    pub fn composite(
        &self,
        photo: &RgbaImage,
        ink: &RgbaImage,
        cancel: &Cancellation,
    ) -> Result<RgbaImage> {
        self.composite_into(photo.clone(), ink, cancel)
    }

    pub(crate) fn composite_into(
        &self,
        mut out: RgbaImage,
        ink: &RgbaImage,
        cancel: &Cancellation,
    ) -> Result<RgbaImage> {
        match self {
            Self::Rotated {
                angle,
                photo_center,
                layout_center,
            } => {
                let (sin, cos) = (-angle).sin_cos();
                for (y, row) in out.rows_mut().enumerate() {
                    cancel.check()?;
                    for (x, p) in row.enumerate() {
                        blend(
                            p,
                            ink,
                            rotate(
                                [x as f32, y as f32],
                                *photo_center,
                                *layout_center,
                                sin,
                                cos,
                            ),
                        );
                    }
                }
            }
            Self::Rulings {
                first,
                step,
                layout_edges: [l, r],
                columns,
                rows,
            } => {
                let mut ys = vec![0.; rows.len()];
                for x in 0..out.width() {
                    cancel.check()?;
                    for (v, row) in ys.iter_mut().zip(rows) {
                        *v = height(row, columns, x as f32);
                    }
                    let mut i = 0;
                    for y in 0..out.height() {
                        while i + 2 < rows.len() && y as f32 > ys[i + 1] {
                            i += 1;
                        }
                        let t = (y as f32 - ys[i]) / (ys[i + 1] - ys[i]);
                        let [left, right] = edges(&rows[i], &rows[i + 1], t);
                        let point = [
                            lerp(*l, *r, (x as f32 - left) / (right - left)),
                            first + (i as f32 + t) * step,
                        ];
                        blend(&mut out[(x, y)], ink, point);
                    }
                }
            }
        }
        Ok(out)
    }
}

// Interpolate premultiplied channels so the edge of dark or colored ink never gains a halo.
fn blend(dst: &mut image::Rgba<u8>, src: &RgbaImage, [x, y]: [f32; 2]) {
    if !(x >= 0. && y >= 0. && x < src.width() as f32 && y < src.height() as f32) {
        return;
    }
    let (ix, iy) = (x as u32, y as u32);
    let (tx, ty) = (x - ix as f32, y - iy as f32);
    let (jx, jy) = (
        (ix + 1).min(src.width() - 1),
        (iy + 1).min(src.height() - 1),
    );
    let mut sum = [0.; 3];
    let mut alpha = 0.;
    for (sx, sy, weight) in [
        (ix, iy, (1. - tx) * (1. - ty)),
        (jx, iy, tx * (1. - ty)),
        (ix, jy, (1. - tx) * ty),
        (jx, jy, tx * ty),
    ] {
        let p = src[(sx, sy)];
        let a = weight * f32::from(p[3]) / 255.;
        alpha += a;
        for (s, c) in sum.iter_mut().zip(p.0) {
            *s += a * f32::from(c);
        }
    }
    if alpha > 0. {
        let residual = (1. - alpha) * f32::from(dst[3]) / 255.;
        let out_a = alpha + residual;
        for (c, s) in dst.0[..3].iter_mut().zip(sum) {
            *c = ((s + residual * f32::from(*c)) / out_a).round() as u8;
        }
        dst[3] = (255. * out_a).round() as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;
    #[test]
    fn inverse_sampling_keeps_photo_and_tracks_slanted_widening_rulings() {
        let columns = std::array::from_fn(|i| i as f32 * 8.);
        let map = PaperProjection::Rulings {
            first: 16.,
            step: 16.,
            layout_edges: [16., 48.],
            columns,
            rows: vec![
                Ruling {
                    edges: [20., 44.],
                    heights: columns.map(|x| 24. - x / 8.),
                },
                Ruling {
                    edges: [8., 56.],
                    heights: columns.map(|x| 48. - x / 8.),
                },
            ],
        };
        let photo = RgbaImage::from_fn(65, 65, |x, y| Rgba([x as u8, y as u8, 180, 255]));
        let mut ink = RgbaImage::new(65, 65);
        for y in [16, 32] {
            for x in 16..=48 {
                ink[(x, y)] = Rgba([255, 0, 0, 255]);
            }
        }
        let result = map
            .composite(&photo, &ink, &Cancellation::default())
            .unwrap();
        for (px, py) in [(24, 21), (40, 19), (8, 47), (56, 41)] {
            assert_eq!(result[(px, py)], Rgba([255, 0, 0, 255]));
        }
        for [x, y] in [[16., 32.], [20., 20.], [43., 27.], [42., 12.]] {
            let back = map.paper_point(map.photo_point(x, y));
            assert!((back[0] - x).abs() < 1e-4 && (back[1] - y).abs() < 1e-4);
        }
        assert_eq!(map.photo_point(16., 32.), [8., 47.]);
        assert_eq!(map.photo_point(48., 32.), [56., 41.]);
        assert_eq!(result[(32, 32)], photo[(32, 32)]);
        let cancelled = Cancellation::default();
        cancelled.cancel();
        assert!(map.composite(&photo, &ink, &cancelled).is_err());
    }
}
