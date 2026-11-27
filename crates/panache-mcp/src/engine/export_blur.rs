use handwriting_core::{Cancellation, Error, Result};
use image::{Rgba, RgbaImage};

pub(crate) fn validate(sigma: f64) -> Result<()> {
    if (0.0..=2.0).contains(&sigma) {
        Ok(())
    } else {
        Err(Error::new(
            "invalid_parameter",
            "export_blur_px must be a Gaussian sigma from 0 to 2 original image pixels.",
        ))
    }
}

/// Filter the completed native-resolution page, including paper and alpha, in its stored RGB space.
pub(crate) fn apply(page: &RgbaImage, sigma: f64, cancel: &Cancellation) -> Result<RgbaImage> {
    validate(sigma)?;
    cancel.check()?;
    if sigma == 0. || page.width() == 0 || page.height() == 0 {
        return Ok(page.clone());
    }
    let radius = (3. * sigma).ceil() as isize;
    let mut kernel: Vec<f32> = (-radius..=radius)
        .map(|i| (-0.5 * (i as f64 / sigma).powi(2)).exp() as f32)
        .collect();
    let sum: f32 = kernel.iter().sum();
    for weight in &mut kernel {
        *weight /= sum;
    }
    let (w, h) = (page.width() as usize, page.height() as usize);
    let mut out = RgbaImage::new(page.width(), page.height());
    // 2026-11-27：分带只缓存双向高斯卷积所需的几行；透明像素的隐藏 RGB 不参与混色。
    for left in (0..w).step_by(512) {
        let width = (w - left).min(512);
        let mut rows = vec![vec![[0f32; 4]; width]; kernel.len().min(h)];
        let slots = rows.len();
        let mut next = 0;
        for y in 0..h {
            if y % 32 == 0 {
                cancel.check()?;
            }
            while next <= (y + radius as usize).min(h - 1) {
                let row = &mut rows[next % slots];
                for (col, filtered) in row.iter_mut().enumerate() {
                    let mut total = [0.; 4];
                    for (k, &weight) in kernel.iter().enumerate() {
                        let x = (left + col)
                            .saturating_add_signed(k as isize - radius)
                            .min(w - 1);
                        let [r, g, b, a] = page[(x as u32, next as u32)].0;
                        let weighted_alpha = f32::from(a) * weight;
                        total[0] += weighted_alpha * f32::from(r);
                        total[1] += weighted_alpha * f32::from(g);
                        total[2] += weighted_alpha * f32::from(b);
                        total[3] += weighted_alpha;
                    }
                    *filtered = total;
                }
                next += 1;
            }
            for col in 0..width {
                let mut total = [0.; 4];
                for (k, &weight) in kernel.iter().enumerate() {
                    let sample_y = y.saturating_add_signed(k as isize - radius).min(h - 1);
                    for (v, sample) in total.iter_mut().zip(rows[sample_y % slots][col]) {
                        *v += weight * sample;
                    }
                }
                let alpha = total[3].round() as u8;
                let rgb = |c: f32| {
                    if alpha == 0 {
                        0
                    } else {
                        (c / total[3]).round() as u8
                    }
                };
                out[((left + col) as u32, y as u32)] =
                    Rgba([rgb(total[0]), rgb(total[1]), rgb(total[2]), alpha]);
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gaussian_crosses_band_boundaries_without_mixing_hidden_colors() {
        let mut page = RgbaImage::from_pixel(515, 9, Rgba([1, 250, 18, 0]));
        page[(511, 4)] = Rgba([207, 13, 99, 255]);
        let result = apply(&page, 1., &Cancellation::default()).unwrap();
        assert_eq!(result.dimensions(), page.dimensions());
        // A unit impulse convolved by the normalized 2-D Gaussian, sigma=1.
        for (x, y, a) in [
            (511, 4, 41),
            (510, 4, 25),
            (512, 4, 25),
            (511, 3, 25),
            (512, 5, 15),
        ] {
            assert_eq!(result[(x, y)].0, [207, 13, 99, a]);
        }
        assert_eq!(result[(5, 4)].0, [0; 4]);
        assert_eq!(apply(&page, 0., &Cancellation::default()).unwrap(), page);
    }

    #[test]
    fn maximum_radius_preserves_uniform_tiny_pages_and_responds_to_cancellation() {
        let page = RgbaImage::from_pixel(2, 1, Rgba([31, 62, 93, 127]));
        assert_eq!(apply(&page, 2., &Cancellation::default()).unwrap(), page);
        assert_eq!(
            apply(&page, f64::MIN_POSITIVE, &Cancellation::default()).unwrap(),
            page
        );
        let cancel = Cancellation::default();
        cancel.cancel();
        assert!(apply(&page, 1., &cancel).is_err());
        for v in [-0.01, 2.01, f64::NAN, f64::INFINITY] {
            assert!(validate(v).is_err());
        }
    }
}
