//! 2026-11-18：从仍未合并的墨迹生成字形蒙版，保留纸张与相邻字迹。
use super::{Glyph, LineUnit, glyph::PositionedGlyph, ink};
use crate::{Cancellation, Parameters, Result, fine_edit, ink_effects, text::Node};
use image::{GrayImage, RgbaImage};
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;

pub(super) fn source_ranges(source: &str, normalized: &str, nodes: &[Node]) -> Option<Vec<u32>> {
    // 2026-11-18：解析器改写内容时保守地只提供画布选择，避免关联到错误原文。
    if source != normalized
        || !source.chars().eq(nodes.iter().map(|node| match node {
            Node::Char(ch) => *ch,
            Node::Newline => '\n',
            _ => '\0',
        }))
    {
        return None;
    }
    let mut index = 0;
    Some(
        std::iter::once(0)
            .chain(source.chars().map(|ch| {
                index += ch.len_utf16() as u32;
                index
            }))
            .collect(),
    )
}

pub(super) fn capture(
    unit: LineUnit,
    origin: (i32, i32),
    baseline: i32,
    p: &Parameters,
    cancel: &Cancellation,
) -> Result<Vec<fine_edit::Tile>> {
    let Some(parts) = unit.fine_parts else {
        return Ok(capture_one(unit, origin, baseline, p, cancel)?
            .into_iter()
            .collect());
    };
    let (width, height) = unit.glyph.mask.dimensions();
    let (old_width, old_height) = parts.size;
    let mut tiles = Vec::new();
    for (index, (mut glyph, x, y)) in parts.children.into_iter().enumerate() {
        if !glyph.ink {
            continue;
        }
        let x = i64::from(x + glyph.left - parts.left) * i64::from(width) / i64::from(old_width);
        let y = i64::from(y + glyph.top - parts.top) * i64::from(height) / i64::from(old_height);
        if width != old_width || height != old_height {
            let (w, h) = glyph.mask.dimensions();
            let w = (u64::from(w) * u64::from(width) / u64::from(old_width)).max(1) as u32;
            let h = (u64::from(h) * u64::from(height) / u64::from(old_height)).max(1) as u32;
            let mut mask = GrayImage::new(w, h);
            for (old_x, old_y, pixel) in glyph.mask.enumerate_pixels() {
                let at = (
                    old_x * w / glyph.mask.width(),
                    old_y * h / glyph.mask.height(),
                );
                mask[at][0] = mask[at][0].max(pixel[0]);
            }
            glyph.mask = mask;
        }
        let child = LineUnit {
            glyph,
            id: unit.id + index as u32,
            source: parts.ranges.get(index).copied(),
            fine_parts: None,
            ..unit
        };
        if let Some(tile) = capture_one(
            child,
            (origin.0 + x as i32, origin.1 + y as i32),
            baseline,
            p,
            cancel,
        )? {
            tiles.push(tile);
        }
    }
    Ok(tiles)
}

pub(super) struct Parts {
    children: Vec<PositionedGlyph>,
    size: (u32, u32),
    left: i32,
    top: i32,
    ranges: Vec<[u32; 2]>,
}

impl Parts {
    pub(super) fn new(
        glyph: &Glyph,
        children: Vec<PositionedGlyph>,
        start: usize,
        source: Option<&[u32]>,
    ) -> Self {
        let ranges = source.map_or_else(Vec::new, |positions| {
            positions[start..=start + children.len()]
                .windows(2)
                .map(|pair| [pair[0], pair[1]])
                .collect()
        });
        Self {
            children,
            size: glyph.mask.dimensions(),
            left: glyph.left,
            top: glyph.top,
            ranges,
        }
    }
}

fn capture_one(
    unit: LineUnit,
    origin: (i32, i32),
    baseline: i32,
    p: &Parameters,
    cancel: &Cancellation,
) -> Result<Option<fine_edit::Tile>> {
    if !unit.glyph.ink {
        return Ok(None);
    }
    let w = unit.glyph.mask.width();
    let h = unit.glyph.mask.height();
    let radius = (p.perturb_x_sigma.max(p.perturb_y_sigma) * 3.
        + (w.max(h) as f32 * p.perturb_theta_sigma * 2.))
        .ceil()
        .clamp(0., 96.) as u32;
    let mut rendered = RgbaImage::new(w + radius * 2, h + radius * 2);
    let mut rng =
        ChaCha8Rng::seed_from_u64(p.seed ^ u64::from(unit.id).wrapping_mul(0x9e3779b97f4a7c15));
    let mut raw = unit.glyph.mask;
    if unit.rigid {
        let tile_params = Parameters {
            left_margin: 0.,
            top_margin: 0.,
            right_margin: 0.,
            bottom_margin: 0.,
            word_spacing: 0.,
            fill: p.fill,
            perturb_x_sigma: p.perturb_x_sigma,
            perturb_y_sigma: p.perturb_y_sigma,
            perturb_theta_sigma: p.perturb_theta_sigma,
            ink_depth_sigma: p.ink_depth_sigma,
            ..Parameters::default()
        };
        ink::paint_math_unit(
            &mut rendered,
            &raw,
            (radius as i32, radius as i32),
            &tile_params,
            unit.align_to_rulings,
            &mut rng,
            cancel,
        )?;
    } else {
        if radius > 0 {
            let mut padded = GrayImage::new(rendered.width(), rendered.height());
            ink::paste_mask(&mut padded, &raw, radius as i32, radius as i32);
            raw = padded;
        }
        ink::perturb(&mut raw, &mut rendered, p, &mut rng, cancel)?;
    }
    let raw = ink_effects::coverage(&rendered);
    let (mut left, mut top, mut right, mut bottom) = (raw.width(), raw.height(), 0, 0);
    for (x, y, _) in raw.enumerate_pixels().filter(|(_, _, v)| v[0] != 0) {
        (left, top, right, bottom) = (left.min(x), top.min(y), right.max(x + 1), bottom.max(y + 1));
    }
    if right == 0 {
        return Ok(None);
    }
    let pad = fine_edit::PAD;
    let crop = image::imageops::crop_imm(&raw, left, top, right - left, bottom - top).to_image();
    let mut mask = GrayImage::new(crop.width() + pad * 2, crop.height() + pad * 2);
    ink::paste_mask(&mut mask, &crop, pad as i32, pad as i32);
    Ok(Some(fine_edit::Tile {
        id: unit.id,
        illustration: None,
        x: origin.0 + left as i32 - radius as i32 - pad as i32,
        y: origin.1 + top as i32 - radius as i32 - pad as i32,
        baseline,
        mask,
        source: unit.source,
    }))
}
