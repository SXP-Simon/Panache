use crate::{Server, header};
use axum::{
    Json,
    body::Body,
    extract::State,
    http::{HeaderMap, HeaderValue, Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use std::time::{Duration, Instant};

pub(super) async fn boundary(
    State(s): State<Server>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let headers = request.headers();
    let cors_origin = header(headers, "origin");
    if foreign_request(headers, cors_origin, &s.0.config.allowed_origins) {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({"error_code":"foreign_origin","message":"请求来源不允许"})),
        )
            .into_response();
    }
    if request.method() == axum::http::Method::OPTIONS && cors_origin.is_some() {
        return with_cors(StatusCode::NO_CONTENT.into_response(), cors_origin);
    }
    if let Some(token) = &s.0.config.access_token
        && !authenticated(headers, token)
    {
        let mut response = (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error_code":"unauthorized","message":"需要访问令牌"})),
        )
            .into_response();
        response.headers_mut().insert(
            "www-authenticate",
            HeaderValue::from_static("Basic realm=\"Handwriting\""),
        );
        return with_cors(response, cors_origin);
    }
    if request.uri().path().starts_with("/api/") && rate_limited(&s, &request) {
        let response = (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({"error_code":"rate_limited","message":"请求过于频繁"})),
        )
            .into_response();
        return with_cors(response, cors_origin);
    }
    let cors_origin = cors_origin.map(str::to_owned);
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    with_cors(response, cors_origin.as_deref())
}

fn foreign_request(headers: &HeaderMap, cors_origin: Option<&str>, allowed: &[String]) -> bool {
    let foreign = cors_origin.is_some_and(|o| !allowed.iter().any(|a| a == o))
        || header(headers, "referer")
            .is_some_and(|r| origin(r).is_none_or(|o| !allowed.contains(&o)))
        || (header(headers, "sec-fetch-site") == Some("cross-site") && cors_origin.is_none());
    let host = header(headers, "host");
    let invalid_host = host.is_some_and(|h| {
        !allowed.iter().any(|a| {
            url::Url::parse(a).ok().is_some_and(|u| {
                let authority = match u.port() {
                    Some(port) => format!("{}:{port}", u.host_str().unwrap_or("")),
                    None => u.host_str().unwrap_or("").into(),
                };
                authority == h
            })
        })
    });
    foreign || invalid_host
}

fn origin(value: &str) -> Option<String> {
    url::Url::parse(value)
        .ok()
        .map(|v| v.origin().ascii_serialization())
}

fn authenticated(headers: &HeaderMap, token: &str) -> bool {
    let auth = header(headers, "authorization").unwrap_or("");
    let bearer = auth.strip_prefix("Bearer ");
    let basic = auth
        .strip_prefix("Basic ")
        .and_then(|v| STANDARD.decode(v).ok())
        .and_then(|v| String::from_utf8(v).ok())
        .and_then(|v| v.split_once(':').map(|(_, p)| p.to_owned()));
    bearer == Some(token) || basic.as_deref() == Some(token)
}

fn rate_limited(s: &Server, request: &Request<Body>) -> bool {
    let ip = request
        .extensions()
        .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
        .map(|v| v.0.ip().to_string())
        .unwrap_or_else(|| "local".into());
    let path = request.uri().path();
    let group = if path == "/api/generate_handwriting"
        || path.ends_with("fileprocess")
        || path == "/api/pdfpageprocess"
    {
        "upload"
    } else {
        "query"
    };
    let limit = if group == "upload" { 200 } else { 600 };
    let mut rates = s.0.rates.lock().unwrap();
    if rates.len() > 4096 {
        rates.retain(|_, (time, _)| time.elapsed() < Duration::from_secs(300));
    }
    let entry = rates
        .entry(format!("{ip}:{group}"))
        .or_insert((Instant::now(), 0));
    if entry.0.elapsed() >= Duration::from_secs(300) {
        *entry = (Instant::now(), 0);
    }
    entry.1 += 1;
    entry.1 > limit
}

fn with_cors(mut response: Response, origin: Option<&str>) -> Response {
    if let Some(origin) = origin
        && let Ok(value) = HeaderValue::from_str(origin)
    {
        let h = response.headers_mut();
        h.insert("access-control-allow-origin", value);
        h.insert("vary", HeaderValue::from_static("Origin"));
        h.insert(
            "access-control-allow-credentials",
            HeaderValue::from_static("true"),
        );
        h.insert(
            "access-control-allow-methods",
            HeaderValue::from_static("GET, POST, OPTIONS"),
        );
        h.insert(
            "access-control-allow-headers",
            HeaderValue::from_static("Authorization, Content-Type, X-Panache-Task-Id"),
        );
    }
    response
}
