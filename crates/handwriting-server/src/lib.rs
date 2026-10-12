//! Web 服务入口；生成能力由 handwriting-core 提供。

use std::path::PathBuf;

use axum::{Json, Router, http::StatusCode, routing::get};
use serde::Serialize;
use tower_http::services::{ServeDir, ServeFile};

#[derive(Serialize)]
struct Health {
    status: &'static str,
    engine_name: &'static str,
    rendering_available: bool,
}

async fn health() -> Json<Health> {
    Json(Health {
        status: "ok",
        engine_name: handwriting_core::ENGINE_NAME,
        rendering_available: handwriting_core::rendering_available(),
    })
}

pub fn router(web_dir: Option<PathBuf>) -> Router {
    // 2026-10-12：未知 API 返回 404，不回退成 SPA 页面。
    let api = Router::new()
        .route("/health", get(health))
        .fallback(|| async { StatusCode::NOT_FOUND });
    let app = Router::new().nest("/api", api);

    match web_dir {
        Some(dir) => {
            let index = dir.join("index.html");
            app.fallback_service(ServeDir::new(dir).fallback(ServeFile::new(index)))
        }
        None => app,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    #[tokio::test]
    async fn health_reports_service_readiness_without_claiming_rendering() {
        let response = router(None)
            .oneshot(
                Request::builder()
                    .uri("/api/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), 1024)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["status"], "ok");
        assert_eq!(json["engine_name"], "handwriting-core");
        assert_eq!(json["rendering_available"], false);
    }

    #[tokio::test]
    async fn unknown_api_does_not_fall_back_to_the_frontend() {
        let web_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/web");
        let app = router(Some(web_dir));
        for uri in ["/", "/workspace", "/api/missing"] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
                .await
                .unwrap();
            let expected = if uri.starts_with("/api/") {
                StatusCode::NOT_FOUND
            } else {
                StatusCode::OK
            };
            assert_eq!(response.status(), expected, "{uri}");
        }
    }
}
