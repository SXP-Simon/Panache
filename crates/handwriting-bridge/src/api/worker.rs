//! Mobile worker lifecycle and publication of completed artifacts.
use super::{Request, Task, fonts, io_error, limits, read};
use handwriting_core::{
    Cancellation, Error, FontBook, Parameters, RenderRequest, Result,
    generation::{self, Event, Output},
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub(super) fn run(request: Request, worker: &Mutex<Task>) {
    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| generate(request, worker)))
            .unwrap_or_else(|_| Err(Error::new("worker_failed", "引擎任务异常")));
    if let Ok(mut state) = worker.lock() {
        state.running = false;
        match outcome.and_then(|()| state.cancel.check()) {
            Ok(()) => {
                state.task_status = "completed".into();
                state.task_progress = 100;
                state.task_stage = "completed".into();
            }
            Err(error) => {
                state.task_status = if error.code == "cancelled" {
                    "cancelled"
                } else {
                    "failed"
                }
                .into();
                state.task_stage = state.task_status.clone();
                state.error_code = Some(error.code.into());
                state.error_message = Some(error.message);
                state.pages.clear();
                state.result = None;
                let _ = fs::remove_dir_all(&state.directory);
            }
        }
    }
}

fn prepare(request: &Request, cancel: &Cancellation) -> Result<RenderRequest> {
    let mut params = Parameters::from_form(&request.fields)?;
    if !request.fields.contains_key("seed") && !params.fine_edit {
        params.seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(io_error)?
            .as_nanos() as u64;
    }
    let text = request
        .fields
        .get("text")
        .cloned()
        .ok_or_else(|| Error::new("invalid_parameter", "缺少 text"))?;
    handwriting_core::validate_document(&text, &limits())?;
    let names = fonts(&request.font_dir)?;
    let primary = if let Some(upload) = request.files.get("font_file") {
        FontBook::load(&read(&upload.path)?)?
    } else {
        let name = request.fields.get("font_option").unwrap_or(&names[0]);
        if !names.contains(name) {
            return Err(Error::new("invalid_font", "字体不存在"));
        }
        FontBook::load(&fs::read(request.font_dir.join(name)).map_err(io_error)?)?
    };
    let fonts = FontBook::with_text_fallbacks(primary, &text, |name| {
        if names.iter().any(|available| available == name) {
            FontBook::load(&fs::read(request.font_dir.join(name)).map_err(io_error)?).map(Some)
        } else {
            Ok(None)
        }
    })?;
    cancel.check()?;
    let background = request
        .files
        .get("background_image")
        .map(|upload| read(&upload.path))
        .transpose()?;
    Ok(RenderRequest {
        text,
        params,
        background,
        fonts,
        limits: limits(),
    })
}

fn generate(request: Request, task: &Mutex<Task>) -> Result<()> {
    let state = task.lock().map_err(io_error)?;
    let cancel = state.cancel.clone();
    let directory = state.directory.clone();
    drop(state);
    cancel.check()?;
    let render_request = prepare(&request, &cancel)?;
    let params = &render_request.params;
    let progress = |event| {
        let mut state = task.lock().map_err(io_error)?;
        match event {
            Event::Rendering => state.task_stage = "rendering".into(),
            Event::PageReady(pages) => {
                state.pages_completed = pages;
                state.task_progress = (pages * 5).min(95) as u32;
            }
            Event::Exporting => state.task_stage = "exporting".into(),
        }
        Ok(())
    };
    let result = if params.pdf_save || !params.preview {
        Some(export(&render_request, &directory, &cancel, progress)?)
    } else if params.ink_layers {
        generation::generate(
            &render_request,
            &cancel,
            Output::InkLayers(&mut |index, page| {
                let bytes = serde_json::to_vec(&page).map_err(io_error)?;
                publish_page(task, directory.join(format!("{index}.json")), &bytes)
            }),
            progress,
        )?;
        None
    } else {
        generation::generate(
            &render_request,
            &cancel,
            Output::Preview(&mut |index, bytes| {
                publish_page(task, directory.join(format!("{index}.png")), &bytes)
            }),
            progress,
        )?;
        None
    };
    let mut state = task.lock().map_err(io_error)?;
    cancel.check()?;
    if let Some((path, mime)) = result {
        state.result = Some(path);
        state.content_type = mime.into();
    } else {
        state.content_type = if params.ink_layers {
            "application/json"
        } else {
            "image/png"
        }
        .into();
    }
    Ok(())
}

fn export(
    request: &RenderRequest,
    directory: &Path,
    cancel: &Cancellation,
    progress: impl FnMut(Event) -> Result<()>,
) -> Result<(PathBuf, &'static str)> {
    let (name, mime) = if request.params.pdf_save {
        ("export.pdf", "application/pdf")
    } else {
        ("export.zip", "application/zip")
    };
    let path = directory.join(name);
    let partial = path.with_extension("partial");
    let mut file = fs::File::create(&partial).map_err(io_error)?;
    let output = if request.params.pdf_save {
        Output::Pdf(&mut file)
    } else {
        Output::Zip(&mut file)
    };
    generation::generate(request, cancel, output, progress)?;
    file.sync_all().map_err(io_error)?;
    drop(file);
    cancel.check()?;
    fs::rename(&partial, &path).map_err(io_error)?;
    Ok((path, mime))
}

fn publish_page(task: &Mutex<Task>, path: PathBuf, bytes: &[u8]) -> Result<()> {
    fs::write(&path, bytes).map_err(io_error)?;
    task.lock().map_err(io_error)?.pages.push(path);
    Ok(())
}
