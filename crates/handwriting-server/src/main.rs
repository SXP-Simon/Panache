use std::{env, net::SocketAddr, path::PathBuf};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let address: SocketAddr = env::var("HANDWRITING_LISTEN_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:5006".to_owned())
        .parse()?;
    let web_dir = match env::var_os("HANDWRITING_WEB_DIR") {
        Some(dir) => {
            let dir = PathBuf::from(dir);
            if !dir.join("index.html").is_file() {
                return Err("HANDWRITING_WEB_DIR must contain index.html".into());
            }
            Some(dir)
        }
        None => {
            let dir = PathBuf::from("app/build/web");
            dir.join("index.html").is_file().then_some(dir)
        }
    };

    let listener = tokio::net::TcpListener::bind(address).await?;
    println!("服务地址：http://{}", listener.local_addr()?);
    println!("健康检查：/api/health（手写渲染尚未接入）");
    if web_dir.is_none() {
        println!("未找到 Web 构建产物，当前仅提供 API。请在 app/ 执行 flutter build web。");
    }

    axum::serve(listener, handwriting_server::router(web_dir))
        .with_graceful_shutdown(async {
            if let Err(error) = tokio::signal::ctrl_c().await {
                eprintln!("无法监听退出信号：{error}");
            }
        })
        .await?;
    Ok(())
}
