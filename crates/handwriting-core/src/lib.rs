//! 跨平台手写核心；不依赖 UI、HTTP 或系统工作目录。
//! 2026-10-12：建立工程边界，实际渲染算法将在后续迁移。

pub const ENGINE_NAME: &str = "handwriting-core";

pub fn rendering_available() -> bool {
    false
}
