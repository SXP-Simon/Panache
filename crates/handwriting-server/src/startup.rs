use handwriting_server::Config;
use std::{
    env,
    net::SocketAddr,
    path::{Path, PathBuf},
};

type Error = Box<dyn std::error::Error>;

pub(super) struct Endpoint {
    pub(super) address: SocketAddr,
    pub(super) desktop: bool,
    access_token: Option<String>,
}

impl Endpoint {
    pub(super) fn from_env() -> Result<Self, Error> {
        let address: SocketAddr = env::var("HANDWRITING_LISTEN_ADDR")
            .unwrap_or_else(|_| "127.0.0.1:5006".into())
            .parse()?;
        let access_token = env::var("HANDWRITING_ACCESS_TOKEN")
            .ok()
            .filter(|s| !s.is_empty());
        if !address.ip().is_loopback() && access_token.as_ref().is_none_or(|v| v.len() < 32) {
            return Err("非 loopback 监听必须配置至少 32 字节的 HANDWRITING_ACCESS_TOKEN".into());
        }
        let desktop = env::var("HANDWRITING_DESKTOP_SIDECAR").as_deref() == Ok("1");
        if desktop
            && (!address.ip().is_loopback() || access_token.as_ref().is_none_or(|v| v.len() < 32))
        {
            return Err("桌面 sidecar 需要 loopback 地址和至少 32 字节的访问令牌".into());
        }
        Ok(Self {
            address,
            desktop,
            access_token,
        })
    }

    pub(super) fn config(self, bound: SocketAddr) -> Result<Config, Error> {
        let root = env::current_exe()?
            .parent()
            .ok_or("无法定位服务程序目录")?
            .to_path_buf();
        let mut config = Config {
            desktop: self.desktop,
            access_token: self.access_token,
            ..Config::default()
        };
        config.data_dir = env::var_os("HANDWRITING_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(default_data_dir);
        config.font_dir = font_dir(&root);
        config.web_dir = web_dir(&root);
        config.allowed_origins = allowed_origins(bound)?;
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
        Ok(config)
    }
}

fn default_data_dir() -> PathBuf {
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
}

fn font_dir(root: &Path) -> PathBuf {
    env::var_os("HANDWRITING_FONT_DIR")
        .or_else(|| env::var_os("FONT_ASSETS_DIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if root.join("font_assets").is_dir() {
                root.join("font_assets")
            } else {
                PathBuf::from("assets/font_assets")
            }
        })
}

fn web_dir(root: &Path) -> Option<PathBuf> {
    match env::var_os("HANDWRITING_WEB_DIR") {
        Some(v) if v.is_empty() => None,
        Some(v) => Some(PathBuf::from(v)),
        None => [root.join("web"), PathBuf::from("app/build/web")]
            .into_iter()
            .find(|p| p.join("index.html").is_file()),
    }
}

fn allowed_origins(bound: SocketAddr) -> Result<Vec<String>, Error> {
    let origins: Vec<String> = match env::var("HANDWRITING_ALLOWED_ORIGINS") {
        Ok(value) => value.split(',').map(|s| s.trim().to_owned()).collect(),
        Err(_) => vec![
            format!("http://{bound}"),
            format!("http://localhost:{}", bound.port()),
        ],
    };
    for origin in &origins {
        let parsed = url::Url::parse(origin)?;
        if parsed.origin().ascii_serialization() != *origin
            || !matches!(parsed.scheme(), "http" | "https")
        {
            return Err("HANDWRITING_ALLOWED_ORIGINS 必须是无路径的 HTTP/HTTPS origin".into());
        }
    }
    Ok(origins)
}

fn number<T: std::str::FromStr>(key: &str, default: T) -> Result<T, Error> {
    match env::var(key) {
        Ok(value) => value.parse().map_err(|_| format!("{key} 无效").into()),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(e) => Err(e.into()),
    }
}
