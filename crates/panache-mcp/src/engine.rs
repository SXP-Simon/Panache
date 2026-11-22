use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use handwriting_core::{Cancellation, FontBook, Limits, RenderRequest, export, render};
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
            self.names.iter().any(|f| f == font_name),
            "Font no longer available: {}",
            font_name
        );
        let primary = self.font(font_name)?;
        let fonts = FontBook::with_text_fallbacks(primary, &section.text, |name| {
            if self.names.iter().any(|n| n == name) {
                self.font(name).map(Some)
            } else {
                Ok(None)
            }
        })?;
        let mut params = crate::controls::parameters(draft, section.number, &draft.controls)?;
        params.fine_edit = edits.is_some();
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
        let request = self.request(draft, section, draft.background()?, edits)?;
        let mut image = None;
        let pages = handwriting_core::render::render_until_page(
            &request,
            cancel,
            page_number,
            |i, page| {
                if i + 1 == page_number {
                    image = Some(STANDARD.encode(export::png(&page)?));
                }
                Ok(())
            },
        )?;
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
    fn fine_request(&mut self, draft: &Snapshot<'_>, section: Section) -> Result<RenderRequest> {
        let (_, edits) = draft.edits(&section)?;
        let mut req = self.request(draft, section, draft.background()?, edits)?;
        req.params.fine_edit = true;
        Ok(req)
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
        let (_, bounds) = fine_edit::inspect_page(&req, page, cancel)?;
        let utf16: Vec<_> = req.text.encode_utf16().collect();
        let rows: Vec<_> = bounds
            .iter()
            .skip(offset)
            .take(limit)
            .map(|g| {
                let mut row = json!({"id":g.id,"bounds":g.bounds});
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
            input.dx.is_some()
                || input.dy.is_some()
                || input.scale.is_some()
                || input.angle.is_some()
                || input.opacity.is_some(),
            "Supply at least one adjustment"
        );
        ensure!(
            input.dx.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.dy.is_none_or(|v| (-65535..=65535).contains(&v))
                && input.scale.is_none_or(|v| (50..=200).contains(&v))
                && input.angle.is_none_or(|v| (-45..=45).contains(&v))
                && input.opacity.is_none_or(|v| v <= 100),
            "Invalid glyph adjustment"
        );
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
            e.dx = input.dx.unwrap_or(e.dx);
            e.dy = input.dy.unwrap_or(e.dy);
            e.angle = input.angle.unwrap_or(e.angle);
            e.scale = input.scale.unwrap_or(e.scale);
            e.opacity = input.opacity.unwrap_or(e.opacity);
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
        let render_sections = |emit: &mut PageSink<'_>| -> Result<()> {
            for section in sections {
                cancel.check()?;
                let (_, edits) = draft.edits(&section)?;
                let mut request = self.request(draft, section, background.take(), edits)?;
                request.limits.max_pages -= count;
                render(&request, cancel, |_, page| {
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
                temp.write_all(&pdf.finish())?;
                "pdf"
            }
            Format::Zip => {
                let mut zip = export::ZipExport::new(temp.as_file_mut());
                render_sections(&mut |i, page| zip.add(i, page))?;
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
