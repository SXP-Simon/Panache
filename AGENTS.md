# AGENTS.md

## 文档约定

只保留稳定的项目事实、职责边界、操作入口与开发约定；不记录工作过程、本机验证结果、测试数量或临时状态。实现细节以源码与测试为准。

## 项目概述

Panache 的 Flutter + Rust 跨平台手写体生成器。Android/iOS 使用 C ABI + Dart FFI；桌面使用自动启动的 Rust HTTP sidecar；Web 使用 Rust HTTP 服务。

## 分支与同步

- `main` 维护 Flutter/Rust 客户端与引擎，是默认开发和发布分支。
- `backup` 归档原 React/Python/Electron 实现；`upstream-backup` 归档原 `main`。保留历史提交和许可。
- 自用远端是 `origin`（`SXP-Simon/Panache`），原项目是 `upstream`，Flutter 迁移来源是 `hakimyu`。

## 目录与资源

- `app/`：Flutter 客户端、平台工程、单元测试和移动端集成测试。
- `assets/`：`handwriting_assets` Flutter package，共享字体位于 `assets/font_assets/`。
- `crates/handwriting-core/`：渲染、文档导入、图片处理与 PNG/PDF/ZIP 导出。
- `crates/handwriting-bridge/`：移动端 C ABI、任务进度与取消。
- `crates/handwriting-server/`：HTTP API、WebSocket、SQLite 队列与静态托管。
- `scripts/`：Python 和 shell 构建脚本，运行应用无需 Python。
- `deploy/rust/`：Docker 与独立服务部署。
- `VERSION`：产品版本，格式为 `X.Y.Z`；通过版本准备脚本更新。
- `website/`：项目官网与工坊手记。中英文正文分别在 `content/zh/`、`content/en/`，主题展示使用 README 同一组图。安装 `website/requirements.txt` 后用 `python website/build.py --out <输出目录>` 构建；`main` 的站点变更通过 GitHub Pages 发布。

## 开发与验证

工具链：Flutter 3.47.5 / Dart 3.13.4、Rust 1.94.1。

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cargo run --locked -p handwriting-server
# 另一个终端，Web 开发
cd app
flutter pub get
python3 ../scripts/build-text-worker.py
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5006
flutter analyze
flutter test
cd ..
python3 scripts/build-flutter-web.py
```

原生桌面包：`python3 scripts/build-flutter-desktop.py`。
独立服务包：`bash scripts/build-rust-service.sh`。
移动端及真实引擎测试命令见 [客户端说明](app/README.md)，工具链配置见 [移动开发环境](scripts/MOBILE_ENVIRONMENT.md)，部署配置见 [部署说明](deploy/rust/README.md)。

## 架构与界面

- 业务状态与任务协调在 `services/workspace.dart`，持久化通过 `WorkspaceStorage` 适配，平台引擎通过 API 契约接入。
- 页面组合独立的 `widgets/` 和 `screens/dialogs/`；输入控制器与局部导航由页面持有，不通过 part 或 extension 共享父 State。职责和存储边界见 [客户端架构](docs/flutter-architecture.md)。
- 界面采用新艺术运动风格的深浅色 Material Design 3 主题。标题使用 Playfair Display，中文回退霞鹜文楷，正文使用霞鹜文楷。纸张渲染字体由用户选择。第三方字体保留各自许可。
- 操作同时显示图标与名称，复杂工具提供用途说明。反馈打开项目的 GitHub Issues，不接入旧邮件服务。
- 所有 PR 的 CI 均按次批准：维护者在 PR 上添加 `run-ci` 标签，按改动路径执行检查。验证新提交时移除并重新添加标签；也可从 Actions 手动运行单项检查。操作入口见[贡献指南](CONTRIBUTING.md)。发布时在 `main` 手动触发版本提交的三项检查。推送与版本提交同名的 `vX.Y.Z` 标签触发 Publish Flutter Release，由 CI 从通过检查的标签提交构建安装包。使用入口见[发布说明](docs/release.md)。

## 编码与协作约定

- 先明确假设和成功标准；简单优先，只修改任务必要内容，不顺手重构。
- 用户沟通、文档和协作文本优先使用简体中文；代码、命令、路径和专有名词保持原文。
- Commit 遵循 Conventional Commits，scope 对应真实路径（客户端 `app/...`、后端 `crates/...`、构建 `scripts/...`）；正文分为「背景：」「解决手段：」「收益：」三个非空段落，每个提交聚焦独立变更。
- 每次远程推送都需要用户明确授权。
- UI 复用现有 Flutter Material Design 3 主题；用户可见文字同时维护 `app/lib/l10n/app_zh.arb` 和 `app_en.arb`。
- 除非用户明确要求，不使用 Browser Use 验证。
- 在 `CHANGELOG.md` 的「未发布」维护变更说明；用 `node scripts/prepare-release.cjs vX.Y.Z` 生成版本提交，确认发版时才创建并推送同名标签。发布构建通过参数和 `HANDWRITING_BUILD_VERSION` 注入发布版本，不修改分支源码版本文件；补跑使用 Release 中固定的来源清单。

## 平台约束

- Rust 原生构建需要目标平台工具链；不能假设当前机器产物能在其它 CPU 架构运行。
- 桌面 sidecar 只绑定 loopback，使用随机访问令牌，父进程持有 stdin，EOF 时退出。保留来源校验和令牌验证。
- macOS sidecar 在 Xcode 构建阶段嵌入并签名；分发包使用 ad-hoc 签名，尚无 Developer ID 签名或公证。
- Android/iOS 的 Gradle/Xcode 调用 `scripts/build-mobile-engine.py` 编译 Rust FFI 库；Android 正式发布签名仍需配置。
- Windows 构建与日志涉及中文时使用 UTF-8，保留 CI 的 `PYTHONUTF8` / `PYTHONIOENCODING`。
- 保留算法 `NOTICE` 和 `licenses/`，字体分发遵守各字体许可。
