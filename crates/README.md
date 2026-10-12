# Rust workspace

| crate | 职责 | 当前状态 |
| --- | --- | --- |
| `handwriting-core` | 独立生成核心 | 标识和能力状态，尚未移植渲染 |
| `handwriting-bridge` | Flutter 原生桥接入口 | Rust API 边界，尚未生成 FFI |
| `handwriting-server` | Web API 与静态页面服务 | Axum 服务、健康检查和 SPA 托管 |

核心不依赖 Flutter、HTTP 或 SQLite；生成算法与文件处理迁移到核心，平台与网络功能留在适配层。

## 检查

在仓库根目录执行，要求支持 Edition 2024 的 Rust 工具链：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p handwriting-server
```

默认地址为 `127.0.0.1:5006`，`GET /api/health` 返回服务状态，并明确 `rendering_available: false`。其他业务接口尚未实现；未知 API 返回 404，不回退成首页。

默认从当前工作目录的 `app/build/web` 提供页面。未构建 Web 时仍可运行 API；显式设置 `HANDWRITING_WEB_DIR` 时，该目录必须包含 `index.html`。

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `HANDWRITING_LISTEN_ADDR` | `127.0.0.1:5006` | 监听地址 |
| `HANDWRITING_WEB_DIR` | `app/build/web`（存在时） | Web 静态资源目录 |

部署时将服务程序与 Web 产物一起分发，并设置资源目录。当前脚手架只适合本地开发，尚无公网部署所需的鉴权、Origin 校验、限流与生成任务管理。

workspace 的 `0.1.0` 是开发脚手架版本，尚未参与产品版本展示或现有 semantic-release 版本同步。库依赖通过 `Cargo.lock` 固定；后续发布阶段再接入版本流程。
