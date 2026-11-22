use crate::{
    Error, LayoutStyle, Limits, Parameters, Result, fine_edit, imaging, ink_effects,
    text::{self, Node},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use image::{GrayImage, RgbaImage};
use rand::{RngExt, SeedableRng};
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
mod fine;
mod glyph;
mod homework;
mod illustration;
mod ink;
mod units;
use glyph::{Glyph, Glyphs};
use ink::{blank_paper, normal, paint_math_unit, paste_mask, perturb};
use units::{fixed_cell, keeps_grid_cell, layout_units};
// 2026-10-15：先缓存整行，知道最高根式/最低分母后再统一落笔，避免后出现的公式撞进上一行。
struct LineUnit {
    glyph: Glyph,
    rigid: bool,
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
        let top = self.p.top_margin;
        let bottom = self.canvas.height() as f32 - self.p.bottom_margin;
        let available = (bottom - top).max(1.);
        let ruled = ((self.p.underlined || self.p.paper_pattern.is_some())
            && self.p.width.is_some())
            || self.p.background_ruled;
        let standard_ruled = ruled && self.p.layout_style == LayoutStyle::Standard;
        let mut gap = (self.p.font_size * 0.12).round().max(2.);
        if standard_ruled {
            gap = gap.min((self.p.line_spacing - self.p.font_size).max(2.));
        }
        let bounds = |units: &[LineUnit]| {
            let visible: Vec<_> = units.iter().filter(|u| u.glyph.ink).collect();
            (
                visible
                    .iter()
                    .map(|u| u.glyph.top + u.dy)
                    .min()
                    .unwrap_or(0),
                visible
                    .iter()
                    .map(|u| u.glyph.bottom() + u.dy)
                    .max()
                    .unwrap_or(0),
            )
        };
        let (mut min_y, mut max_y) = bounds(&units);
        if (max_y - min_y) as f32 > available {
            let factor = available / (max_y - min_y) as f32;
            for u in &mut units {
                let old_top = u.glyph.top;
                let old_dy = u.dy;
                u.glyph = u.glyph.clone().fit(
                    u.glyph.mask.width() as f32 * factor,
                    (u.glyph.mask.height() as f32 * factor).max(1.),
                );
                u.dy = ((old_top + old_dy - min_y) as f32 * factor).floor() as i32 - u.glyph.top;
            }
            (min_y, max_y) = bounds(&units);
        }
        if standard_ruled {
            let height = (self.p.line_spacing - gap).floor() as i32;
            let descent = (self.p.font_size * 0.30).round() as i32;
            fit_standard_ruled_row(&mut units, min_y, max_y, height, descent);
            (min_y, max_y) = bounds(&units);
        }
        // 2026-10-17：公式可占多格，后续基线仍须落在原纸张横线上。
        let align = |anchor: f32| {
            if ruled {
                top + (((anchor - top) / self.p.line_spacing) - 0.00001)
                    .ceil()
                    .max(1.)
                    * self.p.line_spacing
            } else {
                anchor
            }
        };
        let mut anchor = self.y.max(top - min_y as f32);
        if self.dirty {
            anchor = anchor.max(self.previous_bottom + gap - min_y as f32);
        }
        anchor = align(anchor);
        if anchor + max_y as f32 > bottom && self.dirty {
            self.emit_page(false)?;
            if self.stopped {
                return Ok(());
            }
            anchor = align(self.y.max(top - min_y as f32));
        }
        if anchor + max_y as f32 > bottom {
            if ruled {
                // 2026-10-17：仅空页也装不下的极高公式缩至实际横线，不把基线移到页底。
                let mut best = (0f32, top + self.p.line_spacing);
                let mut row = 1usize;
                loop {
                    let baseline = top + row as f32 * self.p.line_spacing;
                    if baseline >= bottom {
                        break;
                    }
                    let above = if min_y < 0 {
                        ((baseline - top - 1.) / -(min_y as f32)).max(0.)
                    } else {
                        1.
                    };
                    let below = if max_y > 0 {
                        ((bottom - baseline - 1.) / max_y as f32).max(0.)
                    } else {
                        1.
                    };
                    let factor = above.min(below).min(1.);
                    if factor > best.0 {
                        best = (factor, baseline);
                    }
                    row += 1;
                }
                anchor = best.1;
                for u in &mut units {
                    let offset = u.glyph.top + u.dy;
                    u.glyph = u.glyph.clone().fit(
                        u.glyph.mask.width() as f32 * best.0,
                        (u.glyph.mask.height() as f32 * best.0).max(1.),
                    );
                    u.dy = (offset as f32 * best.0).round() as i32 - u.glyph.top;
                }
                (_, max_y) = bounds(&units);
            } else {
                anchor = bottom - max_y as f32;
            }
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
                    &mut self.rng,
                    self.cancel,
                )?;
            } else {
                paste_mask(&mut self.mask, &u.glyph.mask, origin.0, origin.1);
            }
        }
        self.written_lines += 1;
        self.previous_bottom = anchor + max_y as f32;
        self.y = anchor + self.p.line_spacing;
        self.x = self.p.left_margin;
        self.dirty = true;
        Ok(())
    }
    // 2026-10-24：将末尾短语整体移至续行，已渲染的结构化公式保持原子性。
    fn homework_wrap(&mut self, continuation: f32, right: f32) -> Result<()> {
        let cutoff = self.p.left_margin + (right - self.p.left_margin) * 0.4;
        let split = self
            .line
            .iter()
            .enumerate()
            .rev()
            .find(|(i, u)| u.break_after && *i + 1 < self.line.len() && u.x as f32 >= cutoff)
            .map(|(i, _)| i + 1);
        let mut tail = split.map(|at| self.line.split_off(at)).unwrap_or_default();
        let old_cursor = self.x;
        self.finish_line()?;
        if let Some(first) = tail.first() {
            let shift = continuation - first.x as f32;
            for unit in &mut tail {
                unit.x += shift.round() as i32;
            }
            self.x = old_cursor + shift;
            self.line = tail;
        } else {
            self.x = continuation;
        }
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
    render_output(r, cancel, stop_after, None, emit)
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
    render_output(r, cancel, stop_after, Some((projection, photo)), emit)
}
fn render_output<F: FnMut(usize, RgbaImage) -> Result<()>>(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    photo: Option<(&crate::photo::PaperProjection, &RgbaImage)>,
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
    render_planes(r, cancel, stop_after, photo.is_some(), |i, paper, ink| {
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
            Some((projection, background)) => projection.composite(background, &image, cancel)?,
            None => image,
        };
        emit(i, output)
    })
}

fn fit_standard_ruled_row(
    units: &mut [LineUnit],
    min_y: i32,
    max_y: i32,
    height: i32,
    descent: i32,
) {
    let ink_height = max_y - min_y;
    let top = descent - height;
    if height <= 0
        || ink_height <= 0
        || ink_height as f32 > height as f32 * 1.2
        || (min_y >= top && max_y <= descent)
    {
        return;
    }
    // 2026-11-17：轻微越界先在同一行格内纵向适配，保留横向字距和高公式的跨行避让。
    let fit_height = height.min(ink_height);
    let start = min_y.clamp(top, descent - fit_height);
    for unit in units.iter_mut().filter(|unit| unit.glyph.ink) {
        let offset = unit.glyph.top + unit.dy - min_y;
        let end = offset + unit.glyph.mask.height() as i32;
        let first = offset * fit_height / ink_height;
        let last = (end * fit_height + ink_height - 1) / ink_height;
        let new_height = (last - first) as u32;
        if new_height != unit.glyph.mask.height() {
            let mut mask = GrayImage::new(unit.glyph.mask.width(), new_height);
            // 2026-11-17：合并缩小后落在同一行的像素，保留分数线等细笔画。
            for (x, y, pixel) in unit.glyph.mask.enumerate_pixels() {
                let row = (y * new_height) / unit.glyph.mask.height();
                mask[(x, row)][0] = mask[(x, row)][0].max(pixel[0]);
            }
            unit.glyph.mask = mask;
        }
        unit.dy = start + first - unit.glyph.top;
    }
}

pub(crate) fn render_pages(
    r: &RenderRequest,
    cancel: &Cancellation,
    stop_after: usize,
    emit: impl FnMut(usize, RgbaImage, Option<PageInk>) -> Result<()>,
) -> Result<usize> {
    render_planes(r, cancel, stop_after, false, emit)
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
        (None, None) => imaging::decode(
            r.background
                .as_deref()
                .ok_or_else(|| Error::new("missing_background", "缺少背景图"))?,
            &r.limits,
        )?
        .to_rgba8(),
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
    let mut i = 0;
    let mut node_index = 0;
    let mut paragraph_start = true;
    let mut section_line_start = 0;
    let mut continuation = p.left_margin;
    while i < units.len() && !pages.stopped {
        cancel.check()?;
        if homework_mode && paragraph_start && !matches!(units[i][0], Node::Newline | Node::Break) {
            let style = homework::paragraph(&units[i..], p.font_size);
            let available = right - p.left_margin;
            let indent = if p.first_line_indent
                && !matches!(
                    units[i][0],
                    Node::RightAlign | Node::Char(' ' | '\t' | '\u{3000}')
                ) {
                (2. * p.font_size).min(available - p.font_size)
            } else {
                style.indent.min(available * 0.15)
            };
            let prefix: Vec<_> = units[i..]
                .iter()
                .flat_map(|u| u.iter())
                .take(style.prefix_chars)
                .cloned()
                .collect();
            let hanging = if prefix.is_empty() {
                0.
            } else {
                glyphs.unit(&prefix, p.font_size)?.advance + p.word_spacing
            };
            continuation = p.left_margin + indent + hanging.min(available * 0.25);
            pages.x = p.left_margin + indent;
            if style.gap_before
                && (style.title || pages.written_lines - section_line_start >= 3)
                && pages.dirty
                && i >= 2
                && !matches!(units[i - 2][0], Node::Newline | Node::Break)
            {
                pages.y += p.line_spacing;
            }
            if style.gap_before {
                section_line_start = pages.written_lines;
            }
            paragraph_start = false;
        } else if !homework_mode
            && paragraph_start
            && !matches!(units[i][0], Node::Newline | Node::Break)
        {
            if p.first_line_indent
                && !matches!(
                    units[i][0],
                    Node::RightAlign | Node::Char(' ' | '\t' | '\u{3000}')
                )
            {
                pages.x = (p.left_margin + 2. * p.font_size).min(right - p.font_size);
            }
            paragraph_start = false;
        }
        match &units[i][0] {
            Node::Break => {
                pages.flush(false)?;
                paragraph_start = true;
            }
            Node::Newline => {
                pages.newline()?;
                paragraph_start = true;
            }
            Node::RightAlign => {
                let rest = units[i + 1..]
                    .iter()
                    .take_while(|unit| !matches!(unit[0], Node::Newline | Node::Break));
                let mut cursor = 0f32;
                let mut width = 0f32;
                for unit in rest {
                    let mut g = glyphs.unit(unit, p.font_size)?;
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
                let size =
                    (p.font_size + normal(&mut pages.rng, p.font_size_sigma)).clamp(1., 2048.);
                let mut fine_parts = None;
                let mut g = if p.fine_edit
                    && units[i].len() > 1
                    && units[i].iter().all(|node| matches!(node, Node::Char(_)))
                {
                    let (advance, children) = glyphs.sequence_parts(units[i], size, 0)?;
                    let composed = Glyphs::compose(advance, children.clone(), vec![])?;
                    fine_parts = Some(fine::Parts::new(
                        &composed,
                        children,
                        node_index,
                        source.as_deref(),
                    ));
                    composed
                } else {
                    glyphs.unit(units[i], size)?
                };
                let mut compound = units[i].len() > 1
                    || !matches!(node, Node::Char(_))
                    || matches!(node,Node::Char(c) if glyph::is_circled(*c));
                if !p.monospaced
                    && pages.rng.random::<f32>() < p.strikethrough_probability
                    && !matches!(node,Node::Char(c) if c.is_whitespace())
                {
                    let candidates: Vec<_> = r
                        .text
                        .chars()
                        .filter(|c| !c.is_whitespace() && !"，。！？,.!?".contains(*c))
                        .take(1024)
                        .collect();
                    if !candidates.is_empty() {
                        let wrong = glyphs.glyph(
                            candidates[pages.rng.random_range(0..candidates.len())],
                            size,
                        )?;
                        let length = (p.font_size * 2f32.sqrt()
                            + normal(&mut pages.rng, p.strikethrough_length_sigma))
                        .clamp(0., (w as f32 + h as f32).min(16384.));
                        let angle = (45. + normal(&mut pages.rng, p.strikethrough_angle_sigma))
                            .to_radians();
                        let width = (p.strikethrough_width
                            + normal(&mut pages.rng, p.strikethrough_width_sigma))
                        .clamp(1., (w.min(h) as f32).clamp(1., 256.))
                            as i32;
                        let sy = wrong.top as f32 + length / 7.;
                        let path = vec![
                            ((length / 7.).round() as i32, sy.round() as i32),
                            (
                                (length / 7. + length * angle.cos() * 5. / 7.).round() as i32,
                                (sy + length * angle.sin() * 5. / 7.).round() as i32,
                            ),
                        ];
                        // 2026-10-15：正确字写在错字和完整删除线之后，不能让较长删除线划到正确内容。
                        let stroke_right =
                            path.iter().map(|p| p.0).max().unwrap_or(0) + width / 2 + 2;
                        let shift = (wrong.advance + p.word_spacing)
                            .max(wrong.right() as f32)
                            .max(stroke_right as f32)
                            .round() as i32;
                        g = Glyphs::compose(
                            g.advance + shift as f32,
                            vec![(wrong, 0, 0), (g, shift, 0)],
                            vec![(path, width)],
                        )?;
                        compound = true;
                        fine_parts = None;
                    }
                }
                if homework_mode
                    && homework::break_before(units[i])
                    && let Some(previous) = pages.line.last_mut()
                {
                    previous.break_after = true;
                }
                let usable_width = right
                    - if homework_mode {
                        continuation
                    } else {
                        p.left_margin
                    };
                let usable_height = h as f32 - p.top_margin - p.bottom_margin;
                let cell = fixed_cell(units[i], p);
                g = g.fit(usable_width, usable_height);
                if let Some(cell) = cell {
                    g = g.place_in_cell(cell);
                }
                let jitter_x = if cell.is_none() && p.grid_layout && keeps_grid_cell(units[i]) {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                } else {
                    0.
                };
                let mut x = (pages.x + jitter_x)
                    .round()
                    .max(p.left_margin - g.left as f32);
                let footprint = cell.unwrap_or_else(|| g.right() as f32);
                if !pages.line.is_empty() && x + footprint > right {
                    if homework_mode {
                        pages.homework_wrap(continuation, right)?;
                        if !pages.line.is_empty() && pages.x + g.right() as f32 > right {
                            pages.finish_line()?;
                            pages.x = continuation;
                        }
                    } else {
                        pages.newline()?;
                    }
                    if pages.stopped {
                        break;
                    }
                    x = (pages.x + jitter_x)
                        .round()
                        .max(p.left_margin - g.left as f32);
                }
                x = x
                    .min(right - g.right() as f32)
                    .max(p.left_margin - g.left as f32);
                let dy = normal(&mut pages.rng, p.line_spacing_sigma)
                    .round()
                    .clamp(-usable_height * 0.25, usable_height * 0.25)
                    as i32;
                let extra = if p.grid_layout && keeps_grid_cell(units[i]) {
                    0.
                } else {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                };
                let advance = g.step(units[i], p, extra, compound);
                pages.x = x + advance;
                pages.line.push(LineUnit {
                    glyph: g,
                    rigid: compound || cell.is_some(),
                    x: x.round() as i32,
                    dy,
                    break_after: homework_mode && homework::break_after(units[i]),
                    id: node_index as u32,
                    source: source.as_ref().map(|positions| {
                        [
                            positions[node_index],
                            positions[node_index + units[i].len()],
                        ]
                    }),
                    fine_parts,
                });
            }
        }
        node_index += units[i].len();
        i += 1;
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
            glyph: Glyph {
                mask: GrayImage::from_pixel(8, 40, Luma([255])),
                advance: 8.,
                left: 0,
                top: -30,
                ink: true,
            },
            rigid: false,
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
