//! 2026-10-15：墨迹掩码合成与连通区域扰动，独立于行布局和分页。
use super::Cancellation;
use crate::{Parameters, Result};
use image::{GrayImage, Luma, Rgba, RgbaImage};
use rand_chacha::ChaCha8Rng;
use rand_distr::{Distribution, StandardNormal};

pub(super) fn normal(rng: &mut ChaCha8Rng, sigma: f32) -> f32 {
    if sigma == 0. {
        0.
    } else {
        let n: f32 = StandardNormal.sample(rng);
        n * sigma
    }
}
pub(super) fn paste_mask(dest: &mut GrayImage, src: &GrayImage, x: i32, y: i32) {
    for (xx, yy, p) in src.enumerate_pixels() {
        let dx = x + xx as i32;
        let dy = y + yy as i32;
        if dx >= 0 && dy >= 0 && dx < dest.width() as i32 && dy < dest.height() as i32 {
            dest[(dx as u32, dy as u32)][0] = dest[(dx as u32, dy as u32)][0].max(p[0]);
        }
    }
}
// 2026-10-12：四邻域连通区域整体扰动；旋转方向沿用 handright，算法许可见 NOTICE。
pub(super) fn perturb(
    mask: &mut GrayImage,
    canvas: &mut RgbaImage,
    p: &Parameters,
    rng: &mut ChaCha8Rng,
    cancel: &Cancellation,
) -> Result<()> {
    let (w, h) = mask.dimensions();
    let mut stack = Vec::new();
    let mut component = Vec::new();
    for y in 0..h {
        if y % 32 == 0 {
            cancel.check()?;
        }
        for x in 0..w {
            if mask[(x, y)][0] < 128 {
                continue;
            }
            stack.push((x, y));
            mask[(x, y)] = Luma([0]);
            let (mut minx, mut maxx, mut miny, mut maxy) = (x, x, y, y);
            while let Some((xx, yy)) = stack.pop() {
                component.push((xx, yy));
                minx = minx.min(xx);
                maxx = maxx.max(xx);
                miny = miny.min(yy);
                maxy = maxy.max(yy);
                if component.len() % 8192 == 0 {
                    cancel.check()?;
                }
                for (nx, ny) in [
                    (xx as i32 - 1, yy as i32),
                    (xx as i32 + 1, yy as i32),
                    (xx as i32, yy as i32 - 1),
                    (xx as i32, yy as i32 + 1),
                ] {
                    if nx >= 0
                        && ny >= 0
                        && nx < w as i32
                        && ny < h as i32
                        && mask[(nx as u32, ny as u32)][0] >= 128
                    {
                        mask[(nx as u32, ny as u32)] = Luma([0]);
                        stack.push((nx as u32, ny as u32));
                    }
                }
            }
            let cx = (minx + maxx) as f32 / 2.;
            let cy = (miny + maxy) as f32 / 2.;
            let dx = normal(rng, p.perturb_x_sigma);
            let dy = normal(rng, p.perturb_y_sigma);
            let angle = normal(rng, p.perturb_theta_sigma);
            let ink = normal(rng, p.ink_depth_sigma);
            let fill = Rgba([
                (p.fill[0] as f32 + ink).clamp(0., 255.) as u8,
                (p.fill[1] as f32 + ink).clamp(0., 255.) as u8,
                (p.fill[2] as f32 + ink).clamp(0., 255.) as u8,
                p.fill[3],
            ]);
            for (xx, yy) in component.drain(..) {
                let rx = xx as f32 - cx;
                let ry = yy as f32 - cy;
                let nx = (rx * angle.cos() + ry * angle.sin() + cx + dx).round() as i32;
                let ny = (ry * angle.cos() - rx * angle.sin() + cy + dy).round() as i32;
                if nx >= 0 && ny >= 0 && nx < w as i32 && ny < h as i32 {
                    use image::Pixel;
                    canvas[(nx as u32, ny as u32)].blend(&fill);
                }
            }
        }
    }
    Ok(())
}

// 2026-10-15：空白纸张与横线只负责背景像素，不参与分页。
pub(super) fn blank_paper(w: u32, h: u32, p: &Parameters) -> RgbaImage {
    let mut bg = RgbaImage::from_pixel(w, h, Rgba([255, 255, 255, 255]));
    if p.underlined {
        // 2026-10-18：纸张缩入 Word 后仍保留横线覆盖率，不使用固定单像素线。
        let thickness = w.div_ceil(600).max(1);
        let mut row = 1usize;
        loop {
            let y = p.top_margin + row as f32 * p.line_spacing;
            if y >= h as f32 - p.bottom_margin {
                break;
            }
            imageproc::drawing::draw_filled_rect_mut(
                &mut bg,
                imageproc::rect::Rect::at(p.left_margin as i32, y as i32 - (thickness / 2) as i32)
                    .of_size(
                        ((w as f32 - p.right_margin - p.left_margin).max(0.) as u32 + 1).max(1),
                        thickness,
                    ),
                Rgba([0, 0, 0, 255]),
            );
            row += 1;
        }
    }
    bg
}

mod rigid;
pub(super) use rigid::paint_math_unit;

#[cfg(test)]
mod paper_tests {
    use super::*;
    use image::imageops::{FilterType, resize};

    #[test]
    fn every_rule_survives_document_downscaling() {
        for (w, h, spacing, top) in [(1600, 600, 120., 100.), (3481, 600, 150.3, 50.)] {
            let p = Parameters {
                underlined: true,
                line_spacing: spacing,
                top_margin: top,
                bottom_margin: 100.,
                left_margin: 80.,
                right_margin: 80.,
                ..Parameters::default()
            };
            let paper = blank_paper(w, h, &p);
            for width in [640, 1270] {
                let height = (h as f64 * width as f64 / w as f64).round() as u32;
                for filter in [
                    FilterType::Nearest,
                    FilterType::Triangle,
                    FilterType::Lanczos3,
                ] {
                    let small = resize(&paper, width, height, filter);
                    let mut row = 1;
                    while top + row as f32 * spacing < h as f32 - 100. {
                        let y = ((top + row as f32 * spacing) * height as f32 / h as f32).round()
                            as u32;
                        assert!(
                            (y.saturating_sub(2)..=(y + 2).min(height - 1))
                                .any(|yy| small[(width / 2, yy)][0] < 200),
                            "missing row {row}, source {w}, target {width}, filter {filter:?}"
                        );
                        row += 1;
                    }
                    assert!(small.pixels().all(|pixel| pixel[3] == 255));
                }
            }
            let plain = blank_paper(
                w,
                h,
                &Parameters {
                    underlined: false,
                    ..p
                },
            );
            assert!(plain.pixels().all(|pixel| *pixel == Rgba([255; 4])));
        }
    }
}
