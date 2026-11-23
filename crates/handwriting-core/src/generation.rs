//! 2026-10-31：共享渲染与导出编排；路径、任务提交和失败清理由平台入口管理。
use crate::{
    Cancellation, Error, RenderRequest, Result, export, fine_edit,
    render::{self, PageInk},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use std::io::{Seek, Write};

pub trait WriteSeek: Write + Seek {}
impl<T: Write + Seek> WriteSeek for T {}

pub enum Output<'a> {
    Preview(&'a mut dyn FnMut(usize, Vec<u8>) -> Result<()>),
    InkLayers(&'a mut dyn FnMut(usize, EncodedInkPage) -> Result<()>),
    Pdf(&'a mut dyn Write),
    Zip(&'a mut dyn WriteSeek),
}

#[derive(serde::Serialize)]
pub struct EncodedInkPage {
    pub paper: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_exif: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ink: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fine: Option<fine_edit::EncodedFinePage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    Rendering,
    PageReady(usize),
    Exporting,
}

/// 2026-10-31：每页编码后报告真实页数，结束前后检查取消，不推算总完成百分比。
pub fn generate(
    request: &RenderRequest,
    cancel: &Cancellation,
    output: Output<'_>,
    mut progress: impl FnMut(Event) -> Result<()>,
) -> Result<()> {
    cancel.check()?;
    progress(Event::Rendering)?;
    cancel.check()?;
    let camera =
        export::CameraMetadata::from_paper(request.background.as_deref(), &request.params.camera)?;
    match output {
        Output::Preview(emit) => {
            render::render(request, cancel, |index, image| {
                cancel.check()?;
                let bytes = camera.png(&image)?;
                cancel.check()?;
                emit(index, bytes)?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
        }
        Output::InkLayers(emit) => {
            let key = request
                .params
                .fine_edit
                .then(|| fine_edit::document_key(&request.text, &request.params));
            crate::render::render_pages(request, cancel, usize::MAX, |index, paper, alpha| {
                let alpha = alpha.ok_or_else(|| Error::new("invalid_parameter", "ink_layers"))?;
                cancel.check()?;
                let paper = STANDARD.encode(export::png(&paper)?);
                cancel.check()?;
                let (ink, fine) =
                    match alpha {
                        PageInk::Flat(alpha) => (
                            Some(STANDARD.encode(export::png(
                                &crate::ink_effects::transparent_mask(&alpha),
                            )?)),
                            None,
                        ),
                        PageInk::Fine(tiles) => (
                            None,
                            Some(fine_edit::encode(
                                key.as_deref().unwrap_or_default(),
                                &tiles,
                                cancel,
                            )?),
                        ),
                    };
                emit(
                    index,
                    EncodedInkPage {
                        paper,
                        ink,
                        fine,
                        camera_exif: (!camera.exif().is_empty())
                            .then(|| STANDARD.encode(camera.exif())),
                    },
                )?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
        }
        Output::Pdf(writer) => {
            let mut pdf = if request.params.ink_layers || request.params.fine_edit {
                export::PdfExport::lossless()
            } else {
                export::PdfExport::new()
            };
            render::render(request, cancel, |index, image| {
                cancel.check()?;
                pdf.add(&image)?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
            progress(Event::Exporting)?;
            cancel.check()?;
            writer
                .write_all(&pdf.finish_with_camera(&camera))
                .map_err(|e| Error::new("storage_failed", e.to_string()))?;
        }
        Output::Zip(writer) => {
            let mut zip = export::ZipExport::new(writer);
            render::render(request, cancel, |index, image| {
                cancel.check()?;
                zip.add_with_camera(index, &image, &camera)?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
            progress(Event::Exporting)?;
            cancel.check()?;
            zip.finish()?;
        }
    }
    cancel.check()
}
