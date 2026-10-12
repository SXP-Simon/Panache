use crate::{
    Error, Limits, Parameters, Result, imaging,
    text::{self, Node},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use fontdue::{Font, FontSettings};
use image::{GrayImage, Luma, Rgba, RgbaImage};
use rand::{RngExt, SeedableRng};
use rand_chacha::ChaCha8Rng;
use rand_distr::{Distribution, StandardNormal};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
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
fn normal(rng: &mut ChaCha8Rng, sigma: f32) -> f32 {
    if sigma == 0. {
        0.
    } else {
        let n: f32 = StandardNormal.sample(rng);
        n * sigma
    }
}
#[derive(Clone)]
struct Glyph {
    mask: GrayImage,
    advance: f32,
}
struct Glyphs<'a> {
    book: &'a FontBook,
    cache: HashMap<(char, u32), Glyph>,
    cache_bytes: usize,
    max_width: u32,
    max_height: u32,
}
impl Glyphs<'_> {
    fn glyph(&mut self, c: char, size: f32) -> Result<Glyph> {
        let size = size.clamp(1., 2048.).round();
        let key = (c, size as u32);
        if let Some(g) = self.cache.get(&key) {
            return Ok(g.clone());
        }
        let font = self.book.for_char(c);
        let metrics = font.metrics(c, size);
        if metrics.width > self.max_width as usize || metrics.height > self.max_height as usize {
            return Err(Error::new("invalid_layout", "字形尺寸超过页面"));
        }
        let (m, data) = font.rasterize(c, size);
        let ascent = font
            .horizontal_line_metrics(size)
            .map(|l| l.ascent)
            .unwrap_or(size);
        let top = (ascent - m.height as f32 - m.ymin as f32).round().max(0.) as u32;
        let w = (m.width as i32 + m.xmin.max(0))
            .max(m.advance_width.ceil() as i32)
            .max(1) as u32;
        let h = (top + m.height as u32).max(size as u32);
        self.check_size(w, h)?;
        let mut mask = GrayImage::new(w, h);
        for y in 0..m.height {
            for x in 0..m.width {
                let xx = x as i32 + m.xmin;
                if xx >= 0 && xx < w as i32 {
                    mask[(xx as u32, y as u32 + top)] = Luma([data[y * m.width + x]]);
                }
            }
        }
        let glyph = Glyph {
            mask,
            advance: if c == ' ' {
                m.advance_width
            } else {
                (m.width as f32).max(m.advance_width)
            },
        };
        // 有界缓存，防止长文档和随机字号不断增长。
        if self.cache.len() >= 1024 || self.cache_bytes + glyph.mask.len() > 8 * 1024 * 1024 {
            self.cache.clear();
            self.cache_bytes = 0;
        }
        self.cache_bytes += glyph.mask.len();
        self.cache.insert(key, glyph.clone());
        Ok(glyph)
    }
    fn check_size(&self, w: u32, h: u32) -> Result<()> {
        if w > self.max_width || h > self.max_height {
            Err(Error::new("invalid_layout", "公式或字形尺寸超过页面"))
        } else {
            Ok(())
        }
    }
    fn sequence(&mut self, nodes: &[Node], size: f32) -> Result<Glyph> {
        let mut glyphs = Vec::new();
        let mut width = 0.;
        for node in nodes {
            let g = self.node(node, size)?;
            width += g.advance;
            self.check_size(width.ceil() as u32, g.mask.height())?;
            glyphs.push(g);
        }
        let w = glyphs.iter().map(|g| g.advance).sum::<f32>().ceil().max(1.) as u32;
        let h = glyphs
            .iter()
            .map(|g| g.mask.height())
            .max()
            .unwrap_or(size as u32)
            .max(1);
        self.check_size(w, h)?;
        let mut mask = GrayImage::new(w, h);
        let mut x = 0f32;
        for g in glyphs {
            paste_mask(&mut mask, &g.mask, x.round() as i32, 0);
            x += g.advance;
        }
        Ok(Glyph {
            mask,
            advance: w as f32,
        })
    }
    fn node(&mut self, n: &Node, size: f32) -> Result<Glyph> {
        match n {
            Node::Char(c) => self.glyph(*c, size),
            Node::Fraction(num, den) => {
                let a = self.sequence(num, size * 0.55)?;
                let b = self.sequence(den, size * 0.55)?;
                let w = a.mask.width().max(b.mask.width()) + 4;
                let gap = (size * 0.07).max(2.) as u32;
                let h = a.mask.height() + b.mask.height() + gap * 2 + 1;
                self.check_size(w, h)?;
                let mut mask = GrayImage::new(w, h);
                paste_mask(&mut mask, &a.mask, ((w - a.mask.width()) / 2) as i32, 0);
                paste_mask(
                    &mut mask,
                    &b.mask,
                    ((w - b.mask.width()) / 2) as i32,
                    (a.mask.height() + gap * 2 + 1) as i32,
                );
                for x in 0..w {
                    mask[(x, a.mask.height() + gap)] = Luma([255]);
                }
                Ok(Glyph {
                    mask,
                    advance: w as f32,
                })
            }
            Node::Radical(body, index) => {
                let a = self.sequence(body, size * 0.85)?;
                let idx = self.sequence(index, size * 0.35)?;
                let hook = (size * 0.45).max(5.) as u32;
                let bar = (size * 0.08).max(2.) as u32;
                let w = hook + a.mask.width() + 3;
                let h = a.mask.height() + bar + 2;
                self.check_size(w, h)?;
                let mut mask = GrayImage::new(w, h);
                paste_mask(&mut mask, &a.mask, hook as i32, (bar + 2) as i32);
                if !index.is_empty() {
                    paste_mask(&mut mask, &idx.mask, 0, 0);
                }
                imageproc::drawing::draw_line_segment_mut(
                    &mut mask,
                    (0., h as f32 * 0.55),
                    (hook as f32 * 0.3, h as f32 * 0.85),
                    Luma([255]),
                );
                imageproc::drawing::draw_line_segment_mut(
                    &mut mask,
                    (hook as f32 * 0.3, h as f32 * 0.85),
                    (hook as f32 * 0.7, bar as f32),
                    Luma([255]),
                );
                imageproc::drawing::draw_line_segment_mut(
                    &mut mask,
                    (hook as f32 * 0.7, bar as f32),
                    ((w - 1) as f32, bar as f32),
                    Luma([255]),
                );
                Ok(Glyph {
                    mask,
                    advance: w as f32,
                })
            }
            _ => Ok(Glyph {
                mask: GrayImage::new(1, 1),
                advance: 0.,
            }),
        }
    }
}
fn paste_mask(dest: &mut GrayImage, src: &GrayImage, x: i32, y: i32) {
    for (xx, yy, p) in src.enumerate_pixels() {
        let dx = x + xx as i32;
        let dy = y + yy as i32;
        if dx >= 0 && dy >= 0 && dx < dest.width() as i32 && dy < dest.height() as i32 {
            dest[(dx as u32, dy as u32)][0] = dest[(dx as u32, dy as u32)][0].max(p[0]);
        }
    }
}
// 2026-10-12：四邻域连通区域整体扰动；旋转方向沿用 handright，算法许可见 NOTICE。
fn perturb(
    mask: &mut GrayImage,
    canvas: &mut RgbaImage,
    p: &Parameters,
    rng: &mut ChaCha8Rng,
    cancel: &Cancellation,
) -> Result<()> {
    let (w, h) = mask.dimensions();
    let mut stack = Vec::new();
    let mut component = Vec::new();
    for y in 0..h {
        if y % 32 == 0 {
            cancel.check()?;
        }
        for x in 0..w {
            if mask[(x, y)][0] < 128 {
                continue;
            }
            stack.push((x, y));
            mask[(x, y)] = Luma([0]);
            let (mut minx, mut maxx, mut miny, mut maxy) = (x, x, y, y);
            while let Some((xx, yy)) = stack.pop() {
                component.push((xx, yy));
                minx = minx.min(xx);
                maxx = maxx.max(xx);
                miny = miny.min(yy);
                maxy = maxy.max(yy);
                if component.len() % 8192 == 0 {
                    cancel.check()?;
                }
                for (nx, ny) in [
                    (xx as i32 - 1, yy as i32),
                    (xx as i32 + 1, yy as i32),
                    (xx as i32, yy as i32 - 1),
                    (xx as i32, yy as i32 + 1),
                ] {
                    if nx >= 0
                        && ny >= 0
                        && nx < w as i32
                        && ny < h as i32
                        && mask[(nx as u32, ny as u32)][0] >= 128
                    {
                        mask[(nx as u32, ny as u32)] = Luma([0]);
                        stack.push((nx as u32, ny as u32));
                    }
                }
            }
            let cx = (minx + maxx) as f32 / 2.;
            let cy = (miny + maxy) as f32 / 2.;
            let dx = normal(rng, p.perturb_x_sigma);
            let dy = normal(rng, p.perturb_y_sigma);
            let angle = normal(rng, p.perturb_theta_sigma);
            let ink = normal(rng, p.ink_depth_sigma);
            let fill = Rgba([
                (p.fill[0] as f32 + ink).clamp(0., 255.) as u8,
                (p.fill[1] as f32 + ink).clamp(0., 255.) as u8,
                (p.fill[2] as f32 + ink).clamp(0., 255.) as u8,
                p.fill[3],
            ]);
            for (xx, yy) in component.drain(..) {
                let rx = xx as f32 - cx;
                let ry = yy as f32 - cy;
                let nx = (rx * angle.cos() + ry * angle.sin() + cx + dx).round() as i32;
                let ny = (ry * angle.cos() - rx * angle.sin() + cy + dy).round() as i32;
                if nx >= 0 && ny >= 0 && nx < w as i32 && ny < h as i32 {
                    use image::Pixel;
                    canvas[(nx as u32, ny as u32)].blend(&fill);
                }
            }
        }
    }
    Ok(())
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
    dirty: bool,
    count: usize,
    max_pages: usize,
    emit: F,
    stopped: bool,
}
impl<F: FnMut(usize, RgbaImage) -> Result<()>> Pages<'_, F> {
    fn flush(&mut self, force: bool) -> Result<()> {
        if !self.dirty && !force {
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
        self.y = self.p.top_margin + self.p.line_spacing - self.p.font_size;
        self.dirty = false;
        Ok(())
    }
    fn newline(&mut self) -> Result<()> {
        self.x = self.p.left_margin;
        self.y += self.p.line_spacing;
        if self.y > self.canvas.height() as f32 - self.p.bottom_margin - self.p.font_size {
            self.flush(true)?;
        }
        Ok(())
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
            let mut bg = RgbaImage::from_pixel(w, h, Rgba([255, 255, 255, 255]));
            if p.underlined {
                let mut y = p.top_margin + p.line_spacing;
                while y < h as f32 - p.bottom_margin {
                    imageproc::drawing::draw_line_segment_mut(
                        &mut bg,
                        (p.left_margin, y),
                        (w as f32 - p.right_margin, y),
                        Rgba([0, 0, 0, 255]),
                    );
                    y += p.line_spacing;
                }
            }
            bg
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
    let mut glyphs = Glyphs {
        book: &r.fonts,
        cache: HashMap::new(),
        cache_bytes: 0,
        max_width: w,
        max_height: h,
    };
    let mut pages = Pages {
        canvas: background.clone(),
        background,
        mask: GrayImage::new(w, h),
        p,
        rng: ChaCha8Rng::seed_from_u64(p.seed),
        cancel,
        x: p.left_margin,
        y: p.top_margin + p.line_spacing - p.font_size,
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
                let mut prefix = 0f32;
                let mut max_prefix = 0f32;
                for n in rest {
                    max_prefix = max_prefix.max(prefix);
                    prefix += glyphs.node(&n, p.font_size)?.advance + p.word_spacing;
                }
                let unit = glyphs.glyph('　', p.font_size)?.advance + p.word_spacing;
                if unit > 0. {
                    pages.x +=
                        (((right - p.font_size - p.left_margin - max_prefix) / unit).floor() - 1.)
                            .max(0.)
                            * unit;
                }
            }
            Node::Image { alt, data } => {
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
                    pages.y + p.font_size + p.line_spacing
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
                pages.y = top + image.height() as f32 + p.line_spacing * 2. - p.font_size;
            }
            node => {
                let closing = matches!(node,Node::Char(c) if "，。》？；：’”】｝、！％）,.>?;:]}!%)′″℃℉".contains(*c));
                if pages.x > right - p.font_size && !closing {
                    pages.newline()?;
                    if pages.stopped {
                        break;
                    }
                }
                if pages.y > h as f32 - p.bottom_margin - p.font_size {
                    pages.flush(false)?;
                    if pages.stopped {
                        break;
                    }
                }
                let size =
                    (p.font_size + normal(&mut pages.rng, p.font_size_sigma)).clamp(1., 2048.);
                let g = glyphs.node(node, size)?;
                if g.mask.width() as f32 > right - p.left_margin {
                    return Err(Error::new("invalid_layout", "公式或字形宽度超过版心"));
                }
                let yy = pages.y + normal(&mut pages.rng, p.line_spacing_sigma);
                let grid_jitter = if p.grid_layout {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                } else {
                    0.
                };
                let xx = pages.x + grid_jitter;
                if pages.rng.random::<f32>() < p.strikethrough_probability
                    && !matches!(node,Node::Char(c) if c.is_whitespace())
                {
                    let candidates: Vec<char> = r
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
                        paste_mask(
                            &mut pages.mask,
                            &wrong.mask,
                            xx.round() as i32,
                            yy.round() as i32,
                        );
                        let length = (p.font_size * 2f32.sqrt()
                            + normal(&mut pages.rng, p.strikethrough_length_sigma))
                        .max(0.);
                        let angle = (45. + normal(&mut pages.rng, p.strikethrough_angle_sigma))
                            .to_radians();
                        let width = (p.strikethrough_width
                            + normal(&mut pages.rng, p.strikethrough_width_sigma))
                        .clamp(1., 256.) as u32;
                        for offset in 0..width {
                            let sy = yy + length / 7. + offset as f32;
                            imageproc::drawing::draw_line_segment_mut(
                                &mut pages.mask,
                                (xx + length / 7., sy),
                                (
                                    xx + length / 7. + length * angle.cos() * 5. / 7.,
                                    sy + length * angle.sin() * 5. / 7.,
                                ),
                                Luma([255]),
                            );
                        }
                        pages.x += wrong.advance + p.word_spacing;
                    }
                }
                paste_mask(
                    &mut pages.mask,
                    &g.mask,
                    (pages.x + grid_jitter).round() as i32,
                    yy.round() as i32,
                );
                pages.x += if p.grid_layout {
                    p.font_size + p.word_spacing
                } else {
                    g.advance + p.word_spacing + normal(&mut pages.rng, p.word_spacing_sigma)
                };
                pages.dirty = true;
            }
        }
        i += 1;
    }
    if !pages.stopped {
        pages.flush(pages.count == 0)?;
    }
    Ok(pages.count)
}
