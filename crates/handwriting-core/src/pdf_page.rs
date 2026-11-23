use crate::{Error, Limits, Result};
use base64::{Engine, engine::general_purpose::STANDARD};
use hayro::{
    PixmapSettings, RenderCache,
    hayro_interpret::{InterpreterSettings, InterpreterWarning},
    hayro_syntax::{LoadPdfError, Pdf},
    vello_cpu::color::palette::css::WHITE,
};
use lopdf::{Document, Stream, dictionary};
use serde::Serialize;
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

mod text;
mod visibility;
pub use text::TextLine;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PdfPage {
    pub page_count: usize,
    pub page_index: usize,
    pub width: u32,
    pub height: u32,
    pub page_width_pt: f32,
    pub page_height_pt: f32,
    pub background_png: String,
    pub lines: Vec<TextLine>,
    pub warnings: Vec<&'static str>,
}

fn load(data: Vec<u8>) -> Result<Pdf> {
    Pdf::new(data).map_err(|error| match error {
        LoadPdfError::Decryption(_) => Error::new("encrypted_pdf", "PDF 需要解密"),
        LoadPdfError::Invalid => Error::new("invalid_document", "无法读取 PDF"),
    })
}

pub fn import(
    bytes: Vec<u8>,
    fields: &HashMap<String, String>,
    limits: &Limits,
) -> Result<PdfPage> {
    if bytes.len() > limits.max_file_bytes {
        return Err(Error::new("upload_limit", "PDF 文件过大"));
    }
    let index = fields
        .get("pageIndex")
        .map_or("0", String::as_str)
        .parse::<usize>()
        .map_err(|_| Error::new("invalid_parameter", "PDF 页码无效"))?;
    let layout = match fields.get("mode").map_or("layout", String::as_str) {
        "layout" => true,
        "fill" => false,
        _ => return Err(Error::new("invalid_parameter", "PDF 导入模式无效")),
    };
    let pdf = load(bytes)?;
    let page_count = pdf.pages().len();
    if page_count > limits.max_pages {
        return Err(Error::new("page_limit", "PDF 页数超过限制"));
    }
    let page = pdf
        .pages()
        .get(index)
        .ok_or_else(|| Error::new("invalid_parameter", "PDF 页码超出范围"))?;
    let (w, h) = page.render_dimensions();
    let unit = page.raw().get::<f32>(b"UserUnit").unwrap_or(1.0);
    let (page_width_pt, page_height_pt) = (w * unit, h * unit);
    if !page_width_pt.is_finite()
        || !page_height_pt.is_finite()
        || page_width_pt <= 0.0
        || page_height_pt <= 0.0
    {
        return Err(Error::new("invalid_document", "PDF 页面尺寸无效"));
    }
    // 2026-11-23：按 144 DPI 生成底图，在扫描稿和超大画幅上按比例降低采样。
    let scale = (2.0 * unit).min(4096.0 / w.max(h)).min(
        ((limits.max_pixels.min(4_000_000) as f64 / (f64::from(w) * f64::from(h))).sqrt()) as f32,
    );
    if (w * scale) < 1.0 || (h * scale) < 1.0 {
        return Err(Error::new("pixel_limit", "PDF 页面长宽比超过限制"));
    }
    let warning = Arc::new(AtomicBool::new(false));
    let sink = warning.clone();
    let settings = InterpreterSettings {
        warning_sink: Arc::new(move |_: InterpreterWarning| {
            sink.store(true, Ordering::Relaxed);
        }),
        ..Default::default()
    };
    let mut extraction = text::extract(page, scale, &settings, limits)?;
    let mut warnings = Vec::new();
    let mut edited = None;
    if layout && let Some(stream) = extraction.background.take() {
        // 2026-11-23：使用新内容流，仅修改所选页。共享的 Form、字体、图像及批注保持完整。
        edited = edit_background(pdf.data().as_ref(), index, stream);
        if edited.is_none() {
            extraction.lines.clear();
            extraction.unsupported = true;
        }
    }
    let raster_page = edited
        .as_ref()
        .and_then(|p| p.pages().get(index))
        .unwrap_or(page);
    let pixmap = hayro::render(
        raster_page,
        &RenderCache::new(),
        &settings,
        &Default::default(),
        &PixmapSettings {
            x_scale: scale,
            y_scale: scale,
            bg_color: WHITE,
        },
    );
    if warning.load(Ordering::Relaxed) {
        warnings.push("partial_render");
    }
    if extraction.unsupported {
        warnings.push("unsupported_text");
    }
    if extraction.lines.is_empty() {
        warnings.push("no_editable_text");
    }
    let width = u32::from(pixmap.width());
    let height = u32::from(pixmap.height());
    let png = pixmap
        .into_png()
        .map_err(|e| Error::new("encode_failed", e.to_string()))?;
    Ok(PdfPage {
        page_count,
        page_index: index,
        width,
        height,
        page_width_pt,
        page_height_pt,
        background_png: STANDARD.encode(png),
        lines: extraction.lines,
        warnings,
    })
}

fn edit_background(bytes: &[u8], index: usize, stream: Vec<u8>) -> Option<Pdf> {
    let mut doc = Document::load_mem(bytes).ok()?;
    let page = doc.page_iter().nth(index)?;
    let id = doc.add_object(Stream::new(dictionary! {}, stream));
    doc.get_object_mut(page)
        .ok()?
        .as_dict_mut()
        .ok()?
        .set("Contents", id);
    let mut output = Vec::new();
    doc.save_to(&mut output).ok()?;
    load(output).ok()
}
