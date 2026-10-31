//! 2026-10-31：共享渲染与导出编排；路径、任务提交和失败清理由平台入口管理。
use crate::{Cancellation, Error, RenderRequest, Result, export, render};
use std::io::{Seek, Write};

pub trait WriteSeek: Write + Seek {}
impl<T: Write + Seek> WriteSeek for T {}

pub enum Output<'a> {
    Preview(&'a mut dyn FnMut(usize, Vec<u8>) -> Result<()>),
    Pdf(&'a mut dyn Write),
    Zip(&'a mut dyn WriteSeek),
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
    match output {
        Output::Preview(emit) => {
            render(request, cancel, |index, image| {
                cancel.check()?;
                let bytes = export::png(&image)?;
                cancel.check()?;
                emit(index, bytes)?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
        }
        Output::Pdf(writer) => {
            let mut pdf = export::PdfExport::new();
            render(request, cancel, |index, image| {
                cancel.check()?;
                pdf.add(&image)?;
                progress(Event::PageReady(index + 1))?;
                cancel.check()
            })?;
            progress(Event::Exporting)?;
            cancel.check()?;
            writer
                .write_all(&pdf.finish())
                .map_err(|e| Error::new("storage_failed", e.to_string()))?;
        }
        Output::Zip(writer) => {
            let mut zip = export::ZipExport::new(writer);
            render(request, cancel, |index, image| {
                cancel.check()?;
                zip.add(index, &image)?;
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
