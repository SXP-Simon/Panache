use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, FontBook, Limits, RenderRequest, export};
use std::{
    collections::HashMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
};
use tempfile::NamedTempFile;
use uuid::Uuid;

use crate::{
    Format,
    drafts::{Section, Snapshot},
};

use handwriting_core::fine_edit::{self, Adjustment, Adjustments};
use serde_json::{Value, json};

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

struct CachedPage {
    draft: String,
    section: u32,
    version: u32,
    settings: u32,
    edits: u32,
    page: usize,
    png: String,
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
        let font_name = draft
            .controls
            .get("font")
            .and_then(serde_json::Value::as_str)
            .unwrap_or(&draft.style.font);
        ensure!(
            font_name.starts_with("upload:") || self.names.iter().any(|f| f == font_name),
            "Font no longer available: {}",
            font_name
        );
        let primary = if font_name.starts_with("upload:") {
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
        };
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
    ) -> Result<(String, bool)> {
        let (n, v) = (section.number, section.version);
        ensure!(
            (1..=Limits::default().max_pages).contains(&page_number),
            "Invalid page number"
        );
        let (edit_revision, edits) = draft.edits(&section)?;
        if let Some(hit) = self.cache.iter().find(|p| {
            p.draft == draft.id
                && p.settings == draft.settings_revision
                && p.edits == edit_revision
                && (p.section, p.version, p.page) == (n, v, page_number)
        }) {
            return Ok((hit.png.clone(), true));
        }
        let mut background = draft.background()?;
        let camera = draft.camera(background.as_deref())?;
        let photo = Self::photo(draft, &mut background)?;
        let request = self.request(draft, section, background, edits)?;
        let mut image = None;
        let pages =
            Self::render_pages(&request, photo.as_ref(), cancel, page_number, |i, page| {
                if i + 1 == page_number {
                    image = Some(STANDARD.encode(camera.png(&page)?));
                }
                Ok(())
            })?;
        let png =
            image.with_context(|| format!("Section has {pages} pages; requested {page_number}"))?;
        if self.cache.len() == 4 {
            self.cache.pop_front();
        }
        self.cache.push_back(CachedPage {
            draft: draft.id.to_owned(),
            section: n,
            version: v,
            settings: draft.settings_revision,
            edits: edit_revision,
            page: page_number,
            png: png.clone(),
        });
        Ok((png, false))
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
    ) -> Result<Vec<[f32; 2]>> {
        let req = self.fine_request(draft, section)?;
        let (_, glyphs) = fine_edit::inspect_page(&req, page, cancel)?;
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
        Ok(glyphs
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
            .collect())
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
        let (_, mut bounds) = fine_edit::inspect_page(&req, page, cancel)?;
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
                if let Some([a, b]) = g.source_utf16
                    && let Some(chars) = utf16.get(a as usize..b as usize)
                {
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
    pub fn adjust(
        &mut self,
        draft: &Snapshot<'_>,
        section: Section,
        input: &crate::Nudge,
        cancel: &Cancellation,
    ) -> Result<u32> {
        use std::collections::{BTreeMap, BTreeSet};
        let ids: BTreeSet<_> = input.ids.iter().copied().collect();
        ensure!(
            !ids.is_empty() && ids.len() == input.ids.len() && ids.len() <= 32,
            "Choose 1..32 distinct glyph IDs"
        );
        ensure!(
            input.target_quad.is_some()
                || input.place_center.is_some()
                || input.dx.is_some()
                || input.dy.is_some()
                || input.scale.is_some()
                || input.angle.is_some()
                || input.opacity.is_some()
                || input.shape.is_some()
                || input.thickness.is_some()
                || input.softness.is_some()
                || input.color.is_some(),
            "Supply at least one adjustment"
        );
        ensure!(
            input.dx.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.dy.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.scale.is_none_or(|v| (50..=200).contains(&v))
                && input.angle.is_none_or(|v| (-45..=45).contains(&v))
                && input.opacity.is_none_or(|v| v <= 100)
                && input
                    .shape
                    .as_ref()
                    .is_none_or(|s| (-20..=20).contains(&s.shear_degrees)
                        && (80..=120).contains(&s.top_width_percent)),
            "Invalid glyph adjustment"
        );
        let delta = |v: f64| -> Result<i8> {
            ensure!(
                (-2.0..=2.0).contains(&v) && (v * 10.).fract() == 0.,
                "Expected -2..2 pixels in steps of 0.1"
            );
            Ok((v * 10.) as i8)
        };
        let thickness = input.thickness.map(delta).transpose()?;
        let softness = input.softness.map(delta).transpose()?;
        let color = input
            .color
            .as_ref()
            .map(|c| -> Result<_> {
                if c == "inherit" {
                    return Ok(None);
                }
                let [r, g, b, _] = crate::Style {
                    ink: c.clone(),
                    ..draft.style.clone()
                }
                .ink_rgba()?;
                Ok(Some([r, g, b]))
            })
            .transpose()?;
        let version = section.version;
        let mut req = self.fine_request(draft, section)?;
        let (key, bounds) = fine_edit::inspect_page(&req, input.page, cancel)?;
        ensure!(
            ids.iter().all(|id| bounds.iter().any(|g| g.id == *id)),
            "Glyph not on this page; inspect its layout first"
        );
        let mut edits: BTreeMap<_, _> = req
            .params
            .fine_edits
            .take()
            .into_iter()
            .flat_map(|v| v.glyphs)
            .map(|e| (e.id, e))
            .collect();
        let params = &req.params;
        let [w, h] = draft
            .paper
            .as_ref()
            .map(|p| p.photo_size.unwrap_or([p.width, p.height]))
            .unwrap_or([params.width.unwrap_or(0), params.height.unwrap_or(0)]);
        let placement = if let Some(quad) = input.target_quad {
            ensure!(
                input.place_center.is_none()
                    && input.dx.is_none()
                    && input.dy.is_none()
                    && input.angle.is_none()
                    && input.scale.is_none()
                    && input.shape.is_none(),
                "Use target_quad separately from other geometry fields"
            );
            Some(crate::placement::Placement::new(
                draft,
                [w, h],
                &bounds,
                &ids,
                quad,
            )?)
        } else {
            None
        };
        let translation = if let Some(target) = input.place_center {
            ensure!(
                input.dx.is_none() && input.dy.is_none() && input.shape.is_none(),
                "Use place_center separately from dx/dy/shape"
            );
            ensure!(target[0] < w && target[1] < h, "Target outside the page");
            let projection = draft.paper.as_ref().and_then(|p| p.projection.as_ref());
            let dest = target.map(|v| v as f32);
            let dest = projection.map_or(dest, |p| p.paper_point(dest));
            let mut mean = [0., 0.];
            for g in bounds.iter().filter(|g| ids.contains(&g.id)) {
                let pos = glyph_point(g, edits.get(&g.id), [0., 0.]);
                for axis in 0..2 {
                    mean[axis] += pos[axis] / ids.len() as f32;
                }
            }
            Some([
                (dest[0] - mean[0]).round() as i32,
                (dest[1] - mean[1]).round() as i32,
            ])
        } else {
            None
        };
        for id in ids {
            let e = edits.entry(id).or_insert(Adjustment {
                id,
                dx: 0,
                dy: 0,
                scale: 100,
                angle: 0,
                opacity: 100,
                color: None,
                thickness: 0,
                softness: 0,
                warp: None,
            });
            let glyph = bounds
                .iter()
                .find(|g| g.id == id)
                .context("Unknown glyph")?;
            if let Some(map) = &placement {
                map.apply(e, glyph.bounds)?;
            }
            if let Some(shape) = &input.shape {
                let height = f64::from(glyph.bounds[3].max(1));
                let ratio = f64::from(shape.top_width_percent) / 100.;
                let shear = f64::from(shape.shear_degrees).to_radians().tan();
                let h = 2. * (ratio - 1.) / ((ratio + 1.) * height);
                let f = h * height * height / 4.;
                e.warp = if shape.shear_degrees == 0 && shape.top_width_percent == 100 {
                    None
                } else {
                    Some([
                        2. * ratio / (ratio + 1.),
                        shear,
                        shear * f,
                        0.,
                        1.,
                        f,
                        0.,
                        h,
                    ])
                };
            }
            if let Some([dx, dy]) = translation {
                e.dx = e.dx.checked_add(dx).context("Position overflow")?;
                e.dy = e.dy.checked_add(dy).context("Position overflow")?;
                ensure!(
                    (-65535..=65535).contains(&e.dx) && (-65535..=65535).contains(&e.dy),
                    "Move exceeds the supported layout range"
                );
            }
            e.dx = input.dx.unwrap_or(e.dx);
            e.dy = input.dy.unwrap_or(e.dy);
            e.angle = input.angle.unwrap_or(e.angle);
            e.scale = input.scale.unwrap_or(e.scale);
            e.opacity = input.opacity.unwrap_or(e.opacity);
            e.thickness = thickness.unwrap_or(e.thickness);
            e.softness = softness.unwrap_or(e.softness);
            if let Some(c) = color {
                e.color = c;
            }
            ensure!(
                fine_edit::usable_shape(e, glyph.bounds[2], glyph.bounds[3]),
                "Shape exceeds safe bounds at the requested scale or rotation"
            );
        }
        ensure!(edits.len() <= 10000, "Section glyph edit limit reached");
        cancel.check()?;
        draft.store_edits(
            input.section,
            version,
            &Adjustments {
                key,
                glyphs: edits.into_values().collect(),
            },
            &json!({"page":input.page,"ids":input.ids,"place_center":input.place_center,"target_quad":input.target_quad,"dx":input.dx,"dy":input.dy,"scale":input.scale,"angle":input.angle,"shape":input.shape,"opacity":input.opacity,"thickness":input.thickness,"softness":input.softness,"color":input.color,"note":input.note}),
        )
    }
    pub fn export(
        &mut self,
        dir: &Path,
        draft: &Snapshot<'_>,
        sections: Vec<Section>,
        format: Format,
        cancel: &Cancellation,
        mut progress: impl FnMut(usize),
    ) -> Result<(PathBuf, usize)> {
        let mut temp = NamedTempFile::new_in(dir)?;
        let mut count = 0;
        let mut background = draft.background()?;
        let camera = draft.camera(background.as_deref())?;
        let photo = Self::photo(draft, &mut background)?;
        let render_sections = |emit: &mut PageSink<'_>| -> Result<()> {
            for section in sections {
                cancel.check()?;
                let (_, edits) = draft.edits(&section)?;
                let mut request = self.request(draft, section, background.take(), edits)?;
                request.params.pdf_save = matches!(format, Format::Pdf);
                request.limits.max_pages -= count;
                Self::render_pages(&request, photo.as_ref(), cancel, usize::MAX, |_, page| {
                    emit(count, &page)?;
                    count += 1;
                    progress(count);
                    Ok(())
                })?;
                background = request.background.take();
            }
            cancel.check()?;
            Ok(())
        };
        let extension = match format {
            Format::Pdf => {
                let mut pdf = export::PdfExport::lossless();
                render_sections(&mut |_, page| pdf.add(page))?;
                temp.write_all(&pdf.finish_with_camera(&camera))?;
                "pdf"
            }
            Format::Zip => {
                let mut zip = export::ZipExport::new(temp.as_file_mut());
                render_sections(&mut |i, page| zip.add_with_camera(i, page, &camera))?;
                zip.finish()?;
                "zip"
            }
        };
        temp.as_file_mut().flush()?;
        cancel.check()?;
        let path = dir.join(format!("panache-{}.{}", Uuid::new_v4(), extension));
        temp.persist_noclobber(&path)?;
        Ok((path, count))
    }
}
