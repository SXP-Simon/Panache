use handwriting_server::{Config, Server};
use std::{env, io::Write, net::SocketAddr, path::PathBuf};
fn number<T: std::str::FromStr>(key: &str, default: T) -> Result<T, Box<dyn std::error::Error>> {
    match env::var(key) {
        Ok(value) => value.parse().map_err(|_| format!("{key} 无效").into()),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(e) => Err(e.into()),
    }
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().init();
    let address: SocketAddr = env::var("HANDWRITING_LISTEN_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:5006".into())
        .parse()?;
    let access_token = env::var("HANDWRITING_ACCESS_TOKEN")
        .ok()
        .filter(|s| !s.is_empty());
    if !address.ip().is_loopback() && access_token.as_ref().is_none_or(|v| v.len() < 32) {
        return Err("非 loopback 监听必须配置至少 32 字节的 HANDWRITING_ACCESS_TOKEN".into());
    }
    let listener = tokio::net::TcpListener::bind(address).await?;
    let bound = listener.local_addr()?;
    let root = env::current_exe()?
        .parent()
        .ok_or("无法定位服务程序目录")?
        .to_path_buf();
    let mut config = Config {
        access_token,
        ..Config::default()
    };
    config.data_dir = env::var_os("HANDWRITING_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(target_os = "windows") {
                PathBuf::from(env::var_os("LOCALAPPDATA").unwrap_or_else(|| env::temp_dir().into()))
                    .join("HandwritingWebRust")
            } else if cfg!(target_os = "macos") {
                PathBuf::from(env::var_os("HOME").unwrap_or_else(|| env::temp_dir().into()))
                    .join("Library/Application Support/HandwritingWebRust")
            } else {
                env::var_os("XDG_DATA_HOME")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| {
                        PathBuf::from(env::var_os("HOME").unwrap_or_else(|| env::temp_dir().into()))
                            .join(".local/share")
                    })
                    .join("handwriting-rust")
            }
        });
    config.font_dir = env::var_os("HANDWRITING_FONT_DIR")
        .or_else(|| env::var_os("FONT_ASSETS_DIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if root.join("font_assets").is_dir() {
                root.join("font_assets")
            } else {
                PathBuf::from("backend/font_assets")
            }
        });
    config.web_dir = match env::var_os("HANDWRITING_WEB_DIR") {
        Some(v) if v.is_empty() => None,
        Some(v) => Some(PathBuf::from(v)),
        None => [root.join("web"), PathBuf::from("app/build/web")]
            .into_iter()
            .find(|p| p.join("index.html").is_file()),
    };
    config.allowed_origins = match env::var("HANDWRITING_ALLOWED_ORIGINS") {
        Ok(value) => value.split(',').map(|s| s.trim().to_owned()).collect(),
        Err(_) => vec![
            format!("http://{bound}"),
            format!("http://localhost:{}", bound.port()),
        ],
    };
    for origin in &config.allowed_origins {
        let parsed = url::Url::parse(origin)?;
        if parsed.origin().ascii_serialization() != *origin
            || !matches!(parsed.scheme(), "http" | "https")
        {
            return Err("HANDWRITING_ALLOWED_ORIGINS 必须是无路径的 HTTP/HTTPS origin".into());
        }
    }
    if let Ok(version) = env::var("HANDWRITING_APP_VERSION") {
        config.version = version;
    } else if let Ok(version) = std::fs::read_to_string(root.join("VERSION")) {
        config.version = version.trim().into();
    }
    config.concurrency = number("HANDWRITING_CONCURRENCY", config.concurrency)?;
    config.max_active = number("HANDWRITING_MAX_ACTIVE", config.max_active)?;
    config.ttl_seconds = number("HANDWRITING_TASK_TTL_SECONDS", config.ttl_seconds)?;
    config.limits.max_pixels = number("HANDWRITING_MAX_PIXELS", config.limits.max_pixels)?;
    config.limits.max_file_bytes =
        number("HANDWRITING_MAX_FILE_BYTES", config.limits.max_file_bytes)?;
    config.limits.max_archive_bytes = number(
        "HANDWRITING_MAX_ARCHIVE_BYTES",
        config.limits.max_archive_bytes,
    )?;
    config.limits.max_text_chars =
        number("HANDWRITING_MAX_TEXT_CHARS", config.limits.max_text_chars)?;
    config.limits.max_pages = number("HANDWRITING_MAX_PAGES", config.limits.max_pages)?;
    let server = Server::new(config)?;
    let cleanup = server.start_cleanup();
    tracing::info!("服务地址：http://{bound}；Rust 手写引擎已启用");
    // 2026-10-12：桌面 sidecar 通过 stdin 管道跟随父进程生命周期。
    // 专用线程避免 Tokio 的阻塞 stdin 在运行时退出时无法回收。
    let desktop = env::var("HANDWRITING_DESKTOP_SIDECAR").as_deref() == Ok("1");
    let (parent_closed, parent_gone) = tokio::sync::oneshot::channel();
    if desktop {
        std::thread::spawn(move || {
            use std::io::Read;
            let mut byte = [0u8; 1];
            while matches!(std::io::stdin().read(&mut byte), Ok(n) if n > 0) {}
            let _ = parent_closed.send(());
        });
        println!(
            "HANDWRITING_READY {}",
            serde_json::json!({"base": format!("http://{bound}")})
        );
        std::io::stdout().flush()?;
    }
    let shutdown_server = server.clone();
    axum::serve(
        listener,
        server
            .router()
            .into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async move {
        if desktop {
            tokio::select! {
                _ = shutdown_signal() => {},
                _ = parent_gone => {},
            }
        } else {
            shutdown_signal().await;
        }
        shutdown_server.cancel_active();
    })
    .await?;
    cleanup.abort();
    Ok(())
}

// 2026-10-12：容器 SIGTERM 与终端 Ctrl+C 都先协作取消任务。
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("无法注册 SIGTERM");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
