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
#[cfg(test)]
use handwriting_core::export;
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
mod tests {
    use super::*;
    use axum::http::Request;
    use tower::ServiceExt;
    fn setup() -> (tempfile::TempDir, Server) {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::new(Config {
            data_dir: dir.path().into(),
            font_dir: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets"),
            ..Config::default()
        })
        .unwrap();
        (dir, server)
    }
    fn form(fields: &[(&str, &str)], file: Option<(&str, &str, &[u8])>) -> (String, Vec<u8>) {
        let boundary = "RustHandwritingTestBoundary";
        let mut body = Vec::new();
        for (key, value) in fields {
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n").as_bytes());
        }
        if let Some((key, name, bytes)) = file {
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n").as_bytes());
            body.extend_from_slice(bytes);
            body.extend_from_slice(b"\r\n");
        }
        body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());
        (format!("multipart/form-data; boundary={boundary}"), body)
    }
    async fn call(s: &Server, path: &str) -> (StatusCode, Vec<u8>) {
        let r = s
            .router()
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = r.status();
        let body = axum::body::to_bytes(r.into_body(), 32 * 1024 * 1024)
            .await
            .unwrap();
        (status, body.to_vec())
    }
    async fn send(
        s: &Server,
        path: &str,
        fields: &[(&str, &str)],
        file: Option<(&str, &str, &[u8])>,
    ) -> (StatusCode, serde_json::Value) {
        let (content_type, body) = form(fields, file);
        let response = s
            .router()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("content-type", content_type)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        (status, serde_json::from_slice(&body).unwrap())
    }
    async fn generate(s: &Server, extra: &[(&str, &str)]) -> String {
        let mut fields = vec![
            ("text", "第一页\n---\n第二页"),
            ("font_option", "霞鹜文楷.ttf"),
            ("font_size", "24"),
            ("line_spacing", "36"),
            ("width", "240"),
            ("height", "180"),
            ("left_margin", "10"),
            ("right_margin", "10"),
            ("top_margin", "10"),
            ("bottom_margin", "10"),
            ("strikethrough_probability", "0"),
        ];
        for &(key, value) in extra {
            if let Some(field) = fields.iter_mut().find(|(name, _)| *name == key) {
                field.1 = value;
            } else {
                fields.push((key, value));
            }
        }
        let (status, json) = send(s, "/api/generate_handwriting", &fields, None).await;
        assert_eq!(status, StatusCode::OK, "{json}");
        let id = json["task_id"].as_str().unwrap().to_string();
        let path = format!("/api/generate_handwriting/task/{id}");
        // 2026-11-17：共享 Windows CI 运行器并行加载字体和渲染时可能超过 10 秒。
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let (_, data) = call(s, &path).await;
                let state: serde_json::Value = serde_json::from_slice(&data).unwrap();
                match state["task_status"].as_str() {
                    Some("completed") => break,
                    Some("pending" | "processing") => {}
                    _ => panic!("任务 {id} 意外结束：{state}"),
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("任务 {id} 超时，生成参数：{extra:?}"));
        id
    }
    mod image_support {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../handwriting-core/tests/support/images.rs"
        ));
    }
    #[tokio::test]
    async fn photo_payload_is_accepted_but_body_limit_is_preserved() {
        let (_dir, s) = setup();
        let document = image_support::image_document();
        let id = generate(&s, &[("text", &document)]).await;
        let (status, bytes) =
            call(&s, &format!("/api/generate_handwriting/task/{id}/result")).await;
        assert_eq!(status, StatusCode::OK);
        assert!(!bytes.is_empty());
        let (status, error) = send(
            &s,
            "/api/generate_handwriting",
            &[("text", &"字".repeat(100_001))],
            None,
        )
        .await;
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(error["error_code"], "text_limit");
    }
    #[tokio::test]
    async fn cors_preflight_and_urlencoded_legacy_forms() {
        let (_dir, s) = setup();
        let response = s
            .router()
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri("/api/generate_handwriting")
                    .header("origin", "http://127.0.0.1:5006")
                    .header("access-control-request-method", "POST")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        assert_eq!(
            response.headers()["access-control-allow-origin"],
            "http://127.0.0.1:5006"
        );
        let response = s
            .router()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/generate_handwriting")
                    .header("content-type", "application/x-www-form-urlencoded")
                    .body(Body::from("text=Hello&font_option=missing.ttf"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let data = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let data: serde_json::Value = serde_json::from_slice(&data).unwrap();
        let id = data["task_id"].as_str().unwrap();
        for _ in 0..100 {
            let task = s.0.store.lock().unwrap().tasks[id].task.clone();
            if !task.active() {
                assert_eq!(task.error_code.as_deref(), Some("invalid_font"));
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("任务超时");
    }
    #[tokio::test]
    async fn websocket_delivers_initial_and_terminal_status_over_network() {
        use futures_util::StreamExt;
        let (_dir, s) = setup();
        s.0.store
            .lock()
            .unwrap()
            .insert("socket-task".into(), 8)
            .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut cfg = s.0.config.clone();
        cfg.allowed_origins = vec![format!("http://{address}")];
        let s = Server::new(cfg).unwrap();
        // 重启后的任务显式中断；新任务验证实时推送。
        s.0.store
            .lock()
            .unwrap()
            .insert("live-task".into(), 8)
            .unwrap();
        let app = s.router();
        let service = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let (mut socket, _) = tokio_tungstenite::connect_async(format!(
            "ws://{address}/api/generate_handwriting/ws/live-task"
        ))
        .await
        .unwrap();
        let first = tokio::time::timeout(Duration::from_secs(2), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let payload: serde_json::Value = serde_json::from_str(first.to_text().unwrap()).unwrap();
        assert_eq!(payload["task_status"], "pending");
        s.update("live-task", |t| {
            t.task_status = "cancelled".into();
        })
        .unwrap();
        let last = tokio::time::timeout(Duration::from_secs(2), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let payload: serde_json::Value = serde_json::from_str(last.to_text().unwrap()).unwrap();
        assert_eq!(payload["task_status"], "cancelled");
        socket.close(None).await.unwrap();
        service.abort();
    }
    #[tokio::test]
    async fn local_fonts_require_authenticated_desktop_sidecar() {
        let (_dir, hosted) = setup();
        let uri = "/api/local_fonts";
        let post = || {
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap()
        };
        let hosted_version: serde_json::Value =
            serde_json::from_slice(&call(&hosted, "/api/version").await.1).unwrap();
        assert_eq!(hosted_version["capabilities"]["local_fonts"], false);
        assert_eq!(
            hosted.router().oneshot(post()).await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
        let mut config = hosted.0.config.clone();
        config.desktop = true;
        assert!(Server::new(config.clone()).is_err());
        config.access_token = Some("x".repeat(32));
        let desktop = Server::new(config).unwrap();
        assert_eq!(
            desktop.router().oneshot(post()).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        let mut foreign = post();
        foreign.headers_mut().insert(
            "origin",
            HeaderValue::from_static("https://elsewhere.example"),
        );
        assert_eq!(
            desktop.router().oneshot(foreign).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    #[tokio::test]
    async fn static_health_fonts_version_and_unknown_api() {
        let (dir, s) = setup();
        let (status, health) = call(&s, "/api/health").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&health).unwrap()["rendering_available"],
            true
        );
        assert_eq!(call(&s, "/api/missing").await.0, StatusCode::NOT_FOUND);
        let fonts: Vec<String> =
            serde_json::from_slice(&call(&s, "/api/fonts_info").await.1).unwrap();
        assert!(fonts.contains(&"霞鹜文楷.ttf".into()));
        assert_eq!(call(&s, "/api/version").await.0, StatusCode::OK);
        std::fs::write(dir.path().join("index.html"), "<html>Flutter</html>").unwrap();
        let mut cfg = s.0.config.clone();
        cfg.web_dir = Some(dir.path().into());
        let s = Server::new(cfg).unwrap();
        assert_eq!(call(&s, "/workspace").await.0, StatusCode::OK);
        assert_eq!(call(&s, "/api/missing").await.0, StatusCode::NOT_FOUND);
    }
    #[tokio::test]
    async fn real_generation_preview_pdf_zip_and_idempotent_download() {
        let (_dir, s) = setup();
        for (extra, content_type, attachment) in [
            (
                vec![("preview", "true"), ("full_preview", "false")],
                "image/png",
                None,
            ),
            (
                vec![("preview", "true"), ("full_preview", "true")],
                "application/json",
                None,
            ),
            (
                vec![
                    ("preview", "true"),
                    ("full_preview", "false"),
                    ("ink_layers", "true"),
                ],
                "application/json",
                None,
            ),
            (
                vec![("pdf_save", "true")],
                "application/pdf",
                Some("attachment; filename=images.pdf"),
            ),
            (
                vec![("preview", "false")],
                "application/zip",
                Some("attachment; filename=images.zip"),
            ),
        ] {
            let id = generate(&s, &extra).await;
            let (_, state) = call(&s, &format!("/api/generate_handwriting/task/{id}")).await;
            let state: serde_json::Value = serde_json::from_slice(&state).unwrap();
            assert_eq!(state["task_stage"], "completed");
            assert_eq!(
                state["pages_completed"],
                if extra.contains(&("full_preview", "false")) {
                    1
                } else {
                    2
                }
            );
            let path = format!("/api/generate_handwriting/task/{id}/result");
            let response = s
                .router()
                .oneshot(Request::builder().uri(&path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(response.headers()["content-type"], content_type);
            assert_eq!(
                header(response.headers(), "content-disposition"),
                attachment
            );
            let bytes = axum::body::to_bytes(response.into_body(), 32 * 1024 * 1024)
                .await
                .unwrap();
            assert_eq!(bytes.as_ref(), call(&s, &path).await.1.as_slice());
            if extra.contains(&("pdf_save", "true")) {
                assert!(bytes.starts_with(b"%PDF-"));
            } else if extra.contains(&("preview", "false")) {
                assert!(bytes.starts_with(b"PK"));
            } else if extra.contains(&("ink_layers", "true")) {
                let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                let layers = data["layers"].as_array().unwrap();
                assert_eq!(layers.len(), 1);
                for kind in ["paper", "ink"] {
                    assert!(layers[0][kind].as_str().unwrap().starts_with("iVBORw0KGgo"));
                }
            } else if extra.contains(&("full_preview", "false")) {
                assert!(bytes.starts_with(b"\x89PNG"));
            } else {
                let data: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(data["images"].as_array().unwrap().len(), 2);
            }
        }
    }
    #[tokio::test]
    async fn imports_selected_pdf_page() {
        let (_dir, s) = setup();
        let mut pdf = export::PdfExport::new();
        pdf.add(&image_for_test()).unwrap();
        let bytes = pdf.finish();
        let (status, data) = send(
            &s,
            "/api/pdfpageprocess",
            &[("pageIndex", "0"), ("mode", "fill")],
            Some(("file", "paper.pdf", &bytes)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{data}");
        assert_eq!(data["pageCount"], 1);
        assert_eq!(data["pageIndex"], 0);
        assert!(data["backgroundPng"].as_str().unwrap().starts_with("iVBOR"));
        let (status, data) = send(
            &s,
            "/api/pdfpageprocess",
            &[("pageIndex", "1")],
            Some(("file", "paper.pdf", &bytes)),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(data["error_code"], "invalid_parameter");
    }
    #[tokio::test]
    async fn uploads_text_and_background_identification() {
        let (_dir, s) = setup();
        let (status, data) = send(
            &s,
            "/api/textfileprocess",
            &[],
            Some(("file", "t.txt", "你好 Rust".as_bytes())),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(data["text"], "你好 Rust");
        let mut image = image_for_test();
        let bytes = export::png(&image).unwrap();
        let (status, data) = send(
            &s,
            "/api/imagefileprocess",
            &[],
            Some(("file", "page.png", &bytes)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{data}");
        assert_eq!(data["lineSpacing"], 40);
        let tilted = image::RgbaImage::from_fn(400, 500, |x, y| {
            let line = (50..420)
                .step_by(60)
                .any(|row| y >= row + x / 20 && y < row + x / 20 + 4);
            let shade = if line && (30..370).contains(&x) {
                220
            } else {
                245
            };
            image::Rgba([shade, shade, shade, 255])
        });
        let bytes = export::png(&tilted).unwrap();
        let expected = imaging::identify(&image::DynamicImage::ImageRgba8(tilted)).unwrap();
        let (status, data) = send(
            &s,
            "/api/imagefileprocess",
            &[],
            Some(("file", "tilted.png", &bytes)),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let wire_expected: serde_json::Value =
            serde_json::from_slice(&serde_json::to_vec(&expected).unwrap()).unwrap();
        assert_eq!(data, wire_expected);
        assert!(data["correctedBackground"].as_str().unwrap().len() > 100);
        image.fill(255);
        let bytes = export::png(&image).unwrap();
        let (status, data) = send(
            &s,
            "/api/imagefileprocess",
            &[],
            Some(("file", "blank.png", &bytes)),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(data["error_code"], "identification_unreliable");
    }
    fn image_for_test() -> image::RgbaImage {
        let mut image = image::RgbaImage::from_pixel(300, 400, image::Rgba([255, 255, 255, 255]));
        for y in (40..360).step_by(40) {
            for yy in y..y + 4 {
                for x in 30..270 {
                    image[(x, yy)] = image::Rgba([0, 0, 0, 255]);
                }
            }
        }
        image
    }
    #[tokio::test]
    async fn origin_host_and_auth_apply_to_http_and_websocket() {
        let (_dir, s) = setup();
        for (name, value) in [
            ("origin", "https://evil.example"),
            ("referer", "https://evil.example/page"),
            ("sec-fetch-site", "cross-site"),
            ("host", "evil.example:5006"),
        ] {
            for path in [
                "/api/generate_handwriting",
                "/api/generate_handwriting/ws/id",
            ] {
                let response = s
                    .router()
                    .oneshot(
                        Request::builder()
                            .uri(path)
                            .header(name, value)
                            .body(Body::empty())
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), StatusCode::FORBIDDEN);
            }
        }
        let mut config = s.0.config.clone();
        config.access_token = Some("test-secret".into());
        let auth = Server::new(config).unwrap();
        assert_eq!(call(&auth, "/api/health").await.0, StatusCode::UNAUTHORIZED);
        for authorization in ["Bearer test-secret", "Basic dXNlcjp0ZXN0LXNlY3JldA=="] {
            let response = auth
                .router()
                .oneshot(
                    Request::builder()
                        .uri("/api/health")
                        .header("authorization", authorization)
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
        }
    }
    #[tokio::test]
    async fn cancellation_tombstone_blocks_late_and_duplicate_submissions() {
        let (_dir, s) = setup();
        let id = uuid::Uuid::new_v4().to_string();
        let (_, data) = send(
            &s,
            &format!("/api/generate_handwriting/task/{id}/cancel"),
            &[],
            None,
        )
        .await;
        assert_eq!(data["task_status"], "cancelled");
        for _ in 0..2 {
            let (content_type, body) = form(&[("text", "迟到上传")], None);
            let response = s
                .router()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/generate_handwriting")
                        .header("content-type", content_type)
                        .header("X-Panache-Task-Id", &id)
                        .body(Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let payload: serde_json::Value = serde_json::from_slice(
                &axum::body::to_bytes(response.into_body(), 4096)
                    .await
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(payload["task_id"], id);
        }
        let store = s.0.store.lock().unwrap();
        assert_eq!(store.tasks.len(), 1);
        assert_eq!(store.tasks[&id].task.task_status, "cancelled");
        assert_eq!(s.0.semaphore.available_permits(), 2);
        assert!(store.tasks[&id].task.result_file.is_none());
    }

    #[tokio::test]
    async fn stopping_task_keeps_queue_capacity_and_survives_cleanup() {
        let (_dir, s) = setup();
        {
            let mut store = s.0.store.lock().unwrap();
            store.insert("running".into(), 1).unwrap();
            store
                .update("running", |t| t.task_status = "processing".into())
                .unwrap();
        }
        for _ in 0..2 {
            let (code, data) = send(
                &s,
                "/api/generate_handwriting/task/running/cancel",
                &[],
                None,
            )
            .await;
            assert_eq!(code, StatusCode::OK);
            assert_eq!(data["task_status"], "cancelling");
            assert_eq!(data["active_task_count"], 1);
        }
        let mut store = s.0.store.lock().unwrap();
        store.ttl = 0.;
        store.cleanup().unwrap();
        assert!(store.tasks.contains_key("running"));
        assert_eq!(
            store.insert("next".into(), 1).unwrap_err().code,
            "queue_full"
        );
        assert!(store.tasks["running"].cancellation.check().is_err());
    }

    #[tokio::test]
    async fn queue_cancel_failure_restart_and_expiry() {
        let (_dir, s) = setup();
        {
            let mut store = s.0.store.lock().unwrap();
            for i in 0..8 {
                store.insert(format!("q{i}"), 8).unwrap();
            }
            assert_eq!(
                store.insert("overflow".into(), 8).unwrap_err().code,
                "queue_full"
            );
        }
        let path = "/api/generate_handwriting/task/q0";
        assert_eq!(
            call(&s, &format!("{path}/result")).await.0,
            StatusCode::CONFLICT
        );
        let (status, data) = send(&s, &format!("{path}/cancel"), &[], None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(data["task_status"], "cancelled");
        assert_eq!(
            call(&s, &format!("{path}/result")).await.0,
            StatusCode::CONFLICT
        );
        let config = s.0.config.clone();
        drop(s);
        let s = Server::new(config).unwrap();
        let data: serde_json::Value =
            serde_json::from_slice(&call(&s, "/api/generate_handwriting/task/q1").await.1).unwrap();
        assert_eq!(data["task_status"], "failed");
        assert_eq!(data["error_code"], "interrupted");
        {
            let mut store = s.0.store.lock().unwrap();
            store.ttl = 0.;
            store.cleanup().unwrap();
        }
        assert_eq!(call(&s, path).await.0, StatusCode::NOT_FOUND);
    }
    #[tokio::test]
    async fn persisted_results_survive_restart_and_download_lease_blocks_expiry() {
        let (_dir, s) = setup();
        let id = generate(&s, &[("preview", "true"), ("full_preview", "false")]).await;
        let path = format!("/api/generate_handwriting/task/{id}/result");
        let bytes = call(&s, &path).await.1;
        let cfg = s.0.config.clone();
        drop(s);
        let s = Server::new(cfg).unwrap();
        assert_eq!(call(&s, &path).await.1, bytes);
        let response = s
            .router()
            .oneshot(Request::builder().uri(&path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        {
            let mut store = s.0.store.lock().unwrap();
            store.ttl = 0.;
            store.cleanup().unwrap();
            assert!(store.tasks.contains_key(&id));
        }
        drop(response);
        s.0.store.lock().unwrap().cleanup().unwrap();
        assert_eq!(call(&s, &path).await.0, StatusCode::NOT_FOUND);
    }
    #[tokio::test]
    async fn pending_cancellation_releases_waiter_and_processing_cancellation_releases_worker() {
        let (_dir, s) = setup();
        generate(&s, &[("preview", "true"), ("full_preview", "false")]).await;
        let permits = s.0.semaphore.clone().acquire_many_owned(2).await.unwrap();
        let (code, data) = send(
            &s,
            "/api/generate_handwriting",
            &[("text", "pending")],
            None,
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        let id = data["task_id"].as_str().unwrap();
        let (_, data) = send(
            &s,
            &format!("/api/generate_handwriting/task/{id}/cancel"),
            &[],
            None,
        )
        .await;
        assert_eq!(data["task_status"], "cancelled");
        tokio::time::sleep(Duration::from_millis(80)).await;
        drop(permits);
        let text = "长任务取消测试".repeat(10_000);
        let (code, data) = send(
            &s,
            "/api/generate_handwriting",
            &[
                ("text", &text),
                ("width", "2480"),
                ("height", "3508"),
                ("font_option", "霞鹜文楷.ttf"),
                ("preview", "false"),
            ],
            None,
        )
        .await;
        assert_eq!(code, StatusCode::OK);
        let id = data["task_id"].as_str().unwrap();
        let mut processing = false;
        for _ in 0..200 {
            let task = s.0.store.lock().unwrap().tasks[id].task.clone();
            if task.task_status == "processing" {
                processing = true;
                break;
            }
            assert!(task.active(), "{task:?}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(processing);
        let (_, data) = send(
            &s,
            &format!("/api/generate_handwriting/task/{id}/cancel"),
            &[],
            None,
        )
        .await;
        assert_eq!(data["task_status"], "cancelling");
        for _ in 0..300 {
            let state = s.0.store.lock().unwrap().tasks[id].task.task_status.clone();
            if state == "cancelled" {
                break;
            }
            assert_eq!(state, "cancelling");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            s.0.store.lock().unwrap().tasks[id].task.task_status,
            "cancelled"
        );
        assert_eq!(s.0.semaphore.available_permits(), 2);
        let permits = tokio::time::timeout(
            Duration::from_secs(3),
            s.0.semaphore.clone().acquire_many_owned(2),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(
            !s.0.config
                .data_dir
                .join("results")
                .join(format!("{id}.partial"))
                .exists()
        );
        drop(permits);
    }
    #[tokio::test]
    async fn invalid_uploads_and_rate_limit() {
        let (_dir, s) = setup();
        let (_, data) = send(
            &s,
            "/api/generate_handwriting",
            &[("font_size", "invalid")],
            None,
        )
        .await;
        assert_eq!(data["error_code"], "invalid_parameter");
        let (_, data) = send(
            &s,
            "/api/textfileprocess",
            &[],
            Some(("file", "t.doc", b"bad")),
        )
        .await;
        assert_eq!(data["error_code"], "unsupported_document");
        for _ in 0..600 {
            call(&s, "/api/health").await;
        }
        let response = s
            .router()
            .oneshot(
                Request::builder()
                    .uri("/api/health")
                    .header("origin", "http://127.0.0.1:5006")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(
            response.headers()["access-control-allow-origin"],
            "http://127.0.0.1:5006"
        );
    }
}
