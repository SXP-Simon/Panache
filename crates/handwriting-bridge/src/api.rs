mod worker;
use handwriting_core::{Cancellation, Error, Limits, Result, document, imaging};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
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
    task_stage: String,
    pages_completed: usize,
    error_message: Option<String>,
    error_code: Option<String>,
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
        "paper_camera" => {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let file = request
                .files
                .get("file")
                .ok_or_else(|| Error::new("invalid_upload", "缺少文件"))?;
            let source = fs::File::open(&file.path).map_err(io_error)?;
            if source.metadata().map_err(io_error)?.len() > 64 * 1024 * 1024 {
                return Err(Error::new("upload_limit", "底纸照片过大"));
            }
            let camera = handwriting_core::export::CameraMetadata::from_reader(
                Some(std::io::BufReader::new(source)),
                &Default::default(),
            )?;
            Ok(json!(STANDARD.encode(camera.exif())))
        }
        "fonts" => Ok(json!(fonts(&request.font_dir)?)),
        "license" => Ok(json!(concat!(
            include_str!("../../handwriting-core/NOTICE"),
            "\n",
            include_str!("../../handwriting-core/licenses/handright-LICENSE.txt")
        ))),
        "version" => Ok(
            json!({"version": handwriting_core::app_version(), "capabilities": {"export_blur": true, "fine_edit": true}}),
        ),
        "import" | "identify" | "pdf_page" => {
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
            if request.command == "pdf_page" {
                serde_json::to_value(handwriting_core::pdf_page::import(
                    bytes,
                    &request.fields,
                    &limits(),
                )?)
                .map_err(io_error)
            } else if request.command == "import" {
                Ok(json!({"text":document::extract(&upload.name, &bytes, &limits())?}))
            } else {
                let detected =
                    imaging::identify_paper(&imaging::decode(&bytes, &limits())?, &bytes)?;
                serde_json::to_value(detected).map_err(io_error)
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
        task_stage: "preparing".into(),
        pages_completed: 0,
        error_message: None,
        error_code: None,
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
        .spawn(move || worker::run(request, &worker))
    {
        registry.remove(&id);
        let _ = fs::remove_dir_all(&task.lock().map_err(io_error)?.directory);
        return Err(io_error(error));
    }
    Ok(json!({"task_id":id}))
}
