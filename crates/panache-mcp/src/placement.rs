//! Map the original paper-space layout to a baseline or to exact corners on the photograph.
use crate::NaturalLine;
use anyhow::{Result, ensure};
use handwriting_core::fine_edit::{Adjustment, GlyphBounds};
use handwriting_core::photo::PaperProjection;
use serde::Serialize;

#[derive(Serialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum PlacementReport {
    NaturalLine {
        scale_percent: u8,
        used_paper_px: f64,
        available_paper_px: f64,
    },
    TargetQuad {
        max_glyph_center_axis_ratio: f64,
    },
}

impl PlacementReport {
    pub fn summary(&self) -> String {
        match self {
            Self::NaturalLine {
                scale_percent,
                used_paper_px,
                available_paper_px,
            } => format!(
                "Natural line at {scale_percent}% uniform size uses {used_paper_px:.1} of {available_paper_px:.1} paper pixels."
            ),
            Self::TargetQuad {
                max_glyph_center_axis_ratio: ratio,
            } => {
                let advice = if *ratio >= 1.15 {
                    " For proportional lettering along a worksheet row, use natural_line."
                } else {
                    ""
                };
                format!(
                    "Exact four-corner warp. The largest local major/minor scale ratio sampled at glyph centers is {ratio:.2}× in paper space.{advice}"
                )
            }
        }
    }
}

fn paper_points<const N: usize>(
    projection: Option<&PaperProjection>,
    size: [u32; 2],
    points: [[u32; 2]; N],
) -> Result<[[f64; 2]; N]> {
    let mut result = [[0.; 2]; N];
    for (dst, src) in result.iter_mut().zip(points) {
        ensure!(
            src[0] < size[0] && src[1] < size[1],
            "Target point outside the image"
        );
        let pt = src.map(|v| v as f32);
        *dst = projection.map_or(pt, |m| m.paper_point(pt)).map(f64::from);
        ensure!(
            dst.iter().all(|v| v.is_finite()),
            "Invalid paper coordinates"
        );
    }
    Ok(result)
}

fn selection_bounds(glyphs: &[GlyphBounds]) -> Result<[f64; 4]> {
    let mut left = f64::INFINITY;
    let mut top = f64::INFINITY;
    let mut right = f64::NEG_INFINITY;
    let mut bottom = f64::NEG_INFINITY;
    for glyph in glyphs {
        let [x, y, w, h] = glyph.bounds.map(f64::from);
        left = left.min(x);
        top = top.min(y);
        right = right.max(x + w);
        bottom = bottom.max(y + h);
    }
    ensure!(right > left && bottom > top, "Empty selection");
    Ok([left, top, right - left, bottom - top])
}

pub struct Placement {
    // Paper-space homography normalized at the source origin.
    matrix: [f64; 8],
    origin: [f64; 2],
}
impl Placement {
    pub fn natural_line(
        projection: Option<&PaperProjection>,
        size: [u32; 2],
        glyphs: &[GlyphBounds],
        line: &NaturalLine,
    ) -> Result<(Self, PlacementReport)> {
        let [start, end] = paper_points(projection, size, [line.start, line.end])?;
        let [left, _, width, _] = selection_bounds(glyphs)?;
        let baseline = glyphs[0].baseline;
        ensure!(
            glyphs.iter().all(|g| g.baseline == baseline
                && g.illustration.is_none()
                && !g.is_native_diagram),
            "Select text on one original layout baseline for natural_line; place each source line separately"
        );
        let scale_percent = line.scale_percent.unwrap_or(100);
        ensure!(
            (50..=200).contains(&scale_percent),
            "natural_line scale_percent must be 50..200"
        );
        let scale = f64::from(scale_percent) / 100.;
        let (dx, dy) = (end[0] - start[0], end[1] - start[1]);
        let available = dx.hypot(dy);
        ensure!(
            available > 0.,
            "Supply two distinct natural_line baseline points"
        );
        let used = width * scale;
        ensure!(
            used <= available,
            "Selection needs {used:.1} paper pixels at {scale_percent}%; only {available:.1} are available. Split the line, extend the baseline, or choose a smaller uniform scale_percent for the worksheet."
        );
        let (a, b) = (scale * dx / available, scale * dy / available);
        Ok((
            Self {
                matrix: [a, -b, start[0], b, a, start[1], 0., 0.],
                origin: [left, f64::from(baseline)],
            },
            PlacementReport::NaturalLine {
                scale_percent,
                used_paper_px: used,
                available_paper_px: available,
            },
        ))
    }

    pub fn target_quad(
        projection: Option<&PaperProjection>,
        size: [u32; 2],
        glyphs: &[GlyphBounds],
        quad: [[u32; 2]; 4],
    ) -> Result<(Self, PlacementReport)> {
        let corners = paper_points(projection, size, quad)?;
        for i in 0..4 {
            let [a, b, c] = [corners[i], corners[(i + 1) % 4], corners[(i + 2) % 4]];
            ensure!(
                (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) > 0.01,
                "Supply a convex TL, TR, BR, BL quadrilateral"
            );
        }
        let [left, top, w, h] = selection_bounds(glyphs)?;
        let [[x0, y0], [x1, y1], [x2, y2], [x3, y3]] = corners;
        let (ax, ay) = (x1 - x2, y1 - y2);
        let (bx, by) = (x3 - x2, y3 - y2);
        let (dx, dy) = (x0 - x1 + x2 - x3, y0 - y1 + y2 - y3);
        // Solve the two perspective coefficients of the unit-square-to-quad map.
        let det = ax * by - ay * bx;
        let g = (dx * by - dy * bx) / det;
        let k = (ax * dy - ay * dx) / det;
        let placement = Self {
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
        };
        let mut max_ratio: f64 = 1.;
        for glyph in glyphs {
            let [x, y, w, h] = glyph.bounds.map(f64::from);
            let ratio = placement.axis_ratio_at(x + w / 2. - left, y + h / 2. - top);
            ensure!(ratio.is_finite(), "Degenerate perspective at glyph center");
            max_ratio = max_ratio.max(ratio);
        }
        Ok((
            placement,
            PlacementReport::TargetQuad {
                max_glyph_center_axis_ratio: max_ratio,
            },
        ))
    }

    // Singular-value ratio of the local Jacobian. Its common scale cancels.
    fn axis_ratio_at(&self, u: f64, v: f64) -> f64 {
        let [a, b, c, d, e, f, g, k] = self.matrix;
        let z = 1. + g * u + k * v;
        let x = (a * u + b * v + c) / z;
        let y = (d * u + e * v + f) / z;
        let [a, b, d, e] = [a - x * g, b - x * k, d - y * g, e - y * k];
        let major = ((a + e).hypot(d - b) + (a - e).hypot(d + b)) / 2.;
        major * major / (a * e - b * d).abs()
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

#[cfg(test)]
mod tests {
    use super::*;

    fn glyph(bounds: [i32; 4], id: u32) -> GlyphBounds {
        GlyphBounds {
            bounds,
            id,
            baseline: 80,
            is_text: true,
            is_native_diagram: false,
            is_grid_table: false,
            source_utf16: None,
            illustration: None,
        }
    }

    #[test]
    fn natural_line_respects_photo_direction_and_original_baseline_for_inline_math() {
        let projection = PaperProjection::Rotated {
            angle: std::f32::consts::FRAC_PI_2,
            layout_center: [150., 150.],
            photo_center: [150., 150.],
        };
        let mut glyphs = [glyph([10, 50, 20, 25], 0), glyph([50, 45, 15, 28], 1)];
        glyphs[1].is_text = false; // A formula shares the text baseline.
        let line = NaturalLine {
            start: [130, 100],
            end: [130, 200],
            scale_percent: Some(125),
        };
        let (placement, report) =
            Placement::natural_line(Some(&projection), [300, 300], &glyphs, &line).unwrap();
        assert!(
            matches!(report, PlacementReport::NaturalLine { used_paper_px, available_paper_px, .. }
            if (used_paper_px - 68.75).abs() < 1e-6 && (available_paper_px - 100.).abs() < 1e-4)
        );
        let [a, b, x0, d, e, y0, _, _] = placement.matrix;
        for (x, y) in [(10., 80.), (65., 80.), (50., 45.)] {
            let (u, v) = (x - placement.origin[0], y - placement.origin[1]);
            let [photo_x, photo_y] =
                projection.photo_point((a * u + b * v + x0) as f32, (d * u + e * v + y0) as f32);
            assert!((f64::from(photo_x) - (130. - 1.25 * (y - 80.))).abs() < 1e-4);
            assert!((f64::from(photo_y) - (100. + 1.25 * (x - 10.))).abs() < 1e-4);
        }
        glyphs[1].illustration = Some(1);
        assert!(Placement::natural_line(Some(&projection), [300, 300], &glyphs, &line).is_err());
    }

    #[test]
    fn exact_quad_keeps_illustrations_and_measures_shear_even_with_equal_edge_lengths() {
        let mut glyph = glyph([0, 0, 10, 10], 0);
        glyph.is_text = false;
        glyph.illustration = Some(0);
        // Both destination axes have length 5 but their angle is no longer 90°.
        let (_, report) = Placement::target_quad(
            None,
            [30, 30],
            &[glyph],
            [[10, 10], [15, 10], [18, 14], [13, 14]],
        )
        .unwrap();
        assert!(
            matches!(report, PlacementReport::TargetQuad { max_glyph_center_axis_ratio }
            if (max_glyph_center_axis_ratio - 2.).abs() < 1e-10)
        );
    }
}
