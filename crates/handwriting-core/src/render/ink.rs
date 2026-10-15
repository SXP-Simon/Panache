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
        let mut y = p.top_margin + p.line_spacing;
        while y < h as f32 - p.bottom_margin {
            imageproc::drawing::draw_line_segment_mut(
                &mut bg,
                (p.left_margin, y),
                (w as f32 - p.right_margin, y),
                Rgba([0, 0, 0, 255]),
            );
            y += p.line_spacing;
        }
    }
    bg
}
