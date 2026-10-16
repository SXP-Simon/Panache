use crate::{Error, Limits, Result, render::Cancellation};
use image::{DynamicImage, GrayImage, ImageDecoder, ImageReader, Rgba, RgbaImage};
use rand::{RngExt, SeedableRng};
use rand_chacha::ChaCha8Rng;
use serde::Serialize;
use std::io::Cursor;

pub fn decode(bytes: &[u8], limits: &Limits) -> Result<DynamicImage> {
    if bytes.len() > limits.max_file_bytes {
        return Err(Error::new("upload_limit", "图片文件过大"));
    }
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| Error::new("invalid_image", e.to_string()))?;
    let mut image_limits = image::Limits::default();
    image_limits.max_alloc = Some(limits.max_pixels.saturating_mul(8));
    reader.limits(image_limits);
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| Error::new("invalid_image", e.to_string()))?;
    let (w, h) = decoder.dimensions();
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > limits.max_pixels {
        return Err(Error::new("image_limit", "解码图片尺寸超出限制"));
    }
    // 2026-10-16：应用手机照片的 EXIF 方向，避免导入后横倒或镜像。
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut image = DynamicImage::from_decoder(decoder)
        .map_err(|e| Error::new("invalid_image", e.to_string()))?;
    image.apply_orientation(orientation);
    Ok(image)
}
pub fn scale(alt: &str) -> f32 {
    let Some((_, param)) = alt.split_once('|') else {
        return 1.;
    };
    let s = param
        .trim()
        .trim_start_matches("scale=")
        .trim_start_matches("w=");
    let n = s.trim_end_matches('%').trim().parse::<f32>().unwrap_or(1.);
    if !n.is_finite() {
        return 1.;
    }
    (if s.ends_with('%') || (n > 7. && n <= 700.) {
        n / 100.
    } else {
        n
    })
    .clamp(0.1, 7.)
}
pub fn fit(image: &RgbaImage, width: u32, height: u32, scale: f32) -> RgbaImage {
    // 2026-10-16：先自然适配版心，再以此为 100%，大图也能按百分比缩小。
    let base_ratio = (width as f32 / image.width() as f32)
        .min(height as f32 / image.height() as f32)
        .min(1.);
    let tw = image.width() as f32 * base_ratio * scale;
    let th = image.height() as f32 * base_ratio * scale;
    let ratio = (width as f32 / tw).min(height as f32 / th).min(1.);
    image::imageops::resize(
        image,
        (tw * ratio).max(1.) as u32,
        (th * ratio).max(1.) as u32,
        image::imageops::FilterType::Lanczos3,
    )
}
// 2026-10-12：高斯局部阈值、低频位移场、线条附近墨滴和透明墨色。
pub fn handdrawn(image: &DynamicImage, seed: u64, cancel: &Cancellation) -> Result<RgbaImage> {
    // 2026-10-16：透明像素须先合成白底，否则黑色透明底会吞掉黑线。
    let mut opaque = image.to_rgba8();
    for pixel in opaque.pixels_mut() {
        let alpha = u16::from(pixel[3]);
        for channel in &mut pixel.0[..3] {
            *channel = ((u16::from(*channel) * alpha + 255 * (255 - alpha) + 127) / 255) as u8;
        }
        pixel[3] = 255;
    }
    let gray = DynamicImage::ImageRgba8(opaque).to_luma8();
    let (w, h) = gray.dimensions();
    let blurred = imageproc::filter::gaussian_blur_f32(&gray, 0.85);
    let mean = imageproc::filter::gaussian_blur_f32(&blurred, 2.6);
    let mask = GrayImage::from_fn(w, h, |x, y| {
        image::Luma(
            [if blurred[(x, y)][0] as i16 <= mean[(x, y)][0] as i16 - 5 {
                255
            } else {
                0
            }],
        )
    });
    let mut rng = ChaCha8Rng::seed_from_u64(seed);
    let cell = (w.min(h) / 40).max(8);
    let gw = w / cell + 2;
    let gh = h / cell + 2;
    let field: Vec<(f32, f32)> = (0..gw * gh)
        .map(|_| (rng.random_range(-1.25..1.25), rng.random_range(-1.25..1.25)))
        .collect();
    let mut out = RgbaImage::new(w, h);
    for y in 0..h {
        if y % 32 == 0 {
            cancel.check()?;
        }
        for x in 0..w {
            let fx = x as f32 / cell as f32;
            let fy = y as f32 / cell as f32;
            let ix = fx as u32;
            let iy = fy as u32;
            let (tx, ty) = (fx - ix as f32, fy - iy as f32);
            let mut delta = (0., 0.);
            for (dx, dy, weight) in [
                (0, 0, (1. - tx) * (1. - ty)),
                (1, 0, tx * (1. - ty)),
                (0, 1, (1. - tx) * ty),
                (1, 1, tx * ty),
            ] {
                let v = field[((iy + dy) * gw + ix + dx) as usize];
                delta.0 += v.0 * weight;
                delta.1 += v.1 * weight;
            }
            let px = (x as f32 + delta.0).clamp(0., (w - 1) as f32);
            let py = (y as f32 + delta.1).clamp(0., (h - 1) as f32);
            let ix = px.floor() as u32;
            let iy = py.floor() as u32;
            let tx = px - ix as f32;
            let ty = py - iy as f32;
            let v = (mask[(ix, iy)][0] as f32 * (1. - tx) * (1. - ty)
                + mask[((ix + 1).min(w - 1), iy)][0] as f32 * tx * (1. - ty)
                + mask[(ix, (iy + 1).min(h - 1))][0] as f32 * (1. - tx) * ty
                + mask[((ix + 1).min(w - 1), (iy + 1).min(h - 1))][0] as f32 * tx * ty)
                as u8;
            let mut alpha = (v as f32 * rng.random_range(0.75..1.)) as u8;
            if rng.random::<f32>() < 0.003
                && (-2..=2).any(|dy| {
                    (-2..=2).any(|dx| {
                        let xx = x as i32 + dx;
                        let yy = y as i32 + dy;
                        xx >= 0
                            && yy >= 0
                            && xx < w as i32
                            && yy < h as i32
                            && mask[(xx as u32, yy as u32)][0] > 0
                    })
                })
            {
                alpha = rng.random_range(100..200);
            }
            out.put_pixel(x, y, Rgba([20, 20, 25, alpha]));
        }
    }
    Ok(out)
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Identification {
    pub margin_left: u32,
    pub margin_right: u32,
    pub margin_top: u32,
    pub margin_bottom: u32,
    pub line_spacing: u32,
    pub confidence: f32,
}
// 2026-10-12：在降采样图上搜索倾斜角度，按横线带中心测量行距，避免把双边缘当两行。
pub fn identify(image: &DynamicImage) -> Result<Identification> {
    let original = image.to_luma8();
    let (ow, oh) = original.dimensions();
    let ratio = (1200. / ow.max(oh) as f32).min(1.);
    let gray = image::imageops::resize(
        &original,
        (ow as f32 * ratio).max(1.) as u32,
        (oh as f32 * ratio).max(1.) as u32,
        image::imageops::FilterType::Triangle,
    );
    let (w, h) = gray.dimensions();
    let mut best = (0f64, 0f32, Vec::new());
    for step in -24..=24 {
        let angle = (step as f32 * 0.5).to_radians();
        let mut rows = vec![0u32; h as usize];
        for y in 0..h {
            for x in 0..w {
                if gray[(x, y)][0] < 150 {
                    let yy = ((y as f32 - h as f32 / 2.) * angle.cos()
                        - (x as f32 - w as f32 / 2.) * angle.sin()
                        + h as f32 / 2.)
                        .round() as i32;
                    if yy >= 0 && yy < h as i32 {
                        rows[yy as usize] += 1;
                    }
                }
            }
        }
        let score = rows.iter().map(|n| f64::from(*n).powi(2)).sum::<f64>();
        if score > best.0 {
            best = (score, angle, rows);
        }
    }
    let threshold = (w as f32 * 0.2).max(20.) as u32;
    let mut bands = Vec::<(u32, u32)>::new();
    let mut start = None;
    for (y, count) in best.2.iter().enumerate() {
        if *count >= threshold {
            start.get_or_insert(y as u32);
        } else if let Some(s) = start.take() {
            bands.push((s, y as u32 - 1));
        }
    }
    if let Some(s) = start {
        bands.push((s, h - 1));
    }
    if bands.len() < 2 {
        return Err(Error::new(
            "identification_unreliable",
            "无法可靠识别行距，请手动设置",
        ));
    }
    let centers: Vec<_> = bands.iter().map(|(a, b)| (*a + *b) as f32 / 2.).collect();
    let mut gaps: Vec<_> = centers
        .windows(2)
        .map(|v| v[1] - v[0])
        .filter(|v| *v > 2.)
        .collect();
    gaps.sort_by(f32::total_cmp);
    if gaps.is_empty() {
        return Err(Error::new("identification_unreliable", "没有可测量的行距"));
    }
    let spacing = gaps[gaps.len() / 2];
    let stable = gaps
        .iter()
        .filter(|v| (**v - spacing).abs() < spacing * 0.15)
        .count() as f32
        / gaps.len() as f32;
    if stable < 0.6 {
        return Err(Error::new(
            "identification_unreliable",
            "线条间距不稳定，请手动设置",
        ));
    }
    let mut left = w;
    let mut right = 0;
    let mut top = h;
    let mut bottom = 0;
    let angle = best.1;
    for y in 0..h {
        for x in 0..w {
            if gray[(x, y)][0] < 150 {
                let xx = ((x as f32 - w as f32 / 2.) * angle.cos()
                    + (y as f32 - h as f32 / 2.) * angle.sin()
                    + w as f32 / 2.)
                    .round()
                    .clamp(0., (w - 1) as f32) as u32;
                let yy = ((y as f32 - h as f32 / 2.) * angle.cos()
                    - (x as f32 - w as f32 / 2.) * angle.sin()
                    + h as f32 / 2.)
                    .round()
                    .clamp(0., (h - 1) as f32) as u32;
                if bands.iter().any(|(a, b)| yy >= *a && yy <= *b) {
                    left = left.min(xx);
                    right = right.max(xx);
                    top = top.min(yy);
                    bottom = bottom.max(yy);
                }
            }
        }
    }
    Ok(Identification {
        margin_left: (left as f32 / ratio).round() as u32,
        margin_right: ((w - 1 - right) as f32 / ratio).round() as u32,
        margin_top: (top as f32 / ratio).round() as u32,
        margin_bottom: ((h - 1 - bottom) as f32 / ratio).round() as u32,
        line_spacing: (spacing / ratio).round() as u32,
        confidence: stable,
    })
}
