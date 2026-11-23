use super::*;

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
    let fonts: Vec<String> = serde_json::from_slice(&call(&s, "/api/fonts_info").await.1).unwrap();
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
