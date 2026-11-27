mod adjustments;
pub(crate) mod font_samples;
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, FontBook, Limits, RenderRequest, export};
use std::{collections::HashMap, fs, io::Write, path::PathBuf, sync::Arc};

use crate::{
    Format,
    drafts::{Section, Snapshot},
};

use handwriting_core::fine_edit::{self, Adjustment, Adjustments};
use serde_json::{Value, json};

fn glyph_source<'a>(text: &'a [u16], glyph: &fine_edit::GlyphBounds) -> Option<&'a [u16]> {
    let [start, end] = glyph.source_utf16?;
    text.get(start as usize..end as usize)
}

// Coordinates relative to the original tile center, transformed in paint order.
fn glyph_point(
    g: &fine_edit::GlyphBounds,
    edit: Option<&Adjustment>,
    mut offset: [f64; 2],
) -> [f32; 2] {
    let [x, y, w, h] = g.bounds;
    let mut center = [x as f64 + w as f64 / 2., y as f64 + h as f64 / 2.];
    if let Some(e) = edit {
        center[0] += f64::from(e.dx);
        center[1] += f64::from(e.dy);
        let (sin, cos) = f64::from(e.angle).to_radians().sin_cos();
        let scale = f64::from(e.scale) / 100.;
        let [u, v] = offset;
        offset = [scale * (cos * u - sin * v), scale * (sin * u + cos * v)];
        if let Some([a, b, c, d, f, k, g, h]) = e.warp {
            let [u, v] = offset;
            let z = g * u + h * v + 1.;
            offset = [(a * u + b * v + c) / z, (d * u + f * v + k) / z];
        }
    }
    [
        (center[0] + offset[0]) as f32,
        (center[1] + offset[1]) as f32,
    ]
}

#[derive(Clone)]
pub struct RenderedPreview {
    pub png: String,
    pub fine_edit: bool,
}

struct CachedPage {
    draft: String,
    section: u32,
    version: u32,
    settings: u32,
    edits: u32,
    page: usize,
    preview: RenderedPreview,
}

type PageSink<'a> = dyn FnMut(usize, &image::RgbaImage) -> handwriting_core::Result<()> + 'a;

pub struct Engine {
    font_dir: PathBuf,
    pub names: Vec<String>,
    fonts: HashMap<String, Arc<fontdue::Font>>,
    // The key identifies immutable text AND the draft's immutable style.
    cache: std::collections::VecDeque<CachedPage>,
}

impl Engine {
    pub fn new(font_dir: PathBuf) -> Result<Self> {
        let mut names = Vec::new();
        for entry in
            fs::read_dir(&font_dir).context("Set PANACHE_FONT_DIR to your font_assets directory")?
        {
            let entry = entry?;
            let path = entry.path();
            if entry.file_type()?.is_file()
                && path
                    .extension()
                    .is_some_and(|e| e.eq_ignore_ascii_case("ttf") || e.eq_ignore_ascii_case("otf"))
            {
                names.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        names.sort();
        ensure!(!names.is_empty(), "No fonts in {}", font_dir.display());
        Ok(Self {
            font_dir,
            names,
            fonts: HashMap::new(),
            cache: Default::default(),
        })
    }
    /// Keep parsed outlines across sections of one export, and only PNGs between calls.
    pub fn release_fonts(&mut self) {
        self.fonts.clear();
    }
    fn font(&mut self, name: &str) -> handwriting_core::Result<Arc<fontdue::Font>> {
        if let Some(font) = self.fonts.get(name) {
            return Ok(font.clone());
        }
        let bytes = fs::read(self.font_dir.join(name))
            .map_err(|e| handwriting_core::Error::new("invalid_font", e.to_string()))?;
        let font = FontBook::load(&bytes)?;
        if self.fonts.len() >= 4 {
            self.fonts.clear();
        }
        self.fonts.insert(name.to_owned(), font.clone());
        Ok(font)
    }
    fn request(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        background: Option<Vec<u8>>,
        edits: Option<Adjustments>,
    ) -> Result<RenderRequest> {
        let primary = self.draft_font(draft, draft.font_name())?;
        self.request_with_font(draft, section, background, edits, primary)
    }
    fn draft_font(&mut self, draft: &Snapshot<'_>, font_name: &str) -> Result<Arc<fontdue::Font>> {
        ensure!(
            font_name.starts_with("upload:") || self.names.iter().any(|f| f == font_name),
            "Font no longer available: {}",
            font_name
        );
        Ok(if font_name.starts_with("upload:") {
            let key = format!("{}:{}", draft.id, font_name);
            if let Some(font) = self.fonts.get(&key) {
                font.clone()
            } else {
                let font = FontBook::load(&draft.font_bytes(font_name)?)?;
                self.fonts.insert(key, font.clone());
                font
            }
        } else {
            self.font(font_name)?
        })
    }
    fn request_with_font(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        background: Option<Vec<u8>>,
        edits: Option<Adjustments>,
        primary: Arc<fontdue::Font>,
    ) -> Result<RenderRequest> {
        let fonts = FontBook::with_text_fallbacks(primary, &section.text, |name| {
            if self.names.iter().any(|n| n == name) {
                self.font(name).map(Some)
            } else {
                Ok(None)
            }
        })?;
        let mut params = crate::controls::parameters(draft, section.number, &draft.controls)?;
        params.fine_edit = edits.is_some() || section.text.contains("![");
        if let Some(paper) = draft.paper.as_ref().filter(|p| p.projection.is_some()) {
            params.width = Some(paper.width);
            params.height = Some(paper.height);
            params.underlined = false;
            params.paper_pattern = None;
            params.fine_edit = true;
        }
        params.fine_edits = edits;
        Ok(RenderRequest {
            text: section.text,
            params,
            background,
            fonts,
            limits: Limits::default(),
        })
    }
    pub fn preview(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        page_number: usize,
        cancel: &Cancellation,
    ) -> Result<(RenderedPreview, bool)> {
        self.preview_with_refresh(draft, section, page_number, false, cancel)
    }
    pub fn preview_with_refresh(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        page_number: usize,
        fresh: bool,
        cancel: &Cancellation,
    ) -> Result<(RenderedPreview, bool)> {
        let (n, v) = (section.number, section.version);
        ensure!(
            (1..=Limits::default().max_pages).contains(&page_number),
            "Invalid page number"
        );
        let (edit_revision, edits) = draft.edits(&section)?;
        let cached = self.cache.iter().position(|p| {
            p.draft == draft.id
                && p.settings == draft.settings_revision
                && p.edits == edit_revision
                && (p.section, p.version, p.page) == (n, v, page_number)
        });
        if let Some(index) = cached {
            if !fresh {
                return Ok((self.cache[index].preview.clone(), true));
            }
            // Leave no stale page on failure. A success restores this FIFO slot.
            self.cache.remove(index);
        }
        let mut background = draft.background()?;
        let camera = draft.camera(background.as_deref())?;
        let photo = Self::photo(draft, &mut background)?;
        let request = self.request(draft, section, background, edits)?;
        let image = Self::render_page(draft, n, &request, photo.as_ref(), cancel, page_number)?;
        let png = STANDARD.encode(camera.png(&image)?);
        let preview = RenderedPreview {
            png,
            fine_edit: request.params.fine_edit,
        };
        let entry = CachedPage {
            draft: draft.id.to_owned(),
            section: n,
            version: v,
            settings: draft.settings_revision,
            edits: edit_revision,
            page: page_number,
            preview: preview.clone(),
        };
        if let Some(index) = cached {
            self.cache.insert(index, entry);
        } else {
            if self.cache.len() == 4 {
                self.cache.pop_front();
            }
            self.cache.push_back(entry);
        }
        Ok((preview, false))
    }
    fn photo<'a>(
        draft: &'a Snapshot<'_>,
        background: &mut Option<Vec<u8>>,
    ) -> Result<
        Option<(
            &'a handwriting_core::photo::PaperProjection,
            image::RgbaImage,
        )>,
    > {
        let Some(map) = draft.paper.as_ref().and_then(|p| p.projection.as_ref()) else {
            return Ok(None);
        };
        let bytes = background.take().context("Missing original photograph")?;
        let img = handwriting_core::imaging::decode(&bytes, &Limits::default())?.into_rgba8();
        Ok(Some((map, img)))
    }
    fn render_pages(
        request: &RenderRequest,
        photo: Option<&(&handwriting_core::photo::PaperProjection, image::RgbaImage)>,
        cancel: &Cancellation,
        stop: usize,
        emit: impl FnMut(usize, image::RgbaImage) -> handwriting_core::Result<()>,
    ) -> handwriting_core::Result<usize> {
        match photo {
            Some((map, img)) => {
                handwriting_core::render::render_on_photo(request, cancel, stop, map, img, emit)
            }
            None => handwriting_core::render::render_until_page(request, cancel, stop, emit),
        }
    }
    fn render_page(
        draft: &Snapshot<'_>,
        section: u32,
        request: &RenderRequest,
        photo: Option<&(&handwriting_core::photo::PaperProjection, image::RgbaImage)>,
        cancel: &Cancellation,
        page_number: usize,
    ) -> Result<image::RgbaImage> {
        let mut image = None;
        let pages = Self::render_pages(request, photo, cancel, page_number, |i, page| {
            if i + 1 == page_number {
                image = Some(page);
            }
            Ok(())
        })?;
        image.ok_or_else(|| {
            draft.page_error(
                section,
                handwriting_core::Error::new(
                    "invalid_page",
                    format!("Section has {pages} pages; requested {page_number}"),
                ),
            )
        })
    }
    pub fn page_count(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        cancel: &Cancellation,
    ) -> Result<u32> {
        let (_, edits) = draft.edits(&section)?;
        // Projected photos are laid out in rectified paper space. Their final photo composite does not paginate.
        let background = if draft.paper.as_ref().is_some_and(|p| p.projection.is_some()) {
            None
        } else {
            draft.background()?
        };
        let req = self.request(draft, section, background, edits)?;
        Ok(u32::try_from(handwriting_core::render::count_pages(
            &req, cancel,
        )?)?)
    }

    fn fine_request(&mut self, draft: &Snapshot<'_>, section: Section) -> Result<RenderRequest> {
        let (_, edits) = draft.edits(&section)?;
        let projected = draft.paper.as_ref().is_some_and(|p| p.projection.is_some());
        let background = if projected { None } else { draft.background()? };
        let mut req = self.request(draft, section, background, edits)?;
        req.params.fine_edit = true;
        Ok(req)
    }
    pub fn review_baselines(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        page: usize,
        cancel: &Cancellation,
    ) -> Result<crate::review::PageSample> {
        let number = section.number;
        let source_revision = section.version;
        let req = self.fine_request(draft, section)?;
        let (_, glyphs) = fine_edit::inspect_page(&req, page, cancel)
            .map_err(|error| draft.page_error(number, error))?;
        let edits = req
            .params
            .fine_edits
            .as_ref()
            .map(|v| {
                v.glyphs
                    .iter()
                    .map(|e| (e.id, e))
                    .collect::<HashMap<_, _>>()
            })
            .unwrap_or_default();
        let stride = glyphs.len().div_ceil(384).max(1);
        // Bind page membership to the immutable section text and all layout units, not just the measurement sample.
        use sha2::{Digest, Sha256};
        let mut membership = Sha256::new();
        membership.update(source_revision.to_le_bytes());
        for glyph in &glyphs {
            membership.update(glyph.id.to_le_bytes());
            membership.update(
                glyph
                    .source_utf16
                    .unwrap_or([u32::MAX; 2])
                    .map(u32::to_le_bytes)
                    .concat(),
            );
        }
        let baselines = glyphs
            .iter()
            .filter(|g| g.illustration.is_none())
            .step_by(stride)
            .map(|g| {
                let dy = f64::from(g.baseline - g.bounds[1]) - f64::from(g.bounds[3]) / 2.;
                crate::review::photo_point(
                    draft,
                    glyph_point(g, edits.get(&g.id).copied(), [0., dy]),
                )
            })
            .collect();
        let mut text = Vec::new();
        let mut drawing = None;
        for g in &glyphs {
            let edit = edits.get(&g.id).copied();
            let is_drawing = g.illustration == Some(g.id) || g.is_native_diagram;
            if !(g.is_text || is_drawing && drawing.is_none())
                || edit.is_some_and(|v| v.opacity == 0)
            {
                continue;
            }
            let hw = f64::from(g.bounds[2]) / 2.;
            let hh = f64::from(g.bounds[3]) / 2.;
            let corners = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]]
                .map(|uv| crate::review::photo_point(draft, glyph_point(g, edit, uv)));
            let bounds = crate::review::Bounds::from_corners(corners);
            if is_drawing {
                drawing = Some(bounds);
            } else {
                let edge = |a: [f32; 2], b: [f32; 2]| (a[0] - b[0]).hypot(a[1] - b[1]);
                let width = edge(corners[0], corners[1]) + edge(corners[3], corners[2]);
                let height = edge(corners[0], corners[3]) + edge(corners[1], corners[2]);
                let dy = f64::from(g.baseline - g.bounds[1]) - hh;
                let baseline = glyph_point(g, edit, [0., dy])[1];
                let top = glyph_point(g, edit, [0., -hh]);
                let bottom = glyph_point(g, edit, [0., hh]);
                text.push(crate::review::TextSample {
                    bounds,
                    baseline,
                    paper_vertical_scale: edge(top, bottom) / g.bounds[3] as f32,
                    stretch: (width / height) / (hw / hh) as f32,
                });
            }
        }
        Ok(crate::review::PageSample {
            text,
            drawing,
            baselines,
            content_sha256: format!("{:x}", membership.finalize()),
        })
    }

    pub fn layout(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        input: &crate::Preview,
        cancel: &Cancellation,
    ) -> Result<Value> {
        let limit = input.limit.unwrap_or(12);
        ensure!((1..=32).contains(&limit), "limit must be 1..32");
        let offset = input.offset.unwrap_or(0);
        let page = input.page.unwrap_or(1);
        let number = section.number;
        let req = self.fine_request(draft, section)?;
        let (_, mut bounds) = fine_edit::inspect_page(&req, page, cancel)
            .map_err(|error| draft.page_error(number, error))?;
        if input.illustrations_only == Some(true) {
            bounds.retain(|g| g.illustration.is_some());
        }
        let edits = req
            .params
            .fine_edits
            .as_ref()
            .map(|v| {
                v.glyphs
                    .iter()
                    .map(|e| (e.id, e))
                    .collect::<HashMap<_, _>>()
            })
            .unwrap_or_default();
        let center = |g: &fine_edit::GlyphBounds| {
            crate::review::photo_point(draft, glyph_point(g, edits.get(&g.id).copied(), [0., 0.]))
        };
        if let Some(poly) = &input.region {
            ensure!(
                (3..=32).contains(&poly.len()),
                "Use 3..32 vertices in image pixels"
            );
            bounds.retain(|g| crate::review::contains(poly, center(g)));
        }
        let utf16: Vec<_> = req.text.encode_utf16().collect();
        let rows: Vec<_> = bounds
            .iter()
            .skip(offset)
            .take(limit)
            .map(|g| {
                let mut row = json!({"id":g.id,"bounds":g.bounds});
                if input.region.is_some() {
                    row["selected_center"] = json!(center(g));
                }
                if let Some(parent) = g.illustration {
                    row["kind"] = json!(if parent == g.id {
                        "illustration"
                    } else {
                        "illustration_detail"
                    });
                    row["illustration_id"] = json!(parent);
                }
                if let Some(map) = draft.paper.as_ref().and_then(|p| p.projection.as_ref()) {
                    let [x, y, w, h] = g.bounds;
                    let project = |x: i32, y: i32| {
                        map.photo_point(x as f32, y as f32)
                            .map(|n| n.round() as i32)
                    };
                    row["photo_quad"] = json!([
                        project(x, y),
                        project(x + w, y),
                        project(x + w, y + h),
                        project(x, y + h)
                    ]);
                    if g.illustration.is_none() {
                        row["photo_baseline"] =
                            json!([project(x, g.baseline), project(x + w, g.baseline)]);
                    }
                }
                if let Some(chars) = glyph_source(&utf16, g) {
                    row["text"] = json!(
                        String::from_utf16_lossy(chars)
                            .chars()
                            .take(24)
                            .collect::<String>()
                    );
                }
                if let Some(edit) = req
                    .params
                    .fine_edits
                    .as_ref()
                    .and_then(|v| v.glyphs.iter().find(|e| e.id == g.id))
                {
                    row["adjustment"] = json!(edit);
                    let w = f64::from(g.bounds[2]) / 2.;
                    let h = f64::from(g.bounds[3]) / 2.;
                    row["current_photo_quad"] =
                        json!([[-w, -h], [w, -h], [w, h], [-w, h]].map(|uv| {
                            crate::review::photo_point(draft, glyph_point(g, Some(edit), uv))
                        }));
                }
                row
            })
            .collect();
        Ok(
            json!({"draft_id":draft.id,"revision":draft.revision,"section":number,"page":page,
            "glyphs":rows,"total":bounds.len(),"next_offset":offset.checked_add(limit).filter(|n|*n<bounds.len())}),
        )
    }
    pub fn export(
        &mut self,
        writer: &mut crate::storage::BudgetWriter<'_>,
        draft: &Snapshot<'_>,
        sections: Vec<Section>,
        format: Format,
        cancel: &Cancellation,
        mut on_page: impl FnMut(usize, u32, usize, &image::RgbaImage),
    ) -> Result<usize> {
        let mut count = 0;
        let mut background = draft.background()?;
        let camera = draft.camera(background.as_deref())?;
        let photo = Self::photo(draft, &mut background)?;
        let render_sections = |emit: &mut PageSink<'_>| -> Result<()> {
            for section in sections {
                cancel.check()?;
                let (_, edits) = draft.edits(&section)?;
                let number = section.number;
                let mut request = self.request(draft, section, background.take(), edits)?;
                request.params.pdf_save = matches!(format, Format::Pdf);
                request.limits.max_pages -= count;
                Self::render_pages(
                    &request,
                    photo.as_ref(),
                    cancel,
                    usize::MAX,
                    |index, page| {
                        emit(count, &page)?;
                        count += 1;
                        on_page(count, number, index + 1, &page);
                        Ok(())
                    },
                )?;
                background = request.background.take();
            }
            cancel.check()?;
            Ok(())
        };
        match format {
            Format::Pdf => {
                let mut pdf = export::PdfExport::lossless();
                render_sections(&mut |_, page| pdf.add(page))?;
                writer.write_all(&pdf.finish_with_camera(&camera))?;
            }
            Format::Zip => {
                let mut zip = export::ZipExport::new(writer);
                render_sections(&mut |i, page| zip.add_with_camera(i, page, &camera))?;
                zip.finish()?;
            }
        };
        cancel.check()?;
        Ok(count)
    }
}
