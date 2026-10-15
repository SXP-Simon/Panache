use handwriting_core::{
    Cancellation, Error, FontBook, Limits, Parameters, RenderRequest, Result, document, export,
    imaging, render,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

#[derive(Deserialize)]
pub struct Request {
    pub command: String,
    pub data_dir: PathBuf,
    pub font_dir: PathBuf,
    #[serde(default)]
    pub fields: HashMap<String, String>,
    #[serde(default)]
    pub files: HashMap<String, Upload>,
    #[serde(default)]
    pub task_id: String,
}
#[derive(Clone, Deserialize)]
pub struct Upload {
    pub name: String,
    pub path: PathBuf,
}
#[derive(Serialize)]
struct Task {
    task_status: String,
    task_progress: u32,
    error_message: Option<String>,
    pages: Vec<PathBuf>,
    result: Option<PathBuf>,
    content_type: String,
    #[serde(skip)]
    cancel: Cancellation,
    #[serde(skip)]
    directory: PathBuf,
    #[serde(skip)]
    running: bool,
}
static TASKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<Task>>>>> = OnceLock::new();
static OPERATIONS: Mutex<()> = Mutex::new(());
static NEXT: AtomicU64 = AtomicU64::new(1);
fn tasks() -> &'static Mutex<HashMap<String, Arc<Mutex<Task>>>> {
    TASKS.get_or_init(Default::default)
}
fn io_error(e: impl std::fmt::Display) -> Error {
    Error::new("storage_failed", e.to_string())
}
fn limits() -> Limits {
    Limits {
        max_pixels: 12_000_000,
        max_text_chars: 20_000,
        max_pages: 20,
        max_file_bytes: 16 * 1024 * 1024,
        max_archive_bytes: 32 * 1024 * 1024,
    }
}
fn read(path: &Path) -> Result<Vec<u8>> {
    if fs::metadata(path).map_err(io_error)?.len() > limits().max_file_bytes as u64 {
        return Err(Error::new("upload_limit", "文件超过移动端限制"));
    }
    fs::read(path).map_err(io_error)
}
fn fonts(dir: &Path) -> Result<Vec<String>> {
    let mut names: Vec<_> = fs::read_dir(dir)
        .map_err(io_error)?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_type().is_ok_and(|t| t.is_file()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| name.ends_with(".ttf") || name.ends_with(".otf") || name.ends_with(".ttc"))
        .collect();
    names.sort();
    // 2026-10-12：移动端优先使用较小的字体，大字体仅在用户选择时解析。
    if let Some(index) = names.iter().position(|n| n == "神韵英子楷书.ttf") {
        names.swap(0, index);
    }
    if names.is_empty() {
        return Err(Error::new("invalid_font", "没有内置字体"));
    }
    Ok(names)
}
fn task(id: &str) -> Result<Arc<Mutex<Task>>> {
    tasks()
        .lock()
        .map_err(io_error)?
        .get(id)
        .cloned()
        .ok_or_else(|| Error::new("task_not_found", "任务不存在"))
}

pub fn execute(mut request: Request) -> Result<Value> {
    fs::create_dir_all(&request.data_dir).map_err(io_error)?;
    request.data_dir = fs::canonicalize(&request.data_dir).map_err(io_error)?;
    request.font_dir = fs::canonicalize(&request.font_dir).map_err(io_error)?;
    for upload in request.files.values_mut() {
        upload.path = fs::canonicalize(&upload.path).map_err(io_error)?;
        if !upload.path.starts_with(&request.data_dir) {
            return Err(Error::new("invalid_upload", "文件必须位于应用数据目录"));
        }
    }
    match request.command.as_str() {
        "reset" => {
            let mut registry = tasks().lock().map_err(io_error)?;
            let mut active = false;
            for task in registry.values() {
                let state = task.lock().map_err(io_error)?;
                if state.running {
                    state.cancel.cancel();
                    active = true;
                }
            }
            if active {
                return Err(Error::new("queue_full", "正在取消旧任务"));
            }
            registry.clear();
            for name in ["tasks", "uploads"] {
                let path = request.data_dir.join(name);
                if path.exists() {
                    fs::remove_dir_all(path).map_err(io_error)?;
                }
            }
            Ok(json!({"status":"ready"}))
        }
        "fonts" => Ok(json!(fonts(&request.font_dir)?)),
        "license" => Ok(json!(concat!(
            include_str!("../../handwriting-core/NOTICE"),
            "\n",
            include_str!("../../handwriting-core/licenses/handright-LICENSE.txt")
        ))),
        "version" => Ok(json!({"version": handwriting_core::app_version()})),
        "import" | "identify" => {
            let _operation = OPERATIONS
                .try_lock()
                .map_err(|_| Error::new("queue_full", "本地引擎正在处理任务"))?;
            if tasks()
                .lock()
                .map_err(io_error)?
                .values()
                .any(|task| task.lock().is_ok_and(|state| state.running))
            {
                return Err(Error::new("queue_full", "本地引擎正在处理任务"));
            }
            let upload = request
                .files
                .get("file")
                .ok_or_else(|| Error::new("invalid_upload", "缺少文件"))?;
            let bytes = read(&upload.path)?;
            if request.command == "import" {
                Ok(json!({"text":document::extract(&upload.name, &bytes, &limits())?}))
            } else {
                let detected = imaging::identify(&imaging::decode(&bytes, &limits())?)?;
                Ok(
                    json!({"marginLeft":detected.margin_left,"marginRight":detected.margin_right,"marginTop":detected.margin_top,"marginBottom":detected.margin_bottom,"lineSpacing":detected.line_spacing}),
                )
            }
        }
        "status" | "result" => {
            let task = task(&request.task_id)?;
            let state = task.lock().map_err(io_error)?;
            if request.command == "result" && state.task_status != "completed" {
                return Err(Error::new("task_running", "任务尚未完成"));
            }
            serde_json::to_value(&*state).map_err(io_error)
        }
        "cancel" => {
            let task = task(&request.task_id)?;
            task.lock().map_err(io_error)?.cancel.cancel();
            Ok(json!({"status":"cancelling"}))
        }
        "cancel_all" => {
            for task in tasks().lock().map_err(io_error)?.values() {
                let state = task.lock().map_err(io_error)?;
                if state.directory.starts_with(&request.data_dir) {
                    state.cancel.cancel();
                }
            }
            Ok(json!({"status":"cancelling"}))
        }
        "submit" => submit(request),
        _ => Err(Error::new("invalid_command", "未知引擎操作")),
    }
}
fn submit(request: Request) -> Result<Value> {
    let _operation = OPERATIONS
        .try_lock()
        .map_err(|_| Error::new("queue_full", "本地引擎正在处理任务"))?;
    let mut registry = tasks().lock().map_err(io_error)?;
    if registry.values().any(|t| t.lock().is_ok_and(|s| s.running)) {
        return Err(Error::new("queue_full", "本地引擎正在处理任务"));
    }
    // 2026-10-12：只保留最近结果；不会清理仍在执行的任务。
    if registry.len() >= 8 {
        for task in registry.values() {
            if let Ok(t) = task.lock() {
                let _ = fs::remove_dir_all(&t.directory);
            }
        }
        registry.clear();
    }
    let id = format!(
        "{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    );
    let directory = request.data_dir.join("tasks").join(&id);
    fs::create_dir_all(&directory).map_err(io_error)?;
    let task = Arc::new(Mutex::new(Task {
        task_status: "processing".into(),
        task_progress: 0,
        error_message: None,
        pages: vec![],
        result: None,
        content_type: String::new(),
        cancel: Cancellation::default(),
        directory,
        running: true,
    }));
    registry.insert(id.clone(), task.clone());
    let worker = task.clone();
    if let Err(error) = std::thread::Builder::new()
        .name("handwriting-mobile".into())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                generate(request, &worker)
            }))
            .unwrap_or_else(|_| Err(Error::new("worker_failed", "引擎任务异常")));
            if let Ok(mut state) = worker.lock() {
                state.running = false;
                match outcome.and_then(|()| state.cancel.check()) {
                    Ok(()) => {
                        state.task_status = "completed".into();
                        state.task_progress = 100;
                    }
                    Err(error) => {
                        state.task_status = if error.code == "cancelled" {
                            "cancelled"
                        } else {
                            "failed"
                        }
                        .into();
                        state.error_message = Some(error.message);
                        state.pages.clear();
                        state.result = None;
                        let _ = fs::remove_dir_all(&state.directory);
                    }
                }
            }
        })
    {
        registry.remove(&id);
        let _ = fs::remove_dir_all(&task.lock().map_err(io_error)?.directory);
        return Err(io_error(error));
    }
    Ok(json!({"task_id":id}))
}
fn generate(request: Request, task: &Arc<Mutex<Task>>) -> Result<()> {
    let state = task.lock().map_err(io_error)?;
    let cancel = state.cancel.clone();
    let directory = state.directory.clone();
    drop(state);
    cancel.check()?;
    let mut params = Parameters::from_form(&request.fields)?;
    if !request.fields.contains_key("seed") {
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
    if text.chars().count() > limits().max_text_chars {
        return Err(Error::new("text_limit", "文本超过移动端限制"));
    }
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
    let render_request = RenderRequest {
        text,
        params: params.clone(),
        background,
        fonts,
        limits: limits(),
    };
    let mut pdf = export::PdfExport::new();
    let archive = fs::File::create(directory.join("export.zip.partial")).map_err(io_error)?;
    let mut zip = export::ZipExport::new(archive);
    render(&render_request, &cancel, |index, image| {
        cancel.check()?;
        if params.preview && !params.pdf_save {
            let path = directory.join(format!("{index}.png"));
            fs::write(&path, export::png(&image)?).map_err(io_error)?;
            task.lock().map_err(io_error)?.pages.push(path);
        } else if params.pdf_save {
            pdf.add(&image)?;
        } else {
            zip.add(index, &image)?;
        }
        task.lock().map_err(io_error)?.task_progress = ((index + 1) * 5).min(95) as u32;
        Ok(())
    })?;
    cancel.check()?;
    let result = if params.pdf_save {
        let path = directory.join("export.pdf");
        let mut file = fs::File::create(&path).map_err(io_error)?;
        file.write_all(&pdf.finish()).map_err(io_error)?;
        Some((path, "application/pdf"))
    } else if !params.preview {
        zip.finish()?;
        let path = directory.join("export.zip");
        fs::rename(directory.join("export.zip.partial"), &path).map_err(io_error)?;
        Some((path, "application/zip"))
    } else {
        None
    };
    let mut state = task.lock().map_err(io_error)?;
    cancel.check()?;
    if let Some((path, mime)) = result {
        state.result = Some(path);
        state.content_type = mime.into();
    } else {
        state.content_type = "image/png".into();
    }
    let _ = fs::remove_file(directory.join("export.zip.partial"));
    Ok(())
}
