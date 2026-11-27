//! 2026-11-18：按排版单元保存墨迹及页面坐标，供客户端实时编辑和导出。
use crate::{Cancellation, Error, LayoutStyle, Parameters, Result, export, ink_effects};
use base64::{Engine, engine::general_purpose::STANDARD};
use image::{GrayImage, Rgba, RgbaImage};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Adjustment {
    pub id: u32,
    pub dx: i32,
    pub dy: i32,
    pub scale: u8,
    pub angle: i8,
    pub opacity: u8,
    // 2026-11-27：以未变换图块高度为坐标，在两个锚点间渐变笔迹浓度。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity_ramp: Option<OpacityRamp>,
    pub color: Option<[u8; 3]>,
    // 2026-11-18：相对全局设置的偏移，以 0.1 px 为单位。
    #[serde(default)]
    pub thickness: i8,
    #[serde(default)]
    pub softness: i8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warp: Option<[f64; 8]>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(transparent)]
pub struct OpacityRamp(pub [[u8; 2]; 2]);

impl OpacityRamp {
    pub fn valid(self) -> bool {
        self.0[0][0] < self.0[1][0] && self.0.into_iter().flatten().all(|v| v <= 100)
    }

    fn multiplier(self, position: f64) -> f64 {
        let [[start, a], [end, b]] = self.0.map(|pair| pair.map(f64::from));
        let t = ((position - start) / (end - start)).clamp(0., 1.);
        (a + t * (b - a)) / 100.
    }
}

impl Adjustment {
    pub fn hides_ink(&self) -> bool {
        self.opacity == 0
            || self
                .opacity_ramp
                .is_some_and(|ramp| ramp.0.iter().all(|point| point[1] == 0))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Adjustments {
    pub key: String,
    pub glyphs: Vec<Adjustment>,
}

/// Original paper-space ink bounds, before any per-glyph adjustment.
#[derive(Serialize)]
pub struct GlyphBounds {
    #[serde(skip)]
    pub is_text: bool,
    #[serde(skip)]
    pub is_native_diagram: bool,
    pub illustration: Option<u32>,
    pub id: u32,
    pub bounds: [i32; 4],
    pub source_utf16: Option<[u32; 2]>,
    pub baseline: i32,
}

/// Inspect a one-based page without encoding or exposing its glyph mask atlas.
pub fn inspect_page(
    request: &crate::RenderRequest,
    page: usize,
    cancel: &Cancellation,
) -> Result<(String, Vec<GlyphBounds>)> {
    if !request.params.fine_edit || !(1..=request.limits.max_pages).contains(&page) {
        return Err(Error::new("invalid_parameter", "Invalid fine edit page"));
    }
    let mut geometry = None;
    let pages = crate::render::render_pages(request, cancel, page, |i, _, ink| {
        if i + 1 == page
            && let Some(crate::render::PageInk::Fine(tiles)) = ink
        {
            geometry = Some(
                tiles
                    .into_iter()
                    .map(|t| GlyphBounds {
                        id: t.id,
                        is_text: t.is_text,
                        is_native_diagram: t.is_native_diagram,
                        illustration: t.illustration,
                        bounds: [t.x, t.y, t.mask.width() as i32, t.mask.height() as i32],
                        source_utf16: t.source,
                        baseline: t.baseline,
                    })
                    .collect(),
            );
        }
        Ok(())
    })?;
    Ok((
        document_key(&request.text, &request.params),
        geometry.ok_or_else(|| {
            Error::new(
                "invalid_page",
                format!("Page {page} not found; available page count: {pages}"),
            )
        })?,
    ))
}

impl Adjustments {
    pub(crate) fn parse(raw: &str) -> Result<Self> {
        let invalid = || Error::new("invalid_parameter", "fine_edits");
        // 2026-11-19：保留万字调整上限，为每个字的透视系数留出空间。
        if raw.len() > 4_000_000 {
            return Err(invalid());
        }
        let value: Self = serde_json::from_str(raw).map_err(|_| invalid())?;
        if !value.valid() {
            return Err(invalid());
        }
        Ok(value)
    }

    pub(crate) fn valid(&self) -> bool {
        self.key.len() == 64
            && self.key.bytes().all(|b| b.is_ascii_hexdigit())
            && self.glyphs.len() <= 10_000
            && self.glyphs.iter().all(|v| {
                (-65535..=65535).contains(&v.dx)
                    && (-65535..=65535).contains(&v.dy)
                    && (50..=200).contains(&v.scale)
                    && (-45..=45).contains(&v.angle)
                    && v.opacity <= 100
                    && v.opacity_ramp.is_none_or(OpacityRamp::valid)
                    && (-20..=20).contains(&v.thickness)
                    && (-20..=20).contains(&v.softness)
                    && v.warp
                        .is_none_or(|m| m.into_iter().all(|value| value.abs() <= 65_535.))
            })
    }
}

pub(crate) fn document_key(text: &str, p: &Parameters) -> String {
    let mut hash = Sha256::new();
    hash.update(b"panache-fine-2\0");
    hash.update(text.as_bytes());
    hash.update([
        u8::from(p.english_spacing),
        u8::from(p.first_line_indent || p.monospaced),
        u8::from(p.layout_style == LayoutStyle::Homework),
    ]);
    format!("{:x}", hash.finalize())
}

pub(crate) struct Tile {
    pub is_text: bool,
    pub is_native_diagram: bool,
    pub illustration: Option<u32>,
    pub id: u32,
    pub x: i32,
    pub y: i32,
    pub baseline: i32,
    pub mask: GrayImage,
    pub source: Option<[u32; 2]>,
}

pub(crate) const PAD: u32 = 4;
pub(crate) const PAGE_TILE_BUDGET: usize = 32_000_000;

#[derive(Debug, Serialize)]
pub struct EncodedFinePage {
    pub key: String,
    pub atlas: String,
    // 2026-11-18：每项为编号、纸面坐标、蒙版大小、图集坐标、基线。
    pub glyphs: Vec<[i32; 8]>,
    pub source_ranges: Vec<Option<[u32; 2]>>,
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub illustrations: std::collections::BTreeMap<u32, Vec<u32>>,
}

pub(crate) fn encode(key: &str, tiles: &[Tile], cancel: &Cancellation) -> Result<EncodedFinePage> {
    let area: usize = tiles.iter().map(|t| t.mask.len()).sum();
    let width = (area.isqrt() as u32).max(tiles.iter().map(|t| t.mask.width()).max().unwrap_or(1));
    let (mut x, mut y, mut row) = (0, 0, 0);
    let mut glyphs = Vec::with_capacity(tiles.len());
    for tile in tiles {
        let (w, h) = tile.mask.dimensions();
        if x + w > width {
            (x, y, row) = (0, y + row, 0);
        }
        glyphs.push([
            tile.id as i32,
            tile.x,
            tile.y,
            w as i32,
            h as i32,
            x as i32,
            y as i32,
            tile.baseline,
        ]);
        x += w;
        row = row.max(h);
    }
    if u64::from(width) * u64::from((y + row).max(1)) > 48_000_000 {
        return Err(Error::new("invalid_layout", "字形图集超过内存预算"));
    }
    let mut atlas = RgbaImage::from_pixel(width, (y + row).max(1), Rgba([0, 0, 0, 255]));
    for (tile, slot) in tiles.iter().zip(&glyphs) {
        cancel.check()?;
        for (x, y, pixel) in tile.mask.enumerate_pixels() {
            atlas[(x + slot[5] as u32, y + slot[6] as u32)][0] = pixel[0];
        }
    }
    let mut illustrations = std::collections::BTreeMap::<_, Vec<_>>::new();
    for t in tiles {
        if let Some(id) = t.illustration {
            illustrations.entry(id).or_default().push(t.id);
        }
    }
    Ok(EncodedFinePage {
        illustrations,
        key: key.to_owned(),
        atlas: STANDARD.encode(export::png(&atlas)?),
        glyphs,
        source_ranges: tiles.iter().map(|tile| tile.source).collect(),
    })
}

pub(crate) fn overrides<'a>(key: &str, p: &'a Parameters) -> HashMap<u32, &'a Adjustment> {
    p.fine_edits
        .as_ref()
        .filter(|edits| edits.key == key)
        .into_iter()
        .flat_map(|edits| &edits.glyphs)
        .map(|edit| (edit.id, edit))
        .collect()
}

// 2026-11-19：验证透视面后再逆向采样，避免字迹穿过消失线。
fn projected_geometry(
    [a, b, c, d, e, f, g, h]: [f64; 8],
    width: f64,
    height: f64,
    scale: f64,
    cos: f64,
    sin: f64,
) -> Option<([f64; 4], [f64; 9])> {
    let inverse = [
        e - f * h,
        c * h - b,
        b * f - c * e,
        f * g - d,
        a - c * g,
        c * d - a * f,
        d * h - e * g,
        b * g - a * h,
        a * e - b * d,
    ];
    if (a * inverse[0] + b * inverse[3] + c * inverse[6]).abs() < 1e-12 {
        return None;
    }
    let mut bounds = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for u in [-width / 2., width / 2.] {
        for v in [-height / 2., height / 2.] {
            let x = scale * (cos * u - sin * v);
            let y = scale * (sin * u + cos * v);
            let z = g * x + h * y + 1.;
            if z < 0.15 {
                return None;
            }
            let px = (a * x + b * y + c) / z;
            let py = (d * x + e * y + f) / z;
            if px.abs().max(py.abs()) > 65_535. {
                return None;
            }
            bounds = [
                bounds[0].min(px),
                bounds[1].min(py),
                bounds[2].max(px),
                bounds[3].max(py),
            ];
        }
    }
    let original_width = scale * (cos.abs() * width + sin.abs() * height);
    let original_height = scale * (sin.abs() * width + cos.abs() * height);
    if (bounds[2] - bounds[0]) * (bounds[3] - bounds[1]) > 32. * original_width * original_height {
        return None;
    }
    Some((bounds, inverse))
}

// Validate a local shape together with its existing scale and rotation.
pub fn usable_shape(edit: &Adjustment, width: i32, height: i32) -> bool {
    let (sin, cos) = f64::from(edit.angle).to_radians().sin_cos();
    edit.warp.is_none_or(|warp| {
        projected_geometry(
            warp,
            f64::from(width),
            f64::from(height),
            f64::from(edit.scale) / 100.,
            cos,
            sin,
        )
        .is_some()
    })
}

pub(crate) fn paint(
    paper: &mut RgbaImage,
    tile: Tile,
    p: &Parameters,
    edit: Option<&Adjustment>,
    cancel: &Cancellation,
) -> Result<()> {
    let (base_thickness, base_softness, base_fill, base_opacity) =
        if tile.illustration.is_some() && !p.illustration_uses_pen {
            (0., 0., [20, 20, 25, 255], 100)
        } else {
            (p.ink_thickness, p.ink_softness, p.fill, p.ink_opacity)
        };
    let thickness =
        (base_thickness + edit.map_or(0., |v| f64::from(v.thickness) / 10.)).clamp(-2., 2.);
    let softness = (base_softness + edit.map_or(0., |v| f64::from(v.softness) / 10.)).clamp(0., 2.);
    let mask = ink_effects::shape(tile.mask, thickness, softness, cancel)?;
    let (w, h) = (f64::from(mask.width()), f64::from(mask.height()));
    let scale = edit.map_or(1., |v| f64::from(v.scale) / 100.);
    let angle = edit.map_or(0., |v| f64::from(v.angle) * std::f64::consts::PI / 180.);
    let (sin, cos) = angle.sin_cos();
    let cx = f64::from(tile.x + edit.map_or(0, |v| v.dx)) + w / 2.;
    let cy = f64::from(tile.y + edit.map_or(0, |v| v.dy)) + h / 2.;
    let rx = scale * (cos.abs() * w + sin.abs() * h) / 2.;
    let ry = scale * (sin.abs() * w + cos.abs() * h) / 2.;
    let projected = edit
        .and_then(|v| v.warp)
        .and_then(|warp| projected_geometry(warp, w, h, scale, cos, sin));
    let [left, top, right, bottom] = projected.map_or([-rx, -ry, rx, ry], |p| p.0);
    let color = edit
        .and_then(|v| v.color)
        .unwrap_or([base_fill[0], base_fill[1], base_fill[2]]);
    let opacity = u32::from(edit.map_or(100, |v| v.opacity));
    let row_opacity = edit.and_then(|e| e.opacity_ramp).map(|ramp| {
        (0..mask.height())
            .map(|y| {
                let position = (f64::from(y) + 0.5) * 100. / h;
                (f64::from(opacity) * ramp.multiplier(position)).round() as u32
            })
            .collect::<Vec<_>>()
    });
    for y in ((cy + top).floor().max(0.) as u32)
        ..((cy + bottom).ceil().max(0.) as u32).min(paper.height())
    {
        cancel.check()?;
        let dy = f64::from(y) + 0.5 - cy;
        for x in ((cx + left).floor().max(0.) as u32)
            ..((cx + right).ceil().max(0.) as u32).min(paper.width())
        {
            let dx = f64::from(x) + 0.5 - cx;
            let (dx, dy) = if let Some((_, [a, b, c, d, e, f, g, h, i])) = projected {
                let z = g * dx + h * dy + i;
                ((a * dx + b * dy + c) / z, (d * dx + e * dy + f) / z)
            } else {
                (dx, dy)
            };
            let sx = ((dx * cos + dy * sin) / scale + w / 2. + 1e-9).floor();
            let sy = ((-dx * sin + dy * cos) / scale + h / 2. + 1e-9).floor();
            if !(sx >= 0. && sy >= 0. && sx < w && sy < h) {
                continue;
            }
            let alpha = (u32::from(mask[(sx as u32, sy as u32)][0])
                * u32::from(base_opacity)
                * u32::from(base_fill[3])
                + 12_750)
                / 25_500;
            let local = row_opacity
                .as_ref()
                .map_or(opacity, |rows| rows[sy as usize]);
            let alpha = (alpha * local + 50) / 100;
            let pixel = &mut paper[(x, y)];
            if pixel[3] < 255 {
                use image::Pixel;
                pixel.blend(&Rgba([color[0], color[1], color[2], alpha as u8]));
                continue;
            }
            for (ch, value) in pixel.0[..3].iter_mut().zip(color) {
                *ch =
                    ((u32::from(*ch) * (255 - alpha) + u32::from(value) * alpha + 127) / 255) as u8;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Adjustment, Adjustments};

    #[test]
    fn parses_perspective_edits_for_ten_thousand_glyphs() {
        let data = Adjustments {
            key: "0".repeat(64),
            glyphs: (0..10_000)
                .map(|id| Adjustment {
                    id,
                    dx: 0,
                    dy: 0,
                    scale: 100,
                    angle: 0,
                    opacity: 100,
                    opacity_ramp: None,
                    color: None,
                    thickness: 0,
                    softness: 0,
                    warp: Some([
                        1.001_234_567_89,
                        0.012_345_6,
                        0.1,
                        0.012_345_6,
                        1.,
                        0.1,
                        0.000_012_345_6,
                        0.000_012_345_6,
                    ]),
                })
                .collect(),
        };
        let raw = serde_json::to_string(&data).unwrap();
        assert!(raw.len() > 1_000_000);
        assert_eq!(
            Adjustments::parse(&raw).unwrap().glyphs.len(),
            data.glyphs.len()
        );
    }
}
