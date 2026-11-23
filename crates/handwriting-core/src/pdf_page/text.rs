use super::visibility::Visibility;
use crate::{Error, Limits, Result};
use hayro::{
    hayro_interpret::{
        BlendMode, ClipPath, Context, Device, DrawMode, DrawProps, Image, ImageDrawProps,
        InterpreterCache, InterpreterSettings, Paint, SoftMask, TransformExt,
        font::{Glyph, GlyphRun},
        hayro_cmap::BfString,
        interpret,
    },
    hayro_syntax::{content::TypedIter, object::Dict, page::Page},
    kurbo::{Affine, BezPath, Rect, Shape},
};
use lopdf::{
    Object,
    content::{Content, Operation},
};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct TextLine {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

pub(super) struct Extraction {
    pub lines: Vec<TextLine>,
    pub background: Option<Vec<u8>>,
    pub unsupported: bool,
}

struct Candidate {
    index: usize,
    mode: i64,
    lines: Vec<TextLine>,
    supported: bool,
}

struct Collector<'a> {
    limits: &'a Limits,
    target: Rect,
    candidates: Vec<Candidate>,
    current: Option<usize>,
    marker_prefix: String,
    characters: usize,
    unsupported: bool,
    oversized_image: bool,
    clips: Vec<Option<Rect>>,
    groups: Vec<bool>,
    visibility: Visibility,
}

fn shows_text(operator: &[u8]) -> bool {
    matches!(operator, b"Tj" | b"TJ" | b"'" | b"\"")
}

pub(super) fn extract(
    page: &Page<'_>,
    scale: f32,
    settings: &InterpreterSettings,
    limits: &Limits,
) -> Result<Extraction> {
    let stream = page.page_stream().unwrap_or_default();
    if stream.len() as u64 > limits.max_archive_bytes {
        return Err(Error::new("archive_limit", "PDF 页面内容流过大"));
    }
    let (w, h) = page.render_dimensions();
    let target = Rect::new(
        0.0,
        0.0,
        (w * scale).floor() as f64,
        (h * scale).floor() as f64,
    );
    let cache = InterpreterCache::new();
    let mut context = Context::new(
        Affine::scale(f64::from(scale)) * page.initial_transform(true).to_kurbo(),
        target,
        &cache,
        page.xref(),
        settings.clone(),
    );
    let mut device = Collector {
        limits,
        target,
        candidates: Vec::new(),
        current: None,
        marker_prefix: format!("Panache{:032x}-", rand::random::<u128>()),
        characters: 0,
        unsupported: false,
        oversized_image: false,
        clips: Vec::new(),
        groups: Vec::new(),
        visibility: Visibility::new(target.height()),
    };
    // 2026-11-23：直接文字指令独立标记。嵌套表单、批注和不支持的字形仍由原 PDF 绘制。
    let content = checked_content(page, stream)?;
    if let Some(parsed) = content.as_ref() {
        let annotated = mark_candidates(parsed, &device.marker_prefix, &mut device.candidates)?;
        interpret(
            TypedIter::new(&annotated),
            page.resources(),
            &mut context,
            &mut device,
        );
    } else {
        interpret(
            page.typed_operations(),
            page.resources(),
            &mut context,
            &mut device,
        );
    }
    // 2026-11-23：批注外观和表单控件可能遮住正文。整页保留可避免暴露被覆盖的文字。
    if device.visibility.exhausted()
        || page
            .raw()
            .get::<hayro::hayro_syntax::object::Array<'_>>(b"Annots")
            .is_some_and(|a| a.raw_iter().next().is_some())
    {
        device.unsupported = true;
        device.candidates.clear();
    }
    if device.oversized_image {
        return Err(Error::new("pixel_limit", "PDF 内嵌图像超过像素限制"));
    }
    if device.characters > limits.max_text_chars {
        return Err(Error::new("text_limit", "PDF 页面文字过长"));
    }
    let mut lines = Vec::new();
    let background = if let Some(content) = content {
        rewrite_background(content, device.candidates, &mut lines)?
    } else {
        None
    };
    lines.retain(|line| !line.text.trim().is_empty());
    Ok(Extraction {
        lines,
        background,
        unsupported: device.unsupported,
    })
}

fn checked_content(page: &Page<'_>, stream: &[u8]) -> Result<Option<Content>> {
    let mut original = page.operations();
    let mut has_inline_image = false;
    let mut has_text = false;
    let mut operators = 0usize;
    while let Some(op) = original.next() {
        operators += 1;
        if operators > 200_000 {
            return Err(Error::new("archive_limit", "PDF 页面绘图指令过多"));
        }
        let name: &[u8] = op.operator;
        has_inline_image |= name == b"BI";
        has_text |= shows_text(name);
    }
    if !has_text || has_inline_image {
        return Ok(None);
    }
    let Ok(parsed) = Content::decode(stream) else {
        return Ok(None);
    };
    // 两种解析器必须读到相同的指令，才允许重写页面内容。
    let mut original = page.operations();
    let same_operators = parsed.operations.iter().all(|op| {
        original
            .next()
            .is_some_and(|raw| &**raw.operator == op.operator.as_bytes())
    }) && original.next().is_none();
    Ok(same_operators.then_some(parsed))
}

fn mark_candidates(
    parsed: &Content,
    prefix: &str,
    candidates: &mut Vec<Candidate>,
) -> Result<Vec<u8>> {
    let mut marked = Vec::with_capacity(parsed.operations.len());
    let mut mode = 0;
    let mut saved = Vec::new();
    for (index, op) in parsed.operations.iter().enumerate() {
        match op.operator.as_str() {
            "Tr" => {
                mode = op
                    .operands
                    .first()
                    .and_then(|o| o.as_i64().ok())
                    .unwrap_or(-1)
            }
            "q" => saved.push(mode),
            "Q" => mode = saved.pop().unwrap_or(0),
            _ => {}
        }
        if shows_text(op.operator.as_bytes()) && matches!(mode, 0 | 1) {
            let number = candidates.len();
            candidates.push(Candidate {
                index,
                mode,
                lines: Vec::new(),
                supported: true,
            });
            marked.push(Operation::new(
                "BMC",
                vec![Object::Name(format!("{prefix}{number}").into_bytes())],
            ));
            marked.push(op.clone());
            marked.push(Operation::new("EMC", vec![]));
        } else {
            marked.push(op.clone());
        }
    }
    encode_operations(marked)
}

fn rewrite_background(
    content: Content,
    candidates: Vec<Candidate>,
    lines: &mut Vec<TextLine>,
) -> Result<Option<Vec<u8>>> {
    let mut accepted = candidates
        .into_iter()
        .filter(|c| c.supported && !c.lines.is_empty())
        .peekable();
    if accepted.peek().is_none() {
        return Ok(None);
    }
    let mut output = Vec::new();
    for (index, op) in content.operations.into_iter().enumerate() {
        if let Some(item) = accepted.next_if(|candidate| candidate.index == index) {
            for line in item.lines {
                append(lines, line);
            }
            // 2026-11-23：让字形不可见但保留原字距、推进量和文字状态。
            output.push(Operation::new("Tr", vec![3.into()]));
            output.push(op);
            output.push(Operation::new("Tr", vec![item.mode.into()]));
        } else {
            output.push(op);
        }
    }
    encode_operations(output).map(Some)
}

fn encode_operations(operations: Vec<Operation>) -> Result<Vec<u8>> {
    Content { operations }
        .encode()
        .map_err(|e| Error::new("invalid_document", e.to_string()))
}

fn append(lines: &mut Vec<TextLine>, next: TextLine) {
    if let Some(prev) = lines.last_mut() {
        let gap = next.x - (prev.x + prev.width);
        if (next.y - prev.y).abs() < next.height * 0.12
            && (next.height - prev.height).abs() < next.height * 0.12
            && gap >= -next.height * 0.18
            && gap < next.height * 0.65
        {
            if gap > next.height * 0.14
                && !prev.text.ends_with(char::is_whitespace)
                && !next.text.starts_with(char::is_whitespace)
            {
                prev.text.push(' ');
            }
            prev.width = (next.x + next.width - prev.x).max(prev.width);
            prev.text.push_str(&next.text);
            return;
        }
    }
    lines.push(next);
}

impl Collector<'_> {
    fn solid(&self, props: &DrawProps<'_>) -> Option<[u8; 3]> {
        if props.soft_mask.is_some()
            || props.blend_mode != BlendMode::Normal
            || self.groups.last() == Some(&false)
        {
            return None;
        }
        if let Paint::Color(color) = &props.paint
            && let [r, g, b, 255] = color.to_rgba().to_rgba8()
        {
            Some([r, g, b])
        } else {
            None
        }
    }
    fn mark(&mut self, bounds: Rect, solid: Option<[u8; 3]>, text: Option<usize>) {
        let bounds = bounds.intersect(self.target);
        let clip = self.clips.last().copied().unwrap_or(Some(self.target));
        let solid = solid.filter(|_| clip.is_some_and(|r| r.contains_rect(bounds)));
        self.visibility.paint(bounds, solid, text, |id| {
            self.candidates[id].supported = false;
            self.unsupported = true;
        });
    }
}

impl Device<'_> for Collector<'_> {
    fn draw_glyph_run(&mut self, run: &GlyphRun<'_, '_>, props: DrawProps<'_>, mode: &DrawMode) {
        if matches!(mode, DrawMode::Invisible) {
            return;
        }
        let current = self.current.filter(|i| *i < self.candidates.len());
        let color = self.solid(&props);
        let clip = self.clips.last().copied().unwrap_or(Some(self.target));
        for glyph in run.glyphs() {
            let transform = props.transform * glyph.transform();
            let [a, b, c, d, x, baseline] = transform.as_coeffs();
            let height = -1000.0 * d;
            let (width, ink) = match &**glyph {
                Glyph::Outline(g) => (
                    f64::from(g.advance_width().unwrap_or(500.0)) * a,
                    transform.transform_rect_bbox(g.outline().bounding_box()),
                ),
                Glyph::Type3(_) => {
                    if let Some(id) = current {
                        self.candidates[id].supported = false;
                    }
                    self.unsupported = true;
                    self.mark(self.target, None, None);
                    continue;
                }
            };
            let text = match glyph.as_unicode() {
                Some(BfString::Char(c)) => c.to_string(),
                Some(BfString::String(s)) => s,
                None => String::new(),
            };
            self.characters = self.characters.saturating_add(text.chars().count());
            if self.characters > self.limits.max_text_chars {
                return;
            }
            let y = baseline - height * 0.8;
            let rect = Rect::new(x, y, x + width, y + height);
            if let Some(id) = current {
                let geometry = rect.is_finite()
                    && height > 0.0
                    && width > 0.0
                    && b.abs() <= a.abs() * 0.02
                    && c.abs() <= d.abs() * 0.02
                    && clip.is_some_and(|r| {
                        r.contains_rect(rect) && (ink.area() == 0.0 || r.contains_rect(ink))
                    });
                let valid_text =
                    !text.is_empty() && !text.contains(|c: char| c.is_control() || c == '\u{fffd}');
                let visible = color.is_some_and(|color| {
                    text.trim().is_empty()
                        || (ink.area() > 0.0 && self.visibility.visible(ink, color, id))
                });
                if geometry && valid_text && visible {
                    append(
                        &mut self.candidates[id].lines,
                        TextLine {
                            text,
                            x,
                            y,
                            width,
                            height,
                        },
                    );
                } else {
                    self.candidates[id].supported = false;
                    self.unsupported = true;
                }
            } else {
                self.unsupported = true;
            }
            self.mark(ink, None, current);
        }
    }
    fn begin_marked_content(&mut self, tag: &[u8], _: Option<&Dict<'_>>) {
        self.current = tag
            .strip_prefix(self.marker_prefix.as_bytes())
            .and_then(|s| str::from_utf8(s).ok())
            .and_then(|s| s.parse().ok());
    }
    fn end_marked_content(&mut self) {
        self.current = None;
    }
    fn draw_image(&mut self, image: Image<'_, '_>, props: ImageDrawProps<'_>) {
        self.oversized_image |=
            u64::from(image.width()) * u64::from(image.height()) > self.limits.max_pixels;
        let local = Rect::new(0.0, 0.0, image.width() as f64, image.height() as f64);
        self.mark(props.transform.transform_rect_bbox(local), None, None);
    }
    fn draw_path(&mut self, path: &BezPath, props: DrawProps<'_>, mode: &DrawMode) {
        let mut bounds = path.bounding_box();
        if let DrawMode::Stroke(stroke) | DrawMode::FillAndStroke(_, stroke) = mode {
            let pad = f64::from(stroke.line_width.max(1.0) * stroke.miter_limit.max(1.0)) * 0.5;
            bounds = bounds.inflate(pad, pad);
        }
        self.mark(props.transform.transform_rect_bbox(bounds), None, None);
    }
    fn draw_rect(&mut self, rect: &Rect, props: DrawProps<'_>, mode: &DrawMode) {
        let [a, b, c, d, _, _] = props.transform.as_coeffs();
        if matches!(mode, DrawMode::Fill(_)) && ((a == 0.0 && d == 0.0) || (b == 0.0 && c == 0.0)) {
            self.mark(
                props.transform.transform_rect_bbox(*rect),
                self.solid(&props),
                None,
            );
        } else {
            self.draw_path(&rect.to_path(0.1), props, mode);
        }
    }
    fn push_clip_path(&mut self, _: &ClipPath) {
        self.clips.push(None);
    }
    fn push_clip_rect(&mut self, rect: &Rect) {
        self.clips.push(
            self.clips
                .last()
                .copied()
                .unwrap_or(Some(self.target))
                .map(|r| r.intersect(*rect)),
        );
    }
    fn pop_clip(&mut self) {
        self.clips.pop();
    }
    fn push_transparency_group(
        &mut self,
        opacity: f32,
        mask: Option<SoftMask<'_>>,
        blend: BlendMode,
    ) {
        self.groups.push(
            self.groups.last() != Some(&false)
                && opacity == 1.0
                && mask.is_none()
                && blend == BlendMode::Normal,
        );
    }
    fn pop_transparency_group(&mut self) {
        self.groups.pop();
    }
}
