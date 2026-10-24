use crate::{
    Error, Limits, Parameters, Result, imaging,
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
mod glyph;
mod ink;
mod units;
use glyph::{Glyph, Glyphs};
use ink::{blank_paper, normal, paint_math_unit, paste_mask, perturb};
use units::{keeps_grid_cell, layout_units};
// 2026-10-15：先缓存整行，知道最高根式/最低分母后再统一落笔，避免后出现的公式撞进上一行。
struct LineUnit {
    glyph: Glyph,
    rigid: bool,
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
        // 2026-10-17：公式可占多格，后续基线仍须落在原纸张横线上。
        let ruled = (self.p.underlined && self.p.width.is_some()) || self.p.background_ruled;
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
            if u.rigid {
                paint_math_unit(
                    &mut self.canvas,
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
    crate::validate_document(&r.text, &r.limits)?;
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
    let units = layout_units(&nodes);
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
    while i < units.len() && !pages.stopped {
        cancel.check()?;
        match &units[i][0] {
            Node::Break => pages.flush(false)?,
            Node::Newline => pages.newline()?,
            Node::RightAlign => {
                let rest = units[i + 1..]
                    .iter()
                    .take_while(|unit| !matches!(unit[0], Node::Newline | Node::Break));
                let mut cursor = 0f32;
                let mut width = 0f32;
                for unit in rest {
                    let g = glyphs.unit(unit, p.font_size)?;
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
                image::imageops::overlay(&mut pages.canvas, &image, x as i64, top as i64);
                pages.dirty = true;
                pages.x = p.left_margin;
                pages.previous_bottom = top + image.height() as f32;
                pages.y = pages.previous_bottom + p.line_spacing;
            }
            node => {
                let size =
                    (p.font_size + normal(&mut pages.rng, p.font_size_sigma)).clamp(1., 2048.);
                let mut g = glyphs.unit(units[i], size)?;
                let mut compound = units[i].len() > 1 || !matches!(node, Node::Char(_));
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
                let jitter_x = if p.grid_layout && keeps_grid_cell(units[i]) {
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
                let extra = if p.grid_layout && keeps_grid_cell(units[i]) {
                    0.
                } else {
                    normal(&mut pages.rng, p.word_spacing_sigma)
                };
                let advance = g.step(units[i], p, extra, compound);
                pages.x = x + advance;
                pages.line.push(LineUnit {
                    glyph: g,
                    rigid: compound,
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
                mask: GrayImage::new(180, 193),
                p: &p,
                rng: ChaCha8Rng::seed_from_u64(42),
                cancel: &cancel,
                x: 10.,
                y: 10. + spacing,
                previous_bottom: 10.,
                line: vec![],
                dirty: false,
                count: 0,
                max_pages: 100,
                emit: |_, _| Ok(()),
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
                let baseline = pages.previous_bottom - 10.;
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
