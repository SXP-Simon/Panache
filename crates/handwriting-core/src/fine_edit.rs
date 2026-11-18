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
    pub color: Option<[u8; 3]>,
    // 2026-11-18：相对全局设置的偏移，以 0.1 px 为单位。
    #[serde(default)]
    pub thickness: i8,
    #[serde(default)]
    pub softness: i8,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Adjustments {
    pub key: String,
    pub glyphs: Vec<Adjustment>,
}

impl Adjustments {
    pub(crate) fn parse(raw: &str) -> Result<Self> {
        let invalid = || Error::new("invalid_parameter", "fine_edits");
        if raw.len() > 1_000_000 {
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
                    && (-20..=20).contains(&v.thickness)
                    && (-20..=20).contains(&v.softness)
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
    Ok(EncodedFinePage {
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

pub(crate) fn paint(
    paper: &mut RgbaImage,
    tile: Tile,
    p: &Parameters,
    edit: Option<&Adjustment>,
    cancel: &Cancellation,
) -> Result<()> {
    let thickness =
        (p.ink_thickness + edit.map_or(0., |v| f64::from(v.thickness) / 10.)).clamp(-2., 2.);
    let softness =
        (p.ink_softness + edit.map_or(0., |v| f64::from(v.softness) / 10.)).clamp(0., 2.);
    let mask = ink_effects::shape(tile.mask, thickness, softness, cancel)?;
    let (w, h) = (f64::from(mask.width()), f64::from(mask.height()));
    let scale = edit.map_or(1., |v| f64::from(v.scale) / 100.);
    let angle = edit.map_or(0., |v| f64::from(v.angle) * std::f64::consts::PI / 180.);
    let (sin, cos) = angle.sin_cos();
    let cx = f64::from(tile.x + edit.map_or(0, |v| v.dx)) + w / 2.;
    let cy = f64::from(tile.y + edit.map_or(0, |v| v.dy)) + h / 2.;
    let rx = scale * (cos.abs() * w + sin.abs() * h) / 2.;
    let ry = scale * (sin.abs() * w + cos.abs() * h) / 2.;
    let color = edit
        .and_then(|v| v.color)
        .unwrap_or([p.fill[0], p.fill[1], p.fill[2]]);
    let opacity = u32::from(edit.map_or(100, |v| v.opacity));
    for y in
        ((cy - ry).floor().max(0.) as u32)..((cy + ry).ceil().max(0.) as u32).min(paper.height())
    {
        cancel.check()?;
        let dy = f64::from(y) + 0.5 - cy;
        for x in
            ((cx - rx).floor().max(0.) as u32)..((cx + rx).ceil().max(0.) as u32).min(paper.width())
        {
            let dx = f64::from(x) + 0.5 - cx;
            let sx = ((dx * cos + dy * sin) / scale + w / 2. + 1e-9).floor();
            let sy = ((-dx * sin + dy * cos) / scale + h / 2. + 1e-9).floor();
            if sx < 0. || sy < 0. || sx >= w || sy >= h {
                continue;
            }
            let alpha = (u32::from(mask[(sx as u32, sy as u32)][0])
                * u32::from(p.ink_opacity)
                * u32::from(p.fill[3])
                + 12_750)
                / 25_500;
            let alpha = (alpha * opacity + 50) / 100;
            for (ch, value) in paper[(x, y)].0[..3].iter_mut().zip(color) {
                *ch =
                    ((u32::from(*ch) * (255 - alpha) + u32::from(value) * alpha + 127) / 255) as u8;
            }
        }
    }
    Ok(())
}
