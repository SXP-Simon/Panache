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
    pub layout_top_margin: u32,
    pub layout_bottom_margin: u32,
    pub image_width: u32,
    pub image_height: u32,
    pub deskew_angle_degrees: f32,
    pub confidence: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corrected_background: Option<String>,
}

// 2026-10-24：局部纵向亮度差可识别浅灰线，也不会把渐变阴影当成整片墨迹。
fn ruling_points(gray: &GrayImage) -> Vec<(f32, f32)> {
    let (w, h) = gray.dimensions();
    let radius = (h / 30).clamp(12, 40);
    let mut points = Vec::new();
    for x in 0..w {
        let mut sums = vec![0u32; h as usize + 1];
        for y in 0..h {
            sums[y as usize + 1] = sums[y as usize] + u32::from(gray[(x, y)][0]);
        }
        for y in 0..h {
            let a = y.saturating_sub(radius);
            let b = (y + radius + 1).min(h);
            let mean = (sums[b as usize] - sums[a as usize]) as f32 / (b - a) as f32;
            if f32::from(gray[(x, y)][0]) + 3. < mean {
                points.push((x as f32 - w as f32 / 2., y as f32 - h as f32 / 2.));
            }
        }
    }
    points
}
fn projected_rows(points: &[(f32, f32)], h: u32, angle: f32) -> (f64, Vec<u32>) {
    let mut rows = vec![0u32; h as usize];
    let (sin, cos) = angle.sin_cos();
    for &(x, y) in points {
        let row = (y * cos - x * sin + h as f32 / 2.).round() as i32;
        if row >= 0 && row < h as i32 {
            rows[row as usize] += 1;
        }
    }
    let score = rows.iter().map(|n| f64::from(*n).powi(2)).sum();
    (score, rows)
}

fn strip_centers(rows: &[u32], threshold: u32) -> Vec<f32> {
    let mut centers = Vec::new();
    let mut count = 0.;
    let mut weighted = 0.;
    for (y, value) in rows.iter().copied().chain([0]).enumerate() {
        if value >= threshold {
            count += value as f32;
            weighted += y as f32 * value as f32;
        } else if count > 0. {
            centers.push(weighted / count);
            count = 0.;
            weighted = 0.;
        }
    }
    centers
}

// Track the same rulings across the page before applying any global rotation.
fn flatten_rulings(
    opaque: &RgbaImage,
    points: &[(f32, f32)],
    w: u32,
    h: u32,
    ratio: f32,
) -> Result<Option<Identification>> {
    use base64::Engine;
    const STRIPS: usize = 5;
    const MIN_TRACKED_LINES: usize = 6;
    let columns: [f32; STRIPS] = std::array::from_fn(|i| w as f32 * (0.15 + i as f32 * 0.175));
    let radius = (w / 30).max(8) as f32;
    let mut rows = vec![[0; STRIPS]; h as usize];
    for &(x, y) in points {
        for (i, column) in columns.iter().enumerate() {
            if (x + w as f32 / 2. - column).abs() < radius {
                rows[(y + h as f32 / 2.) as usize][i] += 1;
            }
        }
    }
    let strips: [Vec<f32>; STRIPS] = std::array::from_fn(|index| {
        let profile: Vec<_> = rows.iter().map(|row| row[index]).collect();
        strip_centers(&profile, (radius * 1.1).ceil() as u32)
    });
    if strips.iter().any(|strip| strip.len() < MIN_TRACKED_LINES) {
        return Ok(None);
    }
    let middle = &strips[2];
    let mut gaps: Vec<_> = middle.windows(2).map(|pair| pair[1] - pair[0]).collect();
    gaps.sort_by(f32::total_cmp);
    let spacing = gaps[gaps.len() / 2];
    if spacing < 6. {
        return Ok(None);
    }
    let mut first = 0;
    let mut best = &middle[..0];
    for (i, pair) in middle.windows(2).enumerate() {
        if (pair[1] - pair[0] - spacing).abs() > spacing * 0.18 {
            if i + 1 - first > best.len() {
                best = &middle[first..=i];
            }
            first = i + 1;
        }
    }
    if middle.len() - first > best.len() {
        best = &middle[first..];
    }
    if best.len() < MIN_TRACKED_LINES {
        return Ok(None);
    }
    let spacing = (best[best.len() - 1] - best[0]) / (best.len() - 1) as f32;
    let tracks = strips.each_ref().map(|strip| {
        best.iter()
            .map(|y| {
                let next = strip.partition_point(|candidate| candidate < y);
                let left = strip[next.saturating_sub(1)];
                let right = strip[next.min(strip.len() - 1)];
                if (y - left).abs() < (right - y).abs() {
                    left
                } else {
                    right
                }
            })
            .collect::<Vec<_>>()
    });
    for track in &tracks {
        if track
            .iter()
            .zip(best)
            .any(|(y, reference)| (y - reference).abs() > spacing * 0.42)
            || track
                .windows(2)
                .any(|pair| (pair[1] - pair[0] - spacing).abs() > spacing * 0.22)
        {
            return Ok(None);
        }
    }
    // Leave flat or uniformly rotated paper on the existing affine path.
    let slope = (tracks[4][0] - tracks[0][0]) / (columns[4] - columns[0]);
    let nonlinear = tracks.iter().zip(columns).any(|(track, x)| {
        track.iter().enumerate().any(|(i, y)| {
            (y - (best[0] + spacing * i as f32 + slope * (x - columns[2]))).abs() > 3.
        })
    });
    if !nonlinear {
        return Ok(None);
    }
    let (ow, oh) = opaque.dimensions();
    let geometry = |x: f32, i: usize| {
        let j = columns
            .partition_point(|column| *column < x)
            .saturating_sub(1)
            .min(STRIPS - 2);
        let t = (x - columns[j]) / (columns[j + 1] - columns[j]);
        tracks[j][i] + t * (tracks[j + 1][i] - tracks[j][i])
    };
    let step = (spacing / ratio).round() as u32;
    let top = (best[0] / ratio).round() as u32;
    let last = top + (best.len() - 1) as u32 * step;
    if top == 0 || last >= oh - 1 {
        return Ok(None);
    }
    let mut support = vec![vec![false; best.len()]; w as usize];
    for &(x, y) in points {
        let x = x + w as f32 / 2.;
        let y = y + h as f32 / 2.;
        let i = ((y - best[0]) / spacing).round() as usize;
        // A slanted row can be closer to an adjacent row at the outer edges.
        let column = &mut support[x as usize];
        for (j, hit) in column
            .iter_mut()
            .enumerate()
            .take(i + 2)
            .skip(i.saturating_sub(1))
        {
            if (y - geometry(x, j)).abs() <= 3. {
                *hit = true;
            }
        }
    }
    let supported =
        |column: &Vec<bool>| column.iter().filter(|&&hit| hit).count() * 2 >= best.len();
    let Some(left) = support.iter().position(supported) else {
        return Ok(None);
    };
    let right = support.iter().rposition(supported).unwrap();
    if right - left < w as usize / 2 {
        return Ok(None);
    }
    let mut corrected = RgbaImage::new(ow, oh);
    for x in 0..ow {
        let source: Vec<_> = std::iter::once(0.)
            .chain((0..best.len()).map(|i| geometry(x as f32 * ratio, i) / ratio))
            .chain([(oh - 1) as f32])
            .collect();
        if source.windows(2).any(|pair| pair[0] >= pair[1]) {
            return Ok(None);
        }
        let destination = |i: usize| match i {
            0 => 0,
            i if i > best.len() => oh - 1,
            i => top + (i - 1) as u32 * step,
        };
        for (i, pair) in source.windows(2).enumerate() {
            let start = destination(i);
            let end = destination(i + 1);
            for y in start..=end {
                let weight = (y - start) as f32 / (end - start) as f32;
                let source_y = (pair[0] + weight * (pair[1] - pair[0])).clamp(0., (oh - 1) as f32);
                let before = source_y.floor() as u32;
                let after = (before + 1).min(oh - 1);
                let fraction = source_y - before as f32;
                corrected[(x, y)] = Rgba(std::array::from_fn(|channel| {
                    let a = opaque[(x, before)][channel] as f32;
                    let b = opaque[(x, after)][channel] as f32;
                    (a + fraction * (b - a)).round() as u8
                }));
            }
        }
    }
    let bottom = oh - last;
    let first_writable = if top >= step { top } else { top + step };
    Ok(Some(Identification {
        margin_left: (left as f32 / ratio).round() as u32,
        margin_right: ((w as usize - 1 - right) as f32 / ratio).round() as u32,
        margin_top: top,
        margin_bottom: bottom,
        layout_top_margin: first_writable - step,
        layout_bottom_margin: bottom.saturating_sub(step.div_ceil(4)),
        image_width: ow,
        image_height: oh,
        line_spacing: step,
        deskew_angle_degrees: 0.,
        confidence: 1.,
        corrected_background: Some(
            base64::engine::general_purpose::STANDARD.encode(crate::export::png(&corrected)?),
        ),
    }))
}
// 2026-10-24：分析坐标和返回的实际背景使用相同旋转，粗线按整条线带中心计距。
pub fn identify(image: &DynamicImage) -> Result<Identification> {
    use base64::Engine;
    use imageproc::geometric_transformations::{
        Border, Interpolation, rotate_about_center_no_crop,
    };
    let mut opaque = image.to_rgba8();
    for pixel in opaque.pixels_mut() {
        let alpha = u16::from(pixel[3]);
        for channel in &mut pixel.0[..3] {
            *channel = ((u16::from(*channel) * alpha + 255 * (255 - alpha) + 127) / 255) as u8;
        }
        pixel[3] = 255;
    }
    let original = DynamicImage::ImageRgba8(opaque.clone()).to_luma8();
    let (ow, oh) = original.dimensions();
    let ratio = (1200. / ow.max(oh) as f32).min(1.);
    let gray = image::imageops::resize(
        &original,
        (ow as f32 * ratio).max(1.) as u32,
        (oh as f32 * ratio).max(1.) as u32,
        image::imageops::FilterType::Triangle,
    );
    let (w, h) = gray.dimensions();
    let points = ruling_points(&gray);
    if let Some(corrected) = flatten_rulings(&opaque, &points, w, h, ratio)? {
        return Ok(corrected);
    }
    let mut best = (0f64, 0f32, vec![0; h as usize]);
    for step in -24..=24 {
        let angle = (step as f32 * 0.5).to_radians();
        let (score, rows) = projected_rows(&points, h, angle);
        if score > best.0 {
            best = (score, angle, rows);
        }
    }
    let coarse = best.1;
    for step in -9..=9 {
        let angle = coarse + (step as f32 * 0.05).to_radians();
        let (score, rows) = projected_rows(&points, h, angle);
        if score > best.0 {
            best = (score, angle, rows);
        }
    }
    let threshold = (w as f32 * 0.3).max(20.) as u32;
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
    if bands.len() < 3 {
        return Err(Error::new(
            "identification_unreliable",
            "无法可靠识别行距，请手动设置",
        ));
    }
    let mut widths: Vec<_> = bands.iter().map(|(a, b)| b - a + 1).collect();
    widths.sort_unstable();
    let typical_width = widths[widths.len() / 2];
    bands.retain(|(a, b)| b - a < (typical_width * 3).max(6));
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
        .filter(|v| (**v - spacing).abs() < spacing * 0.08)
        .count() as f32
        / gaps.len() as f32;
    if stable < 0.6 {
        return Err(Error::new(
            "identification_unreliable",
            "线条间距不稳定，请手动设置",
        ));
    }
    // 2026-10-24：照片边缘和阴影可能形成长条，只保留等距横线的最长连续序列。
    let mut best_run = (0, 1);
    let mut run_start = 0;
    for i in 1..centers.len() {
        if (centers[i] - centers[i - 1] - spacing).abs() >= spacing * 0.08 {
            run_start = i;
        }
        if i + 1 - run_start > best_run.1 - best_run.0 {
            best_run = (run_start, i + 1);
        }
    }
    bands = bands[best_run.0..best_run.1].to_vec();
    let centers = &centers[best_run.0..best_run.1];
    if bands.len() < 3 || bands.iter().any(|(a, b)| (b - a) as f32 > spacing * 0.4) {
        return Err(Error::new(
            "identification_unreliable",
            "没有足够连续等距的横线",
        ));
    }
    let mut left = w;
    let mut right = 0;
    let (sin, cos) = best.1.sin_cos();
    for &(x, y) in &points {
        let xx = (x * cos + y * sin + w as f32 / 2.)
            .round()
            .clamp(0., (w - 1) as f32) as u32;
        let yy = (y * cos - x * sin + h as f32 / 2.).round() as i32;
        if bands
            .iter()
            .any(|(a, b)| yy >= *a as i32 && yy <= *b as i32)
        {
            left = left.min(xx);
            right = right.max(xx);
        }
    }
    let angle = best.1.to_degrees();
    let (image_width, image_height, corrected_background) = if angle.abs() >= 0.1 {
        let fill = opaque[(0, 0)];
        let rotated_width = (oh as f32 * sin.abs() + ow as f32 * cos.abs()).ceil() as u32;
        let rotated_height = (oh as f32 * cos.abs() + ow as f32 * sin.abs()).ceil() as u32;
        if u64::from(rotated_width) * u64::from(rotated_height) > Limits::default().max_pixels {
            return Err(Error::new("image_limit", "校正后的纸张尺寸超出限制"));
        }
        let corrected = rotate_about_center_no_crop(
            &opaque,
            -best.1,
            Interpolation::Bilinear,
            Border::Constant(fill),
        );
        (
            corrected.width(),
            corrected.height(),
            Some(base64::engine::general_purpose::STANDARD.encode(crate::export::png(&corrected)?)),
        )
    } else {
        (ow, oh, None)
    };
    let offset_x = (image_width - ow) as f32 / 2.;
    let offset_y = (image_height - oh) as f32 / 2.;
    let first = centers[0] / ratio + offset_y;
    let line_spacing = (spacing / ratio).round() as u32;
    let first_writable = centers
        .iter()
        .map(|y| y / ratio + offset_y)
        .find(|y| *y >= line_spacing as f32)
        .ok_or_else(|| Error::new("identification_unreliable", "纸张没有足够书写空间"))?;
    let margin_bottom = (oh as f32 - centers.last().unwrap() / ratio + offset_y).round() as u32;
    Ok(Identification {
        margin_left: (left as f32 / ratio + offset_x).round() as u32,
        margin_right: ((w - 1 - right) as f32 / ratio + offset_x).round() as u32,
        margin_top: first.round() as u32,
        margin_bottom,
        layout_bottom_margin: margin_bottom
            .saturating_sub((line_spacing as f32 * 0.25).ceil() as u32),
        line_spacing,
        layout_top_margin: (first_writable.round() as u32).saturating_sub(line_spacing),
        image_width,
        image_height,
        deskew_angle_degrees: angle,
        confidence: stable,
        corrected_background,
    })
}
