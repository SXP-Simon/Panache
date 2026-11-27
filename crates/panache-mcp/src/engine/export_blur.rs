use handwriting_core::{Cancellation, Error, Result};
use image::{Rgba, RgbaImage};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Anchor {
    /// Horizontal position in the full image, 0 at the leftmost pixel and 1 at the rightmost.
    #[schemars(range(min = 0, max = 1))]
    pub x: f64,
    /// Vertical position in the full image, 0 at the top pixel and 1 at the bottom.
    #[schemars(range(min = 0, max = 1))]
    pub y: f64,
    /// Gaussian sigma in original image pixels.
    #[schemars(range(min = 0, max = 2))]
    pub sigma_px: f64,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Gradient {
    /// The starting position and blur strength.
    pub from: Anchor,
    /// The distinct end position and blur strength. Outside the segment the nearest end strength applies.
    pub to: Anchor,
}

impl Gradient {
    fn validate(self) -> Result<()> {
        for anchor in [self.from, self.to] {
            if !(0.0..=1.0).contains(&anchor.x)
                || !(0.0..=1.0).contains(&anchor.y)
                || !(0.0..=2.0).contains(&anchor.sigma_px)
            {
                return Err(Error::new(
                    "invalid_parameter",
                    "export_blur_gradient requires x and y from 0 to 1, and sigma_px from 0 to 2 original image pixels.",
                ));
            }
        }
        if self.from.x == self.to.x && self.from.y == self.to.y {
            return Err(Error::new(
                "invalid_parameter",
                "export_blur_gradient needs two distinct anchor positions.",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) enum Finish {
    Uniform(f64),
    Gradient(Gradient),
}

pub(crate) fn finish(uniform: Option<f64>, gradient: Option<Gradient>) -> Result<Option<Finish>> {
    match (uniform, gradient) {
        (None, None) => Ok(None),
        (Some(_), Some(_)) => Err(Error::new(
            "invalid_parameter",
            "Supply only one of export_blur_px and export_blur_gradient, even when the uniform value is 0.",
        )),
        (Some(sigma), None) => {
            validate(sigma)?;
            Ok(Some(Finish::Uniform(sigma)))
        }
        (None, Some(g)) => {
            g.validate()?;
            Ok(Some(Finish::Gradient(g)))
        }
    }
}

impl Finish {
    pub(crate) fn active(self) -> bool {
        match self {
            Self::Uniform(sigma) => sigma > 0.,
            Self::Gradient(g) => g.from.sigma_px > 0. || g.to.sigma_px > 0.,
        }
    }

    pub(crate) fn write_metadata(self, object: &mut Value) {
        match self {
            Self::Uniform(sigma) => object["export_blur_px"] = json!(sigma),
            Self::Gradient(g) => object["export_blur_gradient"] = json!(g),
        }
    }

    pub(crate) fn apply(self, page: &RgbaImage, cancel: &Cancellation) -> Result<RgbaImage> {
        match self {
            Self::Uniform(sigma) => apply(page, sigma, cancel),
            Self::Gradient(g) => apply_gradient(page, g, cancel),
        }
    }
}

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

// 最大 sigma 为 2，三倍标准差截断的核每侧最多六个像素。
struct Kernel {
    weights: [f32; 13],
    radius: usize,
}

impl Kernel {
    fn new(sigma: f64) -> Self {
        let radius = (3. * sigma).ceil() as usize;
        let mut weights = [0.; 13];
        weights[radius] = 1.;
        for i in 1..=radius {
            let value = (-0.5 * (i as f64 / sigma).powi(2)).exp() as f32;
            weights[radius - i] = value;
            weights[radius + i] = value;
        }
        let taps = &mut weights[..=2 * radius];
        let sum: f32 = taps.iter().sum();
        for weight in taps {
            *weight /= sum;
        }
        Self { weights, radius }
    }

    fn taps(&self) -> &[f32] {
        &self.weights[..=2 * self.radius]
    }

    fn horizontal(&self, page: &RgbaImage, x: usize, y: usize) -> [f32; 4] {
        let mut total = [0.; 4];
        let w = page.width() as usize;
        for (k, &weight) in self.taps().iter().enumerate() {
            let sample_x = x
                .saturating_add_signed(k as isize - self.radius as isize)
                .min(w - 1);
            let [r, g, b, a] = page[(sample_x as u32, y as u32)].0;
            let weighted_alpha = f32::from(a) * weight;
            total[0] += weighted_alpha * f32::from(r);
            total[1] += weighted_alpha * f32::from(g);
            total[2] += weighted_alpha * f32::from(b);
            total[3] += weighted_alpha;
        }
        total
    }
}

fn straight_rgba(total: [f32; 4]) -> Rgba<u8> {
    let alpha = total[3].round() as u8;
    let rgb = |c: f32| {
        if alpha == 0 {
            0
        } else {
            (c / total[3]).round() as u8
        }
    };
    Rgba([rgb(total[0]), rgb(total[1]), rgb(total[2]), alpha])
}

fn apply_gradient(page: &RgbaImage, g: Gradient, cancel: &Cancellation) -> Result<RgbaImage> {
    g.validate()?;
    cancel.check()?;
    if g.from.sigma_px == g.to.sigma_px {
        return apply(page, g.from.sigma_px, cancel);
    }
    let (w, h) = page.dimensions();
    if w == 0 || h == 0 {
        return Ok(page.clone());
    }
    let (from, to) = if (g.from.x, g.from.y) <= (g.to.x, g.to.y) {
        (g.from, g.to)
    } else {
        (g.to, g.from)
    };
    let (wx, hy) = (f64::from(w - 1), f64::from(h - 1));
    let (sx, sy) = (from.x * wx, from.y * hy);
    let (dx, dy) = (to.x * wx - sx, to.y * hy - sy);
    let span = dx.abs().max(dy.abs());
    if span == 0. {
        return apply(page, from.sigma_px.midpoint(to.sigma_px), cancel);
    }
    // 缩放同一投影的分子和分母，避免极近锚点的距离平方下溢。
    let (ux, uy) = (dx / span, dy / span);
    let length = dx * ux + dy * uy;
    let first = Kernel::new(from.sigma_px);
    let last = Kernel::new(to.sigma_px);
    let mut out = RgbaImage::new(w, h);
    for (y, row) in out.rows_mut().enumerate() {
        let y_dot = (y as f64 - sy) * uy;
        for (x, pixel) in row.enumerate() {
            if x % 512 == 0 {
                cancel.check()?;
            }
            let t = ((x as f64 - sx) * ux + y_dot) / length;
            let middle;
            let kernel = if t <= 0. {
                &first
            } else if t >= 1. {
                &last
            } else {
                middle = Kernel::new((1. - t) * from.sigma_px + t * to.sigma_px);
                &middle
            };
            if kernel.radius == 0 {
                *pixel = page[(x as u32, y as u32)];
                continue;
            }
            // 两轴都取输出点的 sigma；先按输入行位置套一次渐变会使斜向边界偏色。
            let mut total = [0.; 4];
            for (k, &weight) in kernel.taps().iter().enumerate() {
                let sample_y = y
                    .saturating_add_signed(k as isize - kernel.radius as isize)
                    .min(h as usize - 1);
                for (v, sample) in total.iter_mut().zip(kernel.horizontal(page, x, sample_y)) {
                    *v += weight * sample;
                }
            }
            *pixel = straight_rgba(total);
        }
    }
    Ok(out)
}

/// Filter the completed native-resolution page, including paper and alpha, in its stored RGB space.
pub(crate) fn apply(page: &RgbaImage, sigma: f64, cancel: &Cancellation) -> Result<RgbaImage> {
    validate(sigma)?;
    cancel.check()?;
    if sigma == 0. || page.width() == 0 || page.height() == 0 {
        return Ok(page.clone());
    }
    let filter = Kernel::new(sigma);
    let radius = filter.radius as isize;
    let kernel = filter.taps();
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
                    *filtered = filter.horizontal(page, left + col, next);
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
                out[((left + col) as u32, y as u32)] = straight_rgba(total);
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn anchor(x: f64, y: f64, sigma_px: f64) -> Anchor {
        Anchor { x, y, sigma_px }
    }

    // Independent 2-D Gaussian reference; accumulate premultiplied channels in double precision.
    fn reference(page: &RgbaImage, x: u32, y: u32, sigma: f64) -> [u8; 4] {
        if sigma == 0. {
            return page[(x, y)].0;
        }
        let radius = (3. * sigma).ceil() as i32;
        let mut total = [0.; 4];
        let mut norm = 0.;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                let weight = (-f64::from(dx * dx + dy * dy) / (2. * sigma * sigma)).exp();
                let px = x.saturating_add_signed(dx).min(page.width() - 1);
                let py = y.saturating_add_signed(dy).min(page.height() - 1);
                let p = page[(px, py)].0.map(f64::from);
                for c in 0..3 {
                    total[c] += weight * p[3] * p[c];
                }
                total[3] += weight * p[3];
                norm += weight;
            }
        }
        let alpha = (total[3] / norm).round() as u8;
        if alpha == 0 {
            [0; 4]
        } else {
            [0, 1, 2, 3].map(|i| {
                if i == 3 {
                    alpha
                } else {
                    (total[i] / total[3]).round() as u8
                }
            })
        }
    }

    #[test]
    fn directional_rgba_matches_output_point_gaussians_in_native_pixel_geometry() {
        let page = RgbaImage::from_fn(33, 17, |x, y| {
            Rgba([
                ((29 * x + 19 * y) % 256) as u8,
                ((13 * x + 37 * y) % 256) as u8,
                191,
                if x <= 5 {
                    0
                } else {
                    ((47 * x + 11 * y) % 256) as u8
                },
            ])
        });
        let cancel = Cancellation::default();
        let full = apply(&page, 1.78, &cancel).unwrap();
        for (from, to, vector) in [
            (anchor(0.125, 0.25, 0.), anchor(0.875, 0.25, 1.78), [24, 0]),
            (anchor(0.125, 0.25, 0.), anchor(0.125, 0.75, 1.78), [0, 8]),
            (anchor(0.125, 0.25, 0.), anchor(0.875, 0.75, 1.78), [24, 8]),
        ] {
            let result = Finish::Gradient(Gradient { from, to })
                .apply(&page, &cancel)
                .unwrap();
            let reverse = Finish::Gradient(Gradient { from: to, to: from })
                .apply(&page, &cancel)
                .unwrap();
            assert_eq!(result, reverse);
            let [dx, dy] = vector.map(f64::from);
            for (x, y, pixel) in result.enumerate_pixels() {
                let t = (((f64::from(x) - 4.) * dx + (f64::from(y) - 4.) * dy)
                    / (dx * dx + dy * dy))
                    .clamp(0., 1.);
                if t == 0. {
                    assert_eq!(*pixel, page[(x, y)]);
                }
                if t == 1. {
                    assert_eq!(*pixel, full[(x, y)]);
                }
                let expected = reference(&page, x, y, t * 1.78);
                assert!(
                    pixel
                        .0
                        .iter()
                        .zip(expected)
                        .all(|(a, b)| a.abs_diff(b) <= 1),
                    "({x},{y}) t={t}: {pixel:?} vs {expected:?}"
                );
            }
        }
    }

    #[test]
    fn equal_sigmas_collapsed_dimensions_and_nearly_coincident_anchors() {
        let page = RgbaImage::from_fn(19, 1, |x, _| {
            Rgba([90, x as u8, 219, if x % 2 == 0 { 0 } else { 255 }])
        });
        let cancel = Cancellation::default();
        for sigma in [0., 0.6, 2.] {
            let flat = Finish::Gradient(Gradient {
                from: anchor(0., 0., sigma),
                to: anchor(1., 1., sigma),
            });
            assert_eq!(flat.active(), sigma > 0.);
            assert_eq!(
                flat.apply(&page, &cancel).unwrap(),
                apply(&page, sigma, &cancel).unwrap()
            );
        }
        let collapsed = Finish::Gradient(Gradient {
            from: anchor(0., 0., 0.),
            to: anchor(0., 1., 2.),
        });
        assert_eq!(
            collapsed.apply(&page, &cancel).unwrap(),
            apply(&page, 1., &cancel).unwrap()
        );
        let tiny = Finish::Gradient(Gradient {
            from: anchor(0., 0., 0.),
            to: anchor(f64::from_bits(1), 0., 2.),
        });
        let result = tiny.apply(&page, &cancel).unwrap();
        let full = apply(&page, 2., &cancel).unwrap();
        for x in 0..page.width() {
            assert_eq!(
                result[(x, 0)],
                if x == 0 { page[(0, 0)] } else { full[(x, 0)] }
            );
        }
        let solid = RgbaImage::from_pixel(3, 7, Rgba([40, 66, 253, 97]));
        assert_eq!(tiny.apply(&solid, &cancel).unwrap(), solid);
        cancel.cancel();
        assert!(tiny.apply(&solid, &cancel).is_err());
    }

    #[test]
    fn validates_range_exclusivity_and_retains_requested_anchor_order_in_metadata() {
        let g = Gradient {
            from: anchor(1., 0.8, 1.5),
            to: anchor(0.1, 0., 0.),
        };
        assert!(finish(None, None).unwrap().is_none());
        assert!(finish(Some(0.), Some(g)).is_err());
        assert!(!finish(Some(0.), None).unwrap().unwrap().active());
        for bad in [
            anchor(f64::NAN, 0., 1.),
            anchor(1., 1.001, 1.),
            anchor(0., 0., 2.1),
            g.to,
        ] {
            assert!(
                finish(
                    None,
                    Some(Gradient {
                        from: bad,
                        to: g.to
                    })
                )
                .is_err()
            );
        }
        let mut metadata = json!({"revision":7});
        finish(None, Some(g))
            .unwrap()
            .unwrap()
            .write_metadata(&mut metadata);
        assert_eq!(
            metadata,
            json!({"revision":7,"export_blur_gradient":{"from":{"x":1.,"y":0.8,"sigma_px":1.5},"to":{"x":0.1,"y":0.,"sigma_px":0.}}})
        );
    }

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
