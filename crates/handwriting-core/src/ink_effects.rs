use image::{GrayImage, Luma, Rgba, RgbaImage};

use crate::{Cancellation, Parameters, Result};

pub fn coverage(ink: &RgbaImage) -> GrayImage {
    GrayImage::from_fn(ink.width(), ink.height(), |x, y| {
        let pixel = ink[(x, y)];
        Luma([((u16::from(255 - pixel[0]) * u16::from(pixel[3]) + 127) / 255) as u8])
    })
}

pub fn transparent_mask(alpha: &GrayImage) -> RgbaImage {
    RgbaImage::from_fn(alpha.width(), alpha.height(), |x, y| {
        Rgba([0, 0, 0, alpha[(x, y)][0]])
    })
}

enum Kernel {
    Max,
    Min,
    Mean,
}

fn pass(
    input: &GrayImage,
    radius: i32,
    kernel: &Kernel,
    vertical: bool,
    cancel: &Cancellation,
) -> Result<GrayImage> {
    let (w, h) = input.dimensions();
    let mut output = GrayImage::new(w, h);
    for y in 0..h {
        cancel.check()?;
        for x in 0..w {
            let mut value = if matches!(kernel, Kernel::Min) {
                255
            } else {
                0
            };
            for offset in -radius..=radius {
                let xx = if vertical {
                    x
                } else {
                    (x as i32 + offset).clamp(0, w as i32 - 1) as u32
                };
                let yy = if vertical {
                    (y as i32 + offset).clamp(0, h as i32 - 1) as u32
                } else {
                    y
                };
                let sample = i32::from(input[(xx, yy)][0]);
                value = match kernel {
                    Kernel::Max => value.max(sample),
                    Kernel::Min => value.min(sample),
                    Kernel::Mean => value + sample,
                };
            }
            if matches!(kernel, Kernel::Mean) {
                value = (value + radius) / (2 * radius + 1);
            }
            output[(x, y)] = Luma([value as u8]);
        }
    }
    Ok(output)
}

// 2026-11-16：遮罩插值使用整数权重，和 Flutter 预览的舍入一致。
fn blend_radius(
    mask: &GrayImage,
    radius: f64,
    kernel: &Kernel,
    cancel: &Cancellation,
) -> Result<GrayImage> {
    let tenths = (radius * 10.).round() as u16;
    let whole = i32::from(tenths / 10);
    let weight = tenths % 10;
    let at = |r| {
        pass(
            &pass(mask, r, kernel, false, cancel)?,
            r,
            kernel,
            true,
            cancel,
        )
    };
    let mut lower = if whole == 0 { mask.clone() } else { at(whole)? };
    if weight != 0 {
        let upper = at(whole + 1)?;
        cancel.check()?;
        for (a, b) in lower.pixels_mut().zip(upper.pixels()) {
            a[0] = ((u16::from(a[0]) * (10 - weight) + u16::from(b[0]) * weight + 5) / 10) as u8;
        }
    }
    Ok(lower)
}

pub(crate) fn shape(
    mut mask: GrayImage,
    thickness: f64,
    softness: f64,
    cancel: &Cancellation,
) -> Result<GrayImage> {
    if thickness != 0. {
        let thin = thickness < 0.;
        let kernel = if thin { Kernel::Min } else { Kernel::Max };
        let mut changed = blend_radius(&mask, thickness.abs(), &kernel, cancel)?;
        if thin {
            for (after, before) in changed.pixels_mut().zip(mask.pixels()) {
                after[0] = ((u16::from(after[0]) * 7 + u16::from(before[0]) * 3 + 5) / 10) as u8;
            }
        }
        mask = changed;
    }
    if softness != 0. {
        mask = blend_radius(&mask, softness, &Kernel::Mean, cancel)?;
    }
    Ok(mask)
}

pub fn composite(
    mut paper: RgbaImage,
    mask: GrayImage,
    p: &Parameters,
    cancel: &Cancellation,
) -> Result<RgbaImage> {
    let mask = shape(mask, p.ink_thickness, p.ink_softness, cancel)?;
    for y in 0..paper.height() {
        cancel.check()?;
        for x in 0..paper.width() {
            let alpha =
                (u32::from(mask[(x, y)][0]) * u32::from(p.ink_opacity) * u32::from(p.fill[3])
                    + 12_750)
                    / 25_500;
            let pixel = &mut paper[(x, y)];
            if pixel[3] < 255 {
                use image::Pixel;
                pixel.blend(&Rgba([p.fill[0], p.fill[1], p.fill[2], alpha as u8]));
                continue;
            }
            for (channel, ink) in pixel.0[..3].iter_mut().zip(p.fill) {
                *channel = ((u32::from(*channel) * (255 - alpha) + u32::from(ink) * alpha + 127)
                    / 255) as u8;
            }
        }
    }
    Ok(paper)
}
