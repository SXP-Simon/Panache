mod startup;

use handwriting_server::Server;
use std::{io::Write, net::SocketAddr};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().init();
    let endpoint = startup::Endpoint::from_env()?;
    let desktop = endpoint.desktop;
    let listener = tokio::net::TcpListener::bind(endpoint.address).await?;
    let bound = listener.local_addr()?;
    let server = Server::new(endpoint.config(bound)?)?;
    let cleanup = server.start_cleanup();
    tracing::info!("服务地址：http://{bound}；Rust 手写引擎已启用");
    // 2026-10-12：桌面 sidecar 通过 stdin 管道跟随父进程生命周期。
    // 专用线程避免 Tokio 的阻塞 stdin 在运行时退出时无法回收。
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
