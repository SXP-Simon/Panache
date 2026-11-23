//! 2026-10-12：兼容 Flutter HTTP API 的独立 Rust 服务。
mod access;
mod render_job;
mod tasks;
use axum::{
    Form, Json, Router,
    body::Body,
    extract::{
        DefaultBodyLimit, FromRequest, Multipart, Path, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, HeaderValue, Request, StatusCode},
    middleware,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use futures_util::Stream;
use handwriting_core::{
    Error, Limits, Parameters, Result, document, imaging,
    local_fonts::{FontPage, FontSearch, LocalFonts},
};
use std::{
    collections::HashMap,
    path::PathBuf,
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};
use tasks::Store;
use tokio::{io::AsyncRead, sync::Semaphore};
use tokio_util::io::ReaderStream;
use tower_http::services::{ServeDir, ServeFile};

#[derive(Clone)]
pub struct Config {
    pub desktop: bool,
    pub data_dir: PathBuf,
    pub font_dir: PathBuf,
    pub web_dir: Option<PathBuf>,
    pub allowed_origins: Vec<String>,
    pub access_token: Option<String>,
    pub version: String,
    pub limits: Limits,
    pub concurrency: usize,
    pub max_active: usize,
    pub ttl_seconds: f64,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            desktop: false,
            data_dir: PathBuf::from(".handwriting-rust"),
            font_dir: PathBuf::from("assets/font_assets"),
            web_dir: None,
            allowed_origins: vec!["http://127.0.0.1:5006".into()],
            access_token: None,
            version: handwriting_core::app_version().into(),
            limits: Limits::default(),
            concurrency: 2,
            max_active: 8,
            ttl_seconds: 1800.,
        }
    }
}
struct App {
    config: Config,
    store: Mutex<Store>,
    semaphore: Arc<Semaphore>,
    fonts: Vec<String>,
    font_cache: Mutex<HashMap<String, Arc<fontdue::Font>>>,
    local_fonts: Option<LocalFonts>,
    rates: Mutex<HashMap<String, (Instant, u32)>>,
}
#[derive(Clone)]
pub struct Server(Arc<App>);
fn storage_error(e: impl std::fmt::Display) -> Error {
    Error::new("storage_failed", e.to_string())
}
struct ApiError(Error);
impl From<Error> for ApiError {
    fn from(e: Error) -> Self {
        Self(e)
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self.0.code {
            "task_not_found" => StatusCode::NOT_FOUND,
            "queue_full" => StatusCode::SERVICE_UNAVAILABLE,
            "task_running" => StatusCode::CONFLICT,
            "task_failed" | "storage_failed" | "worker_failed" => StatusCode::INTERNAL_SERVER_ERROR,
            "cancelled" => StatusCode::CONFLICT,
            "upload_limit" | "archive_limit" | "image_limit" | "text_limit" | "page_limit" => {
                StatusCode::PAYLOAD_TOO_LARGE
            }
            _ => StatusCode::BAD_REQUEST,
        };
        let mut body = serde_json::json!({"status":if self.0.code=="queue_full" {"queue_full"} else {"error"},"error_code":self.0.code,"message":self.0.message});
        if self.0.code == "queue_full" {
            body["estimated_wait_seconds"] = serde_json::json!(60);
        }
        (status, Json(body)).into_response()
    }
}
type ApiResult<T> = std::result::Result<T, ApiError>;
impl Server {
    pub fn new(mut config: Config) -> Result<Self> {
        if (config.desktop && config.access_token.as_ref().is_none_or(|t| t.len() < 32))
            || config.concurrency == 0
            || config.max_active < config.concurrency
            || config.allowed_origins.is_empty()
            || config.allowed_origins.iter().any(|o| {
                url::Url::parse(o).map_or(true, |u| {
                    !matches!(u.scheme(), "http" | "https")
                        || u.origin().ascii_serialization() != *o
                })
            })
            || config.limits.max_pixels == 0
            || config.limits.max_pages == 0
            || config.limits.max_file_bytes == 0
            || config.limits.max_archive_bytes == 0
            || config.limits.max_text_chars == 0
            || !config.ttl_seconds.is_finite()
            || config.ttl_seconds <= 0.
        {
            return Err(Error::new("invalid_config", "无效的服务配置"));
        }
        std::fs::create_dir_all(&config.data_dir).map_err(storage_error)?;
        config.data_dir = std::fs::canonicalize(&config.data_dir).map_err(storage_error)?;
        config.font_dir = std::fs::canonicalize(&config.font_dir).map_err(storage_error)?;
        if let Some(dir) = &config.web_dir
            && !dir.join("index.html").is_file()
        {
            return Err(Error::new("invalid_config", "Web 目录必须包含 index.html"));
        }
        let mut fonts: Vec<_> = std::fs::read_dir(&config.font_dir)
            .map_err(storage_error)?
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|s| s.ends_with(".ttf") || s.ends_with(".otf") || s.ends_with(".ttc"))
            .collect();
        fonts.sort();
        if fonts.is_empty() {
            return Err(Error::new("invalid_config", "未找到默认字体"));
        }
        let store = Store::open(&config.data_dir, config.ttl_seconds)?;
        let concurrency = config.concurrency;
        let local_fonts = config
            .desktop
            .then(|| LocalFonts::new(Vec::new(), config.limits.max_file_bytes));
        Ok(Self(Arc::new(App {
            local_fonts,
            config,
            store: Mutex::new(store),
            semaphore: Arc::new(Semaphore::new(concurrency)),
            fonts,
            font_cache: Mutex::new(HashMap::new()),
            rates: Mutex::new(HashMap::new()),
        })))
    }
    pub fn router(&self) -> Router {
        let mut api = Router::new()
            .route("/health", get(health))
            .route("/fonts_info", get(fonts))
            .route("/version", get(version))
            .route("/textfileprocess", post(textfile))
            .route("/imagefileprocess", post(imagefile))
            .route("/pdfpageprocess", post(pdfpage))
            .route("/generate_handwriting", post(submit))
            .route("/generate_handwriting/task/{id}", get(status))
            .route("/generate_handwriting/task/{id}/result", get(result))
            .route("/generate_handwriting/task/{id}/cancel", post(cancel))
            .route("/generate_handwriting/ws/{id}", get(websocket))
            .fallback(|| async { StatusCode::NOT_FOUND });
        if self.0.local_fonts.is_some() {
            api = api
                .route("/local_fonts", post(local_fonts))
                .route("/local_fonts/read", post(read_local_font));
        }
        let mut app = Router::new().nest("/api", api);
        if let Some(dir) = &self.0.config.web_dir {
            app = app.fallback_service(
                ServeDir::new(dir).fallback(ServeFile::new(dir.join("index.html"))),
            );
        }
        app.layer(DefaultBodyLimit::max(
            self.0.config.limits.max_file_bytes.saturating_mul(3),
        ))
        .layer(middleware::from_fn_with_state(
            self.clone(),
            access::boundary,
        ))
        .with_state(self.clone())
    }
    pub fn cancel_active(&self) {
        let mut store = self.0.store.lock().unwrap();
        let ids: Vec<_> = store
            .tasks
            .iter()
            .filter(|(_, r)| r.task.active())
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            store.tasks[&id].cancellation.cancel();
            if let Err(e) = store.update(&id, |t| {
                t.task_status = if t.task_status == "pending" {
                    "cancelled"
                } else {
                    "cancelling"
                }
                .into();
                t.task_stage = t.task_status.clone();
                t.error_code = Some("cancelled".into());
                t.task_message = "服务关闭，任务已取消".into();
            }) {
                tracing::error!("取消任务失败：{e}");
            }
        }
    }
    pub fn start_cleanup(&self) -> tokio::task::JoinHandle<()> {
        let weak = Arc::downgrade(&self.0);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(30));
            loop {
                interval.tick().await;
                let Some(app) = weak.upgrade() else {
                    break;
                };
                if let Err(e) = app.store.lock().unwrap().cleanup() {
                    tracing::error!("任务清理失败：{e}");
                }
            }
        })
    }
    fn update(&self, id: &str, change: impl FnOnce(&mut tasks::Task)) -> Result<()> {
        self.0.store.lock().unwrap().update(id, change)
    }
}
async fn health() -> Json<serde_json::Value> {
    Json(
        serde_json::json!({"status":"ok","engine_name":handwriting_core::ENGINE_NAME,"rendering_available":true,"algorithm_version":handwriting_core::ALGORITHM_VERSION}),
    )
}
async fn fonts(State(s): State<Server>) -> Json<Vec<String>> {
    Json(s.0.fonts.clone())
}
async fn local_fonts(
    State(s): State<Server>,
    Json(query): Json<FontSearch>,
) -> ApiResult<Json<FontPage>> {
    let page =
        tokio::task::spawn_blocking(move || s.0.local_fonts.as_ref().unwrap().search(&query))
            .await
            .map_err(storage_error)??;
    Ok(Json(page))
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FontId {
    id: String,
}
async fn read_local_font(
    State(s): State<Server>,
    Json(request): Json<FontId>,
) -> ApiResult<Vec<u8>> {
    let (_, bytes) =
        tokio::task::spawn_blocking(move || s.0.local_fonts.as_ref().unwrap().read(&request.id))
            .await
            .map_err(storage_error)??;
    Ok(bytes)
}
async fn version(State(s): State<Server>) -> Json<serde_json::Value> {
    Json(
        serde_json::json!({"version":s.0.config.version,"capabilities":{"local_fonts":s.0.local_fonts.is_some(),"task_cancellation":true,"task_submission_id":true,"fine_edit":true}}),
    )
}
struct Upload {
    name: String,
    bytes: Vec<u8>,
}
async fn multipart(
    mut multipart: Multipart,
    limits: &Limits,
) -> ApiResult<(HashMap<String, String>, HashMap<String, Upload>)> {
    let mut fields = HashMap::new();
    let mut files = HashMap::new();
    let mut count = 0;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError(Error::new("invalid_upload", e.to_string())))?
    {
        count += 1;
        if count > 64 {
            return Err(Error::new("upload_limit", "表单字段过多").into());
        }
        let key = field.name().unwrap_or("").to_string();
        let name = field.file_name().map(str::to_owned);
        if fields.contains_key(&key) || files.contains_key(&key) {
            return Err(Error::new("invalid_upload", "表单字段重复").into());
        }
        let bytes = field
            .bytes()
            .await
            .map_err(|e| ApiError(Error::new("invalid_upload", e.to_string())))?;
        if bytes.len() > limits.max_file_bytes {
            return Err(Error::new("upload_limit", "上传文件过大").into());
        }
        if let Some(name) = name {
            files.insert(
                key,
                Upload {
                    name,
                    bytes: bytes.to_vec(),
                },
            );
        } else {
            fields.insert(
                key,
                String::from_utf8(bytes.to_vec())
                    .map_err(|_| ApiError(Error::new("invalid_upload", "表单必须使用 UTF-8")))?,
            );
        }
    }
    Ok((fields, files))
}
struct Input(HashMap<String, String>, HashMap<String, Upload>);
impl FromRequest<Server> for Input {
    type Rejection = ApiError;
    async fn from_request(request: Request<Body>, state: &Server) -> ApiResult<Self> {
        if header(request.headers(), "content-type")
            .is_some_and(|v| v.split(';').next() == Some("application/x-www-form-urlencoded"))
        {
            let Form(fields) = Form::<HashMap<String, String>>::from_request(request, state)
                .await
                .map_err(|e| Error::new("invalid_upload", e.to_string()))?;
            if fields.len() > 64 {
                return Err(Error::new("upload_limit", "表单字段过多").into());
            }
            Ok(Self(fields, HashMap::new()))
        } else {
            let form = Multipart::from_request(request, state)
                .await
                .map_err(|e| Error::new("invalid_upload", e.to_string()))?;
            let (fields, files) = multipart(form, &state.0.config.limits).await?;
            Ok(Self(fields, files))
        }
    }
}
async fn submit(
    State(s): State<Server>,
    headers: HeaderMap,
    Input(fields, files): Input,
) -> ApiResult<Json<serde_json::Value>> {
    let id = match headers.get("X-Panache-Task-Id") {
        Some(value) => {
            let value = value
                .to_str()
                .map_err(|_| Error::new("invalid_parameter", "任务 ID 无效"))?;
            if !canonical_task_id(value) {
                return Err(Error::new("invalid_parameter", "任务 ID 无效").into());
            }
            value.to_owned()
        }
        None => uuid::Uuid::new_v4().simple().to_string(),
    };
    let response = || Json(serde_json::json!({"status":"accepted","task_id":id}));
    {
        let mut store = s.0.store.lock().unwrap();
        store.cleanup()?;
        if store.tasks.contains_key(&id) {
            return Ok(response());
        }
    }
    Parameters::from_form(&fields)?;
    let text = fields
        .get("text")
        .ok_or_else(|| Error::new("invalid_parameter", "缺少 text"))?;
    handwriting_core::validate_document(text, &s.0.config.limits)?;
    let token = {
        // 2026-10-24：上传期间的取消墓碑与并发重试都不能重新启动同一任务。
        let mut store = s.0.store.lock().unwrap();
        if store.tasks.contains_key(&id) {
            return Ok(response());
        }
        store.insert(id.clone(), s.0.config.max_active)?
    };
    let task_id = id.clone();
    tokio::spawn(async move {
        let acquire = s.0.semaphore.clone().acquire_owned();
        tokio::pin!(acquire);
        let permit = loop {
            tokio::select! {
                permit = &mut acquire => break permit,
                _ = tokio::time::sleep(Duration::from_millis(50)) => {
                    if token.check().is_err() { return; }
                }
            }
        };
        if permit.is_err() {
            return;
        }
        {
            // 2026-10-24：启动与取消共用锁；pending 取消后不会启动阻塞工作线程。
            let mut store = s.0.store.lock().unwrap();
            if token.check().is_err() {
                return;
            }
            if store
                .update(&task_id, |t| t.task_status = "processing".into())
                .is_err()
            {
                return;
            }
        }
        let worker = s.clone();
        let worker_id = task_id.clone();
        let result =
            tokio::task::spawn_blocking(move || worker.run(&worker_id, fields, files, token))
                .await
                .unwrap_or_else(|e| Err(Error::new("worker_failed", e.to_string())));
        // 2026-10-24：阻塞任务退出并释放工作槽后，才发布取消终态。
        drop(permit);
        if let Err(error) = result {
            let _ = s.update(&task_id, |t| {
                if t.active() {
                    t.task_status = if error.code == "cancelled" {
                        "cancelled"
                    } else {
                        "failed"
                    }
                    .into();
                    t.task_stage = t.task_status.clone();
                    t.error_code = Some(error.code.into());
                    t.error_message = Some(error.message.clone());
                    t.task_message = error.message;
                }
            });
        }
    });
    Ok(Json(serde_json::json!({"status":"accepted","task_id":id})))
}
async fn status(
    State(s): State<Server>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let mut store = s.0.store.lock().unwrap();
    store.cleanup()?;
    Ok(Json(store.payload(&id).ok_or_else(|| {
        Error::new("task_not_found", "任务不存在")
    })?))
}
fn canonical_task_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}

async fn cancel(
    State(s): State<Server>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let mut store = s.0.store.lock().unwrap();
    if !store.tasks.contains_key(&id) && canonical_task_id(&id) {
        // 2026-10-24：客户端已知 ID 时可先取消，阻止迟到上传在后台开始渲染。
        store.insert(id.clone(), usize::MAX)?;
    }
    let runtime = store
        .tasks
        .get(&id)
        .ok_or_else(|| Error::new("task_not_found", "任务不存在"))?;
    if runtime.task.active() {
        runtime.cancellation.cancel();
        store.update(&id, |t| {
            let pending = t.task_status == "pending";
            t.task_status = if pending { "cancelled" } else { "cancelling" }.into();
            t.task_stage = t.task_status.clone();
            t.task_message = if pending {
                "任务已取消"
            } else {
                "正在停止任务"
            }
            .into();
            t.error_code = Some("cancelled".into());
        })?;
    }
    Ok(Json(store.payload(&id).unwrap()))
}
struct Lease(Arc<AtomicUsize>);
impl Drop for Lease {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}
struct Download<R> {
    reader: ReaderStream<R>,
    _lease: Lease,
}
impl<R: AsyncRead + Unpin> Stream for Download<R> {
    type Item = std::result::Result<axum::body::Bytes, std::io::Error>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.get_mut().reader).poll_next(cx)
    }
}
async fn result(State(s): State<Server>, Path(id): Path<String>) -> ApiResult<Response> {
    let (task, lease) = {
        let mut store = s.0.store.lock().unwrap();
        store.cleanup()?;
        let runtime = store
            .tasks
            .get(&id)
            .ok_or_else(|| Error::new("task_not_found", "任务不存在"))?;
        match runtime.task.task_status.as_str() {
            "pending" | "processing" => {
                return Err(Error::new("task_running", "任务仍在运行").into());
            }
            "failed" => {
                return Err(Error::new(
                    "task_failed",
                    runtime.task.error_message.clone().unwrap_or_default(),
                )
                .into());
            }
            "cancelled" => return Err(Error::new("cancelled", "任务已取消").into()),
            _ => (),
        }
        runtime.downloads.fetch_add(1, Ordering::AcqRel);
        (runtime.task.clone(), Lease(runtime.downloads.clone()))
    };
    let file = tokio::fs::File::open(
        task.result_file
            .ok_or_else(|| Error::new("storage_failed", "结果文件缺失"))?,
    )
    .await
    .map_err(storage_error)?;
    let mut response = Body::from_stream(Download {
        reader: ReaderStream::new(file),
        _lease: lease,
    })
    .into_response();
    response.headers_mut().insert(
        "content-type",
        HeaderValue::from_str(
            task.content_type
                .as_deref()
                .unwrap_or("application/octet-stream"),
        )
        .unwrap(),
    );
    if let Some(name) = task.filename {
        response.headers_mut().insert(
            "content-disposition",
            HeaderValue::from_str(&format!("attachment; filename={name}")).unwrap(),
        );
    }
    Ok(response)
}
async fn textfile(
    State(s): State<Server>,
    Input(_, mut files): Input,
) -> ApiResult<Json<serde_json::Value>> {
    let file = files
        .remove("file")
        .ok_or_else(|| Error::new("invalid_upload", "缺少 file"))?;
    let limits = s.0.config.limits.clone();
    let _permit =
        s.0.semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::new("queue_full", "工作线程繁忙，请稍后重试"))?;
    let text =
        tokio::task::spawn_blocking(move || document::extract(&file.name, &file.bytes, &limits))
            .await
            .map_err(|e| Error::new("worker_failed", e.to_string()))??;
    Ok(Json(serde_json::json!({"text":text})))
}
async fn pdfpage(
    State(s): State<Server>,
    Input(fields, mut files): Input,
) -> ApiResult<Json<handwriting_core::pdf_page::PdfPage>> {
    let file = files
        .remove("file")
        .ok_or_else(|| Error::new("invalid_upload", "缺少 file"))?;
    let limits = s.0.config.limits.clone();
    let permit =
        s.0.semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::new("queue_full", "工作线程繁忙，请稍后重试"))?;
    let page = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        handwriting_core::pdf_page::import(file.bytes, &fields, &limits)
    })
    .await
    .map_err(|e| Error::new("worker_failed", e.to_string()))??;
    Ok(Json(page))
}
async fn imagefile(
    State(s): State<Server>,
    Input(_, mut files): Input,
) -> ApiResult<Json<imaging::Identification>> {
    let file = files
        .remove("file")
        .ok_or_else(|| Error::new("invalid_upload", "缺少 file"))?;
    let limits = s.0.config.limits.clone();
    let _permit =
        s.0.semaphore
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::new("queue_full", "工作线程繁忙，请稍后重试"))?;
    let identification = tokio::task::spawn_blocking(move || {
        imaging::identify_paper(&imaging::decode(&file.bytes, &limits)?, &file.bytes)
    })
    .await
    .map_err(|e| Error::new("worker_failed", e.to_string()))??;
    Ok(Json(identification))
}
async fn websocket(
    State(s): State<Server>,
    Path(id): Path<String>,
    upgrade: WebSocketUpgrade,
) -> ApiResult<Response> {
    let receiver =
        s.0.store
            .lock()
            .unwrap()
            .tasks
            .get(&id)
            .ok_or_else(|| Error::new("task_not_found", "任务不存在"))?
            .sender
            .subscribe();
    Ok(upgrade.on_upgrade(move |socket| socket_updates(socket, s, id, receiver)))
}
async fn socket_updates(
    mut socket: WebSocket,
    s: Server,
    id: String,
    mut receiver: tokio::sync::watch::Receiver<tasks::Task>,
) {
    loop {
        let payload = s.0.store.lock().unwrap().payload(&id);
        let Some(payload) = payload else {
            return;
        };
        if socket
            .send(Message::Text(payload.to_string().into()))
            .await
            .is_err()
        {
            return;
        }
        if !receiver.borrow_and_update().active() {
            return;
        }
        tokio::select! {changed=receiver.changed()=>if changed.is_err(){return;},message=socket.recv()=>if matches!(message,None|Some(Err(_))|Some(Ok(Message::Close(_)))){return;}}
    }
}
fn header<'a>(h: &'a HeaderMap, name: &str) -> Option<&'a str> {
    h.get(name).and_then(|v| v.to_str().ok())
}
#[cfg(test)]
mod tests;
