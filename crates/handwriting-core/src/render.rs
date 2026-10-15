use crate::{
    Error, Limits, Parameters, Result, imaging,
    text::{self, Node},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use fontdue::{Font, FontSettings};
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
#[derive(Clone)]
pub struct FontBook {
    fonts: Vec<Arc<Font>>,
}
impl FontBook {
    pub fn new(primary: &[u8], fallbacks: &[Vec<u8>]) -> Result<Self> {
        let mut fonts = vec![Self::load(primary)?];
        for bytes in fallbacks {
            fonts.push(Self::load(bytes)?);
        }
        Ok(Self { fonts })
    }
    pub fn load(bytes: &[u8]) -> Result<Arc<Font>> {
        ttf_parser::Face::parse(bytes, 0).map_err(|e| Error::new("invalid_font", e.to_string()))?;
        Font::from_bytes(bytes, FontSettings::default())
            .map(Arc::new)
            .map_err(|e| Error::new("invalid_font", e))
    }
    pub fn from_fonts(primary: Arc<Font>, fallbacks: Vec<Arc<Font>>) -> Self {
        let mut fonts = vec![primary];
        fonts.extend(fallbacks);
        Self { fonts }
    }
    fn for_char(&self, c: char) -> &Font {
        self.fonts
            .iter()
            .find(|f| f.lookup_glyph_index(c) != 0)
            .unwrap_or(&self.fonts[0])
    }
}
pub struct RenderRequest {
    pub text: String,
    pub params: Parameters,
    pub background: Option<Vec<u8>>,
    pub fonts: FontBook,
    pub limits: Limits,
}
mod glyph;
mod ink;
use glyph::{Glyph, Glyphs};
use ink::{blank_paper, normal, paste_mask, perturb};
// 2026-10-15：先缓存整行，知道最高根式/最低分母后再统一落笔，避免后出现的公式撞进上一行。
struct LineUnit {
    glyph: Glyph,
    x: i32,
    dy: i32,
}
struct Pages<'a, F>
where
    F: FnMut(usize, RgbaImage) -> Result<()>,
{
    background: RgbaImage,
    canvas: RgbaImage,
    mask: GrayImage,
    p: &'a Parameters,
    rng: ChaCha8Rng,
    cancel: &'a Cancellation,
    x: f32,
    y: f32,
    previous_bottom: f32,
    line: Vec<LineUnit>,
    dirty: bool,
    count: usize,
    max_pages: usize,
    emit: F,
    stopped: bool,
}
impl<F: FnMut(usize, RgbaImage) -> Result<()>> Pages<'_, F> {
    fn emit_page(&mut self, force: bool) -> Result<()> {
        if (!self.dirty && !force) || self.stopped {
            return Ok(());
        }
        self.cancel.check()?;
        if self.count >= self.max_pages {
            return Err(Error::new("page_limit", "页数超出限制"));
        }
        perturb(
            &mut self.mask,
            &mut self.canvas,
            self.p,
            &mut self.rng,
            self.cancel,
        )?;
        let canvas = std::mem::replace(&mut self.canvas, self.background.clone());
        (self.emit)(self.count, canvas)?;
        self.count += 1;
        self.stopped = self.p.preview && !self.p.full_preview && !self.p.pdf_save;
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
        let gap = (self.p.font_size * 0.12).round().max(2.);
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
        let mut anchor = self.y.max(top - min_y as f32);
        if self.dirty {
            anchor = anchor.max(self.previous_bottom + gap - min_y as f32);
        }
        if anchor + max_y as f32 > bottom && self.dirty {
            self.emit_page(false)?;
            if self.stopped {
                return Ok(());
            }
            anchor = self.y.max(top - min_y as f32);
        }
        if anchor + max_y as f32 > bottom {
            anchor = bottom - max_y as f32;
        }
        for u in units {
            paste_mask(
                &mut self.mask,
                &u.glyph.mask,
                u.x + u.glyph.left,
                (anchor.round() as i32) + u.dy + u.glyph.top,
            );
        }
        self.previous_bottom = anchor + max_y as f32;
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
    cancel.check()?;
    if r.text.chars().count() > r.limits.max_text_chars {
        return Err(Error::new("text_limit", "文本过长"));
    }
    let p = &r.params;
    let background = match (p.width, p.height) {
        (Some(w), Some(h)) => {
            p.validate(w, h, &r.limits)?;
            blank_paper(w, h, p)
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
    let nodes = text::parse(&text::normalize(&r.text, p.english_spacing));
    let mut glyphs = Glyphs::new(&r.fonts);
    let mut pages = Pages {
        canvas: background.clone(),
        background,
        mask: GrayImage::new(w, h),
        p,
        rng: ChaCha8Rng::seed_from_u64(p.seed),
        cancel,
        x: p.left_margin,
        y: p.top_margin + p.line_spacing,
        previous_bottom: p.top_margin,
        line: Vec::new(),
        dirty: false,
        count: 0,
        max_pages: r.limits.max_pages,
        emit,
        stopped: false,
    };
    let right = w as f32 - p.effective_right_margin();
    let mut i = 0;
    while i < nodes.len() && !pages.stopped {
        cancel.check()?;
        match &nodes[i] {
            Node::Break => pages.flush(false)?,
            Node::Newline => pages.newline()?,
            Node::RightAlign => {
                let rest: Vec<_> = nodes[i + 1..]
                    .iter()
                    .take_while(|n| !matches!(n, Node::Newline | Node::Break))
                    .cloned()
                    .collect();
                let mut cursor = 0f32;
                let mut width = 0f32;
                for n in rest {
                    let g = glyphs.node(&n, p.font_size)?;
                    width = width.max(cursor + g.right() as f32);
                    cursor += if p.grid_layout {
                        let cell = (p.font_size + p.word_spacing).max(1.);
                        if matches!(n, Node::Char(_)) {
                            cell
                        } else {
                            (g.advance.max(g.right() as f32) / cell).ceil().max(1.) * cell
                        }
                    } else {
                        g.advance + p.word_spacing
                    };
                }
                pages.x = (right - width).max(p.left_margin);
            }
            Node::Image { alt, data } => {
                pages.finish_line()?;
                if pages.stopped {
                    break;
                }
                perturb(
                    &mut pages.mask,
                    &mut pages.canvas,
                    p,
                    &mut pages.rng,
                    cancel,
                )?;
                let raw = data.split_once(',').map(|(_, s)| s).unwrap_or(data);
                let compact: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
                if compact.len() > r.limits.max_file_bytes * 4 / 3 + 4 {
                    return Err(Error::new("upload_limit", "插图过大"));
                }
                let bytes = STANDARD
                    .decode(compact)
                    .map_err(|e| Error::new("invalid_image", e.to_string()))?;
                let decoded = imaging::decode(&bytes, &r.limits)?;
                let image = imaging::handdrawn(&decoded, p.seed.wrapping_add(i as u64), cancel)?;
                let image = imaging::fit(
                    &image,
                    (w as f32 - p.left_margin - p.right_margin).max(1.) as u32,
                    ((h as f32 - p.top_margin - p.bottom_margin) * 0.45).max(1.) as u32,
                    imaging::scale(alt),
                );
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
                image::imageops::overlay(&mut pages.canvas, &image, x as i64, top as i64);
                pages.dirty = true;
                pages.x = p.left_margin;
                pages.previous_bottom = top + image.height() as f32;
                pages.y = pages.previous_bottom + p.line_spacing;
            }
            node => {
                let size =
                    (p.font_size + normal(&mut pages.rng, p.font_size_sigma)).clamp(1., 2048.);
                let mut g = glyphs.node(node, size)?;
                let mut compound = !matches!(node, Node::Char(_));
                if pages.rng.random::<f32>() < p.strikethrough_probability
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
                    }
                }
                let usable_width = right - p.left_margin;
                let usable_height = h as f32 - p.top_margin - p.bottom_margin;
                g = g.fit(usable_width, usable_height);
                let jitter_x = if p.grid_layout {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                } else {
                    0.
                };
                let mut x = (pages.x + jitter_x)
                    .round()
                    .max(p.left_margin - g.left as f32);
                if !pages.line.is_empty() && x + g.right() as f32 > right {
                    pages.newline()?;
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
                let advance = if p.grid_layout {
                    let cell = (p.font_size + p.word_spacing).max(1.);
                    if compound {
                        (g.advance.max(g.right() as f32) / cell).ceil().max(1.) * cell
                    } else {
                        cell
                    }
                } else {
                    let step =
                        g.advance + p.word_spacing + normal(&mut pages.rng, p.word_spacing_sigma);
                    if matches!(node, Node::Char(_)) {
                        step.max(1.)
                    } else {
                        step.max(g.right() as f32).max(1.)
                    }
                };
                pages.x = x + advance;
                pages.line.push(LineUnit {
                    glyph: g,
                    x: x.round() as i32,
                    dy,
                });
            }
        }
        i += 1;
    }
    if !pages.stopped {
        pages.flush(pages.count == 0)?;
    }
    Ok(pages.count)
}
