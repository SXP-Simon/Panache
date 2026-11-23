//! Place a selection's original layout rectangle into four corners on the photograph.
use crate::drafts::Snapshot;
use anyhow::{Result, ensure};
use handwriting_core::fine_edit::{Adjustment, GlyphBounds};
use std::collections::BTreeSet;

pub struct Placement {
    // Paper-space homography normalized at the selection's top left.
    matrix: [f64; 8],
    origin: [f64; 2],
}
impl Placement {
    pub fn new(
        draft: &Snapshot<'_>,
        size: [u32; 2],
        glyphs: &[GlyphBounds],
        ids: &BTreeSet<u32>,
        quad: [[u32; 2]; 4],
    ) -> Result<Self> {
        let mut corners = [[0.; 2]; 4];
        let map = draft.paper.as_ref().and_then(|p| p.projection.as_ref());
        for (dst, src) in corners.iter_mut().zip(quad) {
            ensure!(
                src[0] < size[0] && src[1] < size[1],
                "Target corner outside the image"
            );
            let pt = src.map(|v| v as f32);
            *dst = map.map_or(pt, |m| m.paper_point(pt)).map(f64::from);
        }
        for i in 0..4 {
            let [a, b, c] = [corners[i], corners[(i + 1) % 4], corners[(i + 2) % 4]];
            ensure!(
                (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) > 0.01,
                "Supply a convex TL, TR, BR, BL quadrilateral"
            );
        }
        let mut left = f64::INFINITY;
        let mut top = f64::INFINITY;
        let mut right = f64::NEG_INFINITY;
        let mut bottom = f64::NEG_INFINITY;
        for g in glyphs.iter().filter(|g| ids.contains(&g.id)) {
            let [x, y, w, h] = g.bounds.map(f64::from);
            left = left.min(x);
            top = top.min(y);
            right = right.max(x + w);
            bottom = bottom.max(y + h);
        }
        let (w, h) = (right - left, bottom - top);
        ensure!(w > 0. && h > 0., "Empty selection");
        let [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = corners;
        let (ax, ay) = (x1 - x2, y1 - y2);
        let (bx, by) = (x3 - x2, y3 - y2);
        let (dx, dy) = (x0 - x1 + x2 - x3, y0 - y1 + y2 - y3);
        // Solve the two perspective coefficients of the unit-square-to-quad map.
        let det = ax * by - ay * bx;
        let g = (dx * by - dy * bx) / det;
        let k = (ax * dy - ay * dx) / det;
        Ok(Self {
            origin: [left, top],
            matrix: [
                (x1 * (1. + g) - x0) / w,
                (x3 * (1. + k) - x0) / h,
                x0,
                (y1 * (1. + g) - y0) / w,
                (y3 * (1. + k) - y0) / h,
                y0,
                g / w,
                k / h,
            ],
        })
    }

    pub fn apply(&self, edit: &mut Adjustment, bounds: [i32; 4]) -> Result<()> {
        let [x, y, w, h] = bounds.map(f64::from);
        let center = [x + w / 2., y + h / 2.];
        let (u, v) = (center[0] - self.origin[0], center[1] - self.origin[1]);
        let [a, b, c, d, e, f, g, k] = self.matrix;
        let z = 1. + g * u + k * v;
        ensure!(
            z.is_finite() && z > 1e-8,
            "Selection crosses the perspective horizon"
        );
        let nx = a * u + b * v + c;
        let ny = d * u + e * v + f;
        edit.dx = (nx / z - center[0]).round() as i32;
        edit.dy = (ny / z - center[1]).round() as i32;
        let (cx, cy) = (
            center[0] + f64::from(edit.dx),
            center[1] + f64::from(edit.dy),
        );
        // The renderer applies a tile-local transform around the translated center.
        // Conjugate the shared block transform into that frame, retaining subpixel translation.
        let warp = [
            a - cx * g,
            b - cx * k,
            nx - cx * z,
            d - cy * g,
            e - cy * k,
            ny - cy * z,
            g,
            k,
        ]
        .map(|p| p / z);
        ensure!(
            warp.iter().all(|p| p.abs() <= 65535.)
                && (-65535..=65535).contains(&edit.dx)
                && (-65535..=65535).contains(&edit.dy),
            "Perspective exceeds supported coordinates"
        );
        edit.angle = 0;
        edit.scale = 100;
        edit.warp = Some(warp);
        Ok(())
    }
}
