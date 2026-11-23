use super::*;

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
