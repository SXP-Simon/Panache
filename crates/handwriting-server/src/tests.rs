mod generation;
mod http;
mod lifecycle;

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
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
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
