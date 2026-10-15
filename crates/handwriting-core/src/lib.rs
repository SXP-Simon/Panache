//! 跨平台生成核心；2026-10-12：不依赖 HTTP、Flutter 或全局工作目录。
pub mod document;
pub mod export;
pub mod fonts;
pub mod imaging;
mod parameters;
pub mod render;
pub mod text;
pub use parameters::{Limits, Parameters};
pub use render::{Cancellation, FontBook, RenderRequest, render};
use thiserror::Error;
pub const ENGINE_NAME: &str = "handwriting-core";
pub const ALGORITHM_VERSION: &str = "1";
pub fn rendering_available() -> bool {
    true
}
#[derive(Debug, Error)]
#[error("{code}: {message}")]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}
impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}
pub type Result<T> = std::result::Result<T, Error>;
