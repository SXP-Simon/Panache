use crate::{
    Error, LayoutStyle, Limits, Parameters, Result, fine_edit, imaging, ink_effects,
    text::{self, Node},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use image::{GrayImage, RgbaImage};
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone, Default, Debug)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn check(&self) -> Result<()> {
        if self.0.load(Ordering::Acquire) {
            Err(Error::new("cancelled", "任务已取消"))
        } else {
            Ok(())
        }
    }
}
pub use crate::fonts::FontBook;
pub struct RenderRequest {
    pub text: String,
    pub params: Parameters,
    pub background: Option<Vec<u8>>,
    pub fonts: FontBook,
    pub limits: Limits,
}
mod composition;
mod fine;
mod glyph;
mod homework;
mod illustration;
mod ink;
mod line;
mod paragraph;
mod units;
use glyph::{Glyph, Glyphs};
use ink::{blank_paper, normal, paint_math_unit, paste_mask, perturb};
use units::{fixed_cell, keeps_grid_cell, layout_units};
// 2026-10-15：先缓存整行，知道最高根式/最低分母后再统一落笔，避免后出现的公式撞进上一行。
struct LineUnit {
    is_text: bool,
    glyph: Glyph,
    rigid: bool,
    align_to_rulings: bool,
    x: i32,
    dy: i32,
    break_after: bool,
    id: u32,
    source: Option<[u32; 2]>,
    fine_parts: Option<fine::Parts>,
}
pub(crate) enum PageInk {
    Flat(GrayImage),
    Fine(Vec<fine_edit::Tile>),
}
struct Pages<'a, F>
where
    F: FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
{
    background: RgbaImage,
    canvas: RgbaImage,
    ink_layer: Option<RgbaImage>,
    mask: GrayImage,
    tiles: Vec<fine_edit::Tile>,
    tile_area: usize,
    p: &'a Parameters,
    rng: ChaCha8Rng,
    cancel: &'a Cancellation,
    x: f32,
    y: f32,
    previous_bottom: f32,
    written_lines: usize,
    line: Vec<LineUnit>,
    dirty: bool,
    count: usize,
    max_pages: usize,
    stop_after: usize,
    emit: F,
    stopped: bool,
}
impl<F: FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>> Pages<'_, F> {
    fn push_tile(&mut self, tile: fine_edit::Tile) -> Result<()> {
        self.tile_area += tile.mask.len();
        if self.tile_area > fine_edit::PAGE_TILE_BUDGET {
            return Err(Error::new("invalid_layout", "当前页的墨迹超过内存预算"));
        }
        self.tiles.push(tile);
        Ok(())
    }
    fn flush_ink(&mut self) -> Result<()> {
        if self.p.fine_edit {
            return Ok(());
        }
        perturb(
            &mut self.mask,
            self.ink_layer.as_mut().unwrap_or(&mut self.canvas),
            self.p,
            &mut self.rng,
            self.cancel,
        )
    }

    fn emit_page(&mut self, force: bool) -> Result<()> {
        if (!self.dirty && !force) || self.stopped {
            return Ok(());
        }
        self.cancel.check()?;
        if self.count >= self.max_pages {
            return Err(Error::new("page_limit", "页数超出限制"));
        }
        self.flush_ink()?;
        let canvas = std::mem::replace(&mut self.canvas, self.background.clone());
        let alpha = if self.p.fine_edit {
            self.tile_area = 0;
            Some(PageInk::Fine(std::mem::take(&mut self.tiles)))
        } else {
            self.ink_layer.as_mut().map(|ink| {
                let alpha = ink_effects::coverage(ink);
                ink.as_mut().fill(0);
                PageInk::Flat(alpha)
            })
        };
        (self.emit)(self.count, canvas, alpha)?;
        self.count += 1;
        self.stopped = self.count >= self.stop_after
            || (self.p.preview && !self.p.full_preview && !self.p.pdf_save);
        self.x = self.p.left_margin;
        self.y = self.p.top_margin + self.p.line_spacing;
        self.previous_bottom = self.p.top_margin;
        self.dirty = false;
        Ok(())
    }
    fn finish_line(&mut self) -> Result<()> {
        if self.line.is_empty() {
            return Ok(());
        }
        let mut units = std::mem::take(&mut self.line);
        let mut layout = line::LineLayout::fit(&mut units, self.p, self.canvas.height());
        let mut anchor = layout.baseline(self.y, self.dirty.then_some(self.previous_bottom));
        if layout.overflows(anchor) && self.dirty {
            self.emit_page(false)?;
            if self.stopped {
                return Ok(());
            }
            anchor = layout.baseline(self.y, None);
        }
        if layout.overflows(anchor) {
            anchor = layout.fit_empty_page(&mut units);
        }
        for u in units {
            let origin = (
                u.x + u.glyph.left,
                anchor.round() as i32 + u.dy + u.glyph.top,
            );
            if self.p.fine_edit {
                for tile in fine::capture(u, origin, anchor.round() as i32, self.p, self.cancel)? {
                    self.push_tile(tile)?;
                }
            } else if u.rigid {
                paint_math_unit(
                    self.ink_layer.as_mut().unwrap_or(&mut self.canvas),
                    &u.glyph.mask,
                    origin,
                    self.p,
                    u.align_to_rulings,
                    &mut self.rng,
                    self.cancel,
                )?;
            } else {
                paste_mask(&mut self.mask, &u.glyph.mask, origin.0, origin.1);
            }
        }
        self.written_lines += 1;
        self.previous_bottom = layout.ink_bottom(anchor);
        self.y = anchor + self.p.line_spacing;
        self.x = self.p.left_margin;
        self.dirty = true;
        Ok(())
    }
    fn flush(&mut self, force: bool) -> Result<()> {
        self.finish_line()?;
        self.emit_page(force)
    }
    fn newline(&mut self) -> Result<()> {
        if self.line.is_empty() {
            self.y += self.p.line_spacing;
            self.x = self.p.left_margin;
            Ok(())
        } else {
            self.finish_line()
        }
    }
}
/// 每次仅交付一页像素；调用方负责编码和释放，进度不携带像素。
pub fn render<F: FnMut(usize, RgbaImage) -> Result<()>>(
    r: &RenderRequest,
    cancel: &Cancellation,
    emit: F,
) -> Result<usize> {
    render_until_page(r, cancel, usize::MAX, emit)
}

/// Render a deterministic prefix and stop immediately after delivering its last page.
pub fn render_until_page<F: FnMut(usize, RgbaImage) -> Result<()>>(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    emit: F,
) -> Result<usize> {
    render_output(
        r,
        cancel,
        stop_after,
        None,
        r.params.transparent_background && !r.params.pdf_save,
        emit,
    )
}
/// Unmarked preset stationery for comparison with a rendered page.
pub fn preset_paper(w: u32, h: u32, params: &Parameters, limits: &Limits) -> Result<RgbaImage> {
    params.validate(w, h, limits)?;
    Ok(blank_paper(w, h, params))
}

pub fn render_on_photo<F: FnMut(usize, RgbaImage) -> Result<()>>(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    projection: &crate::photo::PaperProjection,
    photo: &RgbaImage,
    emit: F,
) -> Result<usize> {
    if !r.params.fine_edit || r.params.width.is_none() || r.params.height.is_none() {
        return Err(Error::new(
            "invalid_parameter",
            "Photo projection requires a paper-space fine layout",
        ));
    }
    render_output(r, cancel, stop_after, Some((projection, photo)), true, emit)
}
pub(crate) fn render_output<F: FnMut(usize, RgbaImage) -> Result<()>>(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    photo: Option<(&crate::photo::PaperProjection, &RgbaImage)>,
    transparent: bool,
    mut emit: F,
) -> Result<usize> {
    if stop_after == 0 {
        return Ok(0);
    }
    let key = r
        .params
        .fine_edit
        .then(|| fine_edit::document_key(&r.text, &r.params));
    let edits = key
        .as_deref()
        .map(|key| fine_edit::overrides(key, &r.params))
        .unwrap_or_default();
    render_planes(r, cancel, stop_after, transparent, |i, paper, ink| {
        let image = match ink {
            Some(PageInk::Flat(ink)) => ink_effects::composite(paper, ink, &r.params, cancel)?,
            Some(PageInk::Fine(tiles)) => {
                let mut paper = paper;
                for tile in tiles {
                    let adjustment = edits.get(&tile.id).copied();
                    fine_edit::paint(&mut paper, tile, &r.params, adjustment, cancel)?;
                }
                paper
            }
            None => paper,
        };
        let output = match photo {
            Some((projection, background))
                if r.params.transparent_background && !r.params.pdf_save =>
            {
                let clear = RgbaImage::new(background.width(), background.height());
                projection.composite_into(clear, &image, cancel)?
            }
            Some((projection, background)) => projection.composite(background, &image, cancel)?,
            None => image,
        };
        emit(i, output)
    })
}

/// Run the normal pagination pass, discarding each page before compositing or encoding.
pub fn count_pages(request: &RenderRequest, cancel: &Cancellation) -> Result<usize> {
    render_pages(request, cancel, usize::MAX, |_, _, _| Ok(()))
}

pub(crate) fn render_pages(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    emit: impl FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
) -> Result<usize> {
    render_planes(
        r,
        cancel,
        stop_after,
        r.params.transparent_background && !r.params.pdf_save,
        emit,
    )
}
fn render_planes(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    transparent: bool,
    emit: impl FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
) -> Result<usize> {
    cancel.check()?;
    crate::validate_document(&r.text, &r.limits)?;
    let p = &r.params;
    if p.fine_edit && p.fine_edits.as_ref().is_some_and(|edits| !edits.valid()) {
        return Err(Error::new("invalid_parameter", "fine_edits"));
    }
    let mut background = match (p.width, p.height) {
        (Some(w), Some(h)) => {
            p.validate(w, h, &r.limits)?;
            if transparent {
                RgbaImage::new(w, h)
            } else {
                blank_paper(w, h, p)
            }
        }
        (None, None) => {
            let mut paper = imaging::decode(
                r.background
                    .as_deref()
                    .ok_or_else(|| Error::new("missing_background", "缺少背景图"))?,
                &r.limits,
            )?
            .to_rgba8();
            if transparent {
                paper.as_mut().fill(0);
            }
            paper
        }
        _ => {
            return Err(Error::new(
                "invalid_parameter",
                "width 和 height 必须同时提供",
            ));
        }
    };
    let (w, h) = background.dimensions();
    p.validate(w, h, &r.limits)?;
    let homework_mode = p.layout_style == LayoutStyle::Homework;
    let mut layout = if homework_mode {
        homework::parameters(p, w, h)
    } else {
        p.clone()
    };
    if p.ink_layers || p.fine_edit {
        // The generated mask stores concentration, independent of the selected tint.
        layout.fill = [0, 0, 0, 255];
        if !transparent {
            for pixel in background.pixels_mut() {
                let opacity = u16::from(pixel[3]);
                for channel in &mut pixel.0[..3] {
                    *channel =
                        ((u16::from(*channel) * opacity + 255 * (255 - opacity) + 127) / 255) as u8;
                }
                pixel[3] = 255;
            }
        }
    }
    let p = &layout;
    p.validate(w, h, &r.limits)?;
    let normalized = text::normalize_for_layout(
        &r.text,
        p.english_spacing,
        p.first_line_indent || p.monospaced,
    );
    let nodes = text::parse(&normalized);
    let source = p
        .fine_edit
        .then(|| fine::source_ranges(&r.text, &normalized, &nodes))
        .flatten();
    let units = if homework_mode {
        homework::units(&nodes)
    } else {
        layout_units(&nodes)
    };
    let mut composer = composition::UnitComposer::new(p, &r.text, source.as_deref(), (w, h));
    let mut glyphs = Glyphs::with_parameters(&r.fonts, p)?;
    let mut pages = Pages {
        canvas: background.clone(),
        ink_layer: (p.ink_layers && !p.fine_edit).then(|| RgbaImage::new(w, h)),
        background,
        mask: if p.fine_edit {
            GrayImage::new(0, 0)
        } else {
            GrayImage::new(w, h)
        },
        tiles: Vec::new(),
        tile_area: 0,
        p,
        rng: ChaCha8Rng::seed_from_u64(p.seed),
        cancel,
        x: p.left_margin,
        y: p.top_margin + p.line_spacing,
        previous_bottom: p.top_margin,
        written_lines: 0,
        line: Vec::new(),
        dirty: false,
        count: 0,
        max_pages: r.limits.max_pages,
        stop_after,
        emit,
        stopped: false,
    };
    let right = w as f32 - p.effective_right_margin();
    let mut paragraph = paragraph::ParagraphLayout::new(&nodes, &units, p.left_margin, right);
    let mut next_node_index = 0;
    for (i, &unit) in units.iter().enumerate() {
        if pages.stopped {
            break;
        }
        cancel.check()?;
        let node_index = next_node_index;
        next_node_index += unit.len();
        paragraph.begin_unit(&mut pages, &mut glyphs, i)?;
        match &unit[0] {
            Node::Break => pages.flush(false)?,
            Node::Newline => pages.newline()?,
            Node::RightAlign => {
                let rest = units[i + 1..]
                    .iter()
                    .take_while(|unit| !matches!(unit[0], Node::Newline | Node::Break));
                let mut cursor = 0f32;
                let mut width = 0f32;
                for (offset, unit) in rest.enumerate() {
                    let mut g = glyphs.unit(unit, p.font_size, i + 1 + offset)?;
                    if let Some(cell) = fixed_cell(unit, p) {
                        g = g.place_in_cell(cell);
                    }
                    width = width.max(cursor + g.right() as f32);
                    cursor += g.step(
                        unit,
                        p,
                        0.,
                        unit.len() > 1 || !matches!(unit[0], Node::Char(_)),
                    );
                }
                pages.x = (right - width).max(p.left_margin);
            }
            Node::Image { alt, data } => {
                pages.finish_line()?;
                if pages.stopped {
                    break;
                }
                pages.flush_ink()?;
                let raw = data.split_once(',').map(|(_, s)| s).unwrap_or(data);
                let compact: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
                if compact.len() > r.limits.max_file_bytes * 4 / 3 + 4 {
                    return Err(Error::new("upload_limit", "插图过大"));
                }
                let bytes = STANDARD
                    .decode(compact)
                    .map_err(|e| Error::new("invalid_image", e.to_string()))?;
                let decoded = imaging::decode(&bytes, &r.limits)?;
                // 2026-10-16：按版心缩小后再运行滤镜，避免大图产生巨型临时缓冲。
                let fitted = imaging::fit(
                    &decoded.to_rgba8(),
                    (w as f32 - p.left_margin - p.right_margin).max(1.) as u32,
                    (h as f32 - p.top_margin - p.bottom_margin).max(1.) as u32,
                    imaging::scale(alt),
                );
                let image = imaging::handdrawn(
                    &image::DynamicImage::ImageRgba8(fitted),
                    p.seed.wrapping_add(i as u64),
                    cancel,
                )?;
                let top = if pages.dirty {
                    pages.previous_bottom + p.line_spacing
                } else {
                    p.top_margin
                };
                let mut top = top;
                if top + image.height() as f32 > h as f32 - p.bottom_margin {
                    pages.flush(false)?;
                    if pages.stopped {
                        break;
                    }
                    top = p.top_margin;
                }
                let x = p.left_margin
                    + ((w as f32 - p.left_margin - p.right_margin - image.width() as f32) / 2.)
                        .max(0.);
                if p.fine_edit {
                    for tile in illustration::tiles(
                        &decoded,
                        &image,
                        node_index as u32,
                        x as i32,
                        top as i32,
                        fine_edit::PAGE_TILE_BUDGET - pages.tile_area,
                        cancel,
                    )? {
                        pages.push_tile(tile)?;
                    }
                } else {
                    image::imageops::overlay(&mut pages.canvas, &image, x as i64, top as i64);
                }
                pages.dirty = true;
                pages.x = p.left_margin;
                pages.previous_bottom = top + image.height() as f32;
                pages.y = pages.previous_bottom + p.line_spacing;
            }
            node => {
                let composition::PreparedGlyph {
                    glyph,
                    compound,
                    fine_parts,
                } = composer.prepare(&mut glyphs, &mut pages.rng, unit, i, node_index)?;
                if homework_mode
                    && homework::break_before(unit)
                    && let Some(previous) = pages.line.last_mut()
                {
                    previous.break_after = true;
                }
                let usable_height = h as f32 - p.top_margin - p.bottom_margin;
                let cell = fixed_cell(unit, p);
                let mut g = glyph.fit(paragraph.usable_width(), usable_height);
                if let Some(cell) = cell {
                    g = g.place_in_cell(cell);
                }
                let jitter_x = if cell.is_none() && p.grid_layout && keeps_grid_cell(unit) {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                } else {
                    0.
                };
                let Some(x) = paragraph.position(&mut pages, i, &g, cell, jitter_x)? else {
                    continue;
                };
                let dy = normal(&mut pages.rng, p.line_spacing_sigma)
                    .round()
                    .clamp(-usable_height * 0.25, usable_height * 0.25)
                    as i32;
                let extra = if p.grid_layout && keeps_grid_cell(unit) {
                    0.
                } else {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                };
                let advance = g.step(unit, p, extra, compound);
                pages.x = x + advance;
                pages.line.push(LineUnit {
                    is_text: unit.iter().all(|node| matches!(node, Node::Char(_))),
                    glyph: g,
                    rigid: compound || cell.is_some(),
                    align_to_rulings: matches!(node, Node::Circuit(_) | Node::Table(_))
                        && (p.background_ruled || p.underlined || p.paper_pattern.is_some()),
                    x: x.round() as i32,
                    dy,
                    break_after: homework_mode && homework::break_after(unit),
                    id: node_index as u32,
                    source: source
                        .as_ref()
                        .map(|positions| [positions[node_index], positions[next_node_index]]),
                    fine_parts,
                });
            }
        }
    }
    if !pages.stopped {
        pages.flush(pages.count == 0)?;
    }
    Ok(pages.count)
}

#[cfg(test)]
mod ruled_tests {
    use super::*;
    use image::Luma;

    fn sample_line() -> Vec<LineUnit> {
        vec![LineUnit {
            is_text: true,
            glyph: Glyph {
                mask: GrayImage::from_pixel(8, 40, Luma([255])),
                advance: 8.,
                left: 0,
                top: -30,
                ink: true,
            },
            rigid: false,
            align_to_rulings: false,
            x: 10,
            dy: 0,
            break_after: false,
            id: 0,
            source: None,
            fine_parts: None,
        }]
    }

    #[test]
    fn tall_lines_keep_the_ruled_phase_across_pages_and_image_offsets() {
        for (spacing, uploaded) in [32., 32.3, 42.]
            .into_iter()
            .flat_map(|spacing| [(spacing, false), (spacing, true)])
        {
            let p = Parameters {
                font_size: 24.,
                line_spacing: spacing,
                top_margin: 10.,
                bottom_margin: 13.,
                left_margin: 10.,
                right_margin: 10.,
                width: if uploaded { None } else { Some(180) },
                height: if uploaded { None } else { Some(193) },
                underlined: !uploaded,
                background_ruled: uploaded,
                preview: false,
                perturb_x_sigma: 0.,
                perturb_y_sigma: 0.,
                perturb_theta_sigma: 0.,
                ink_depth_sigma: 0.,
                ..Parameters::default()
            };
            let cancel = Cancellation::default();
            let bg = blank_paper(180, 193, &p);
            let mut pages = Pages {
                background: bg.clone(),
                canvas: bg,
                ink_layer: None,
                mask: GrayImage::new(180, 193),
                tiles: Vec::new(),
                tile_area: 0,
                p: &p,
                rng: ChaCha8Rng::seed_from_u64(42),
                cancel: &cancel,
                x: 10.,
                y: 10. + spacing,
                previous_bottom: 10.,
                written_lines: 0,
                line: vec![],
                dirty: false,
                count: 0,
                max_pages: 100,
                stop_after: usize::MAX,
                emit: |_, _, _| Ok(()),
                stopped: false,
            };
            for n in 0..20 {
                if n == 7 {
                    // 模拟插图占用了非整数行格的高度。
                    pages.previous_bottom += 17.;
                    pages.y = pages.previous_bottom + spacing;
                }
                pages.line = sample_line();
                pages.finish_line().unwrap();
                let baseline = pages.y - spacing;
                let grid = (baseline - p.top_margin) / spacing;
                assert!(
                    (grid - grid.round()).abs() < 0.0001,
                    "baseline {baseline}, spacing {spacing}"
                );
                assert!(pages.previous_bottom <= 180.);
                assert!(baseline - 30. >= p.top_margin);
            }
            assert!(pages.count >= 4);
            pages.flush(false).unwrap();
            let mut giant = sample_line();
            giant[0].glyph.mask = GrayImage::from_pixel(8, 400, Luma([255]));
            giant[0].glyph.top = -220;
            pages.line = giant;
            pages.finish_line().unwrap();
            let grid = (pages.y - spacing - p.top_margin) / spacing;
            assert!((grid - grid.round()).abs() < 0.0001);
            assert!(pages.previous_bottom <= 180.);
            let painted_top = pages
                .mask
                .enumerate_pixels()
                .filter(|(_, _, pixel)| pixel[0] > 128)
                .map(|(_, y, _)| y)
                .min()
                .unwrap();
            assert!(painted_top >= p.top_margin as u32);
        }
    }
}
