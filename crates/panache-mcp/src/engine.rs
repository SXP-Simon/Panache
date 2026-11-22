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

struct CachedPage {
    draft: String,
    section: u32,
    version: u32,
    settings: u32,
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
        let params = crate::controls::parameters(draft, section.number, &draft.controls)?;
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
        if let Some(hit) = self.cache.iter().find(|p| {
            p.draft == draft.id
                && p.settings == draft.settings_revision
                && (p.section, p.version, p.page) == (n, v, page_number)
        }) {
            return Ok((hit.png.clone(), true));
        }
        let request = self.request(draft, section, draft.background()?)?;
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
            page: page_number,
            png: png.clone(),
        });
        Ok((png, false))
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
                let mut request = self.request(draft, section, background.take())?;
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
