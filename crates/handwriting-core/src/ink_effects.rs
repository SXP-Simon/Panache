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

pub fn composite(
    mut paper: RgbaImage,
    mut mask: GrayImage,
    p: &Parameters,
    cancel: &Cancellation,
) -> Result<RgbaImage> {
    if p.ink_thickness != 0 {
        let thin = p.ink_thickness < 0;
        let kernel = if thin { Kernel::Min } else { Kernel::Max };
        let radius = i32::from(p.ink_thickness.unsigned_abs());
        let horizontal = pass(&mask, radius, &kernel, false, cancel)?;
        let mut changed = pass(&horizontal, radius, &kernel, true, cancel)?;
        if thin {
            for (after, before) in changed.pixels_mut().zip(mask.pixels()) {
                after[0] = ((u16::from(after[0]) * 7 + u16::from(before[0]) * 3 + 5) / 10) as u8;
            }
        }
        mask = changed;
    }
    if p.ink_softness != 0 {
        let radius = i32::from(p.ink_softness);
        let horizontal = pass(&mask, radius, &Kernel::Mean, false, cancel)?;
        mask = pass(&horizontal, radius, &Kernel::Mean, true, cancel)?;
    }
    for y in 0..paper.height() {
        cancel.check()?;
        for x in 0..paper.width() {
            let alpha =
                (u32::from(mask[(x, y)][0]) * u32::from(p.ink_opacity) * u32::from(p.fill[3])
                    + 12_750)
                    / 25_500;
            let pixel = &mut paper[(x, y)];
            for (channel, ink) in pixel.0[..3].iter_mut().zip(p.fill) {
                *channel = ((u32::from(*channel) * (255 - alpha) + u32::from(ink) * alpha + 127)
                    / 255) as u8;
            }
        }
    }
    Ok(paper)
}
