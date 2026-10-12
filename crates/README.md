# Rust workspace

| crate | 职责 | 当前状态 |
| --- | --- | --- |
| `handwriting-core` | 字体、排版、扰动、图片与文档处理、PNG/PDF/ZIP 导出 | 已实现，独立于 Flutter、HTTP 和 SQLite |
| `handwriting-bridge` | Flutter 原生桥接入口 | C ABI JSON 请求/响应、原生任务线程、进度、取消、离线导入和导出 |
| `handwriting-server` | API、任务队列、WebSocket、SQLite、静态托管 | 已实现，桌面包作为内置 sidecar 自动运行 |

核心实现流式/网格排版、数学节点、缺字回退、四邻域连通区域扰动、手动分页、右对齐、删除线模拟、插图滤镜和背景识别。使用 ChaCha8 与显式 seed，固定构建内结果可复现。源码移植的 BSD-3-Clause 说明见 [NOTICE](handwriting-core/NOTICE)。

## 检查与运行

在仓库根目录执行，当前使用 Rust 1.94.1（Edition 2024）：

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cargo run --locked -p handwriting-server
```

默认地址 `127.0.0.1:5006`。健康检查声明 `rendering_available: true`，业务接口兼容既有 Flutter HTTP 客户端。设置 Flutter 的服务地址即可使用 Rust；桌面通过随包 HTTP sidecar 调用；Android/iOS 使用 `handwriting-bridge` FFI 离线调用，见 [移动端说明](../app/README.md#移动端独立客户端)。

独立服务包、Docker、全部配置、API/取消契约与限制见 [部署说明](../deploy/rust/README.md)。运行时数据使用独立目录与 `rust-tasks.db`，不复用 Python 临时任务库。原 Python 与 Electron 部署路径保留。

workspace 的 `0.1.0` 仅为开发 crate 版本；产品版本展示沿用发版流程维护的 `backend/VERSION`，不手改版本号。依赖由 `Cargo.lock` 固定。`.github/workflows/rust.yml` 增加三平台编译/测试、Linux 服务包、Docker 构建与真实 Flutter API 集成；本机验证结果不代替其它平台 CI 验收。

桌面完整打包使用 `python3 scripts/build-flutter-desktop.py`。Flutter 自动传入随机端口、访问令牌与可写数据目录；`HANDWRITING_DESKTOP_SIDECAR=1` 启用 stdout 就绪握手和 stdin EOF 退出，`HANDWRITING_WEB_DIR=""` 关闭静态托管。此模式必须由父进程持续持有 stdin 管道。详见 [客户端说明](../app/README.md)。

## 移动端 C ABI

`handwriting-bridge` 产出 `cdylib` 与 `staticlib`，导出 `handwriting_bridge_call` / `handwriting_bridge_free`。输入为 NUL 结尾的 UTF-8 JSON，返回 JSON 指针必须由 `free` 释放一次。操作包括 `reset`、`fonts`、`version`、`license`、`import`、`identify`、`submit`、`status`、`result`、`cancel`、`cancel_all`；响应为 `{ok:true,data:...}` 或 `{ok:false,code,message}`。任务输出路径只用于应用私有目录。

FFI 调用由 Flutter background isolate 执行，生成在原生线程中逐页写文件。任务注册表属于原生进程，Dart 热重启时调用 `reset`，取消并等待旧任务结束后清理缓存。`cargo test --release -p handwriting-bridge` 覆盖真实字体渲染、分页、导出、取消、上传目录边界与 C 字符串释放。
