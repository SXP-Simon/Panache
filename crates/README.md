# Rust workspace

| crate | 职责 | 当前状态 |
| --- | --- | --- |
| `handwriting-core` | 字体、排版、扰动、图片与文档处理、PNG/PDF/ZIP 导出 | 已实现，独立于 Flutter、HTTP 和 SQLite |
| `handwriting-bridge` | Flutter 原生桥接入口 | 保留 Rust API 边界，FFI 与原生离线运行待实施 |
| `handwriting-server` | API、任务队列、WebSocket、SQLite、静态托管 | 已实现，可独立连接现有 Flutter 客户端 |

核心实现流式/网格排版、数学节点、缺字回退、四邻域连通区域扰动、手动分页、右对齐、删除线模拟、插图滤镜和背景识别。使用 ChaCha8 与显式 seed，固定构建内结果可复现。源码移植的 BSD-3-Clause 说明见 [NOTICE](handwriting-core/NOTICE)。

## 检查与运行

在仓库根目录执行，当前使用 Rust 1.94.1（Edition 2024）：

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cargo run --locked -p handwriting-server
```

默认地址 `127.0.0.1:5006`。健康检查声明 `rendering_available: true`，业务接口兼容既有 Flutter HTTP 客户端。设置 Flutter 的服务地址即可使用 Rust；原生客户端仍通过 HTTP 连接，不代表已支持 FFI 离线生成。

独立服务包、Docker、全部配置、API/取消契约与限制见 [部署说明](../deploy/rust/README.md)。运行时数据使用独立目录与 `rust-tasks.db`，不复用 Python 临时任务库。原 Python 与 Electron 部署路径保留。

workspace 的 `0.1.0` 仅为开发 crate 版本；产品版本展示沿用发版流程维护的 `backend/VERSION`，不手改版本号。依赖由 `Cargo.lock` 固定。`.github/workflows/rust.yml` 增加三平台编译/测试、Linux 服务包、Docker 构建与真实 Flutter API 集成；本机验证结果不代替其它平台 CI 验收。
