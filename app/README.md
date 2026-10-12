# Flutter 客户端

新客户端与现有 `frontend/`、`backend/`、`desktop/` 并行开发。总体方案见 [refactor.md](../docs/refactor.md)。

当前提供 Android、iOS、Windows、macOS、Linux 和 Web 平台工程、中英文首页及响应式布局。手写引擎、FFI 与 HTTP 调用尚未接入，不具备生成和导出功能。

## 开发与检查

要求 Flutter 3.47.5 或兼容版本、Dart 3.13.4 或兼容版本；各原生平台还需要相应 SDK。首次执行：

```bash
cd app
flutter pub get
flutter run -d macos
```

按本机设备选择 `flutter run` 目标。iOS 真机签名由开发者在 Xcode 配置，工程不预置个人开发团队。

```bash
flutter analyze
flutter test
flutter build web
```

生成的翻译文件位于 `lib/l10n/app_localizations*.dart`，由 `flutter pub get` / `flutter gen-l10n` 管理；只编辑 ARB。当前无需启动 Python 后端。

## Web 本地运行

先在 `app/` 执行 `flutter build web`，再回仓库根目录运行：

```bash
cargo run -p handwriting-server
```

访问 `http://127.0.0.1:5006`。服务同时托管 `app/build/web` 和 `/api/health`，与旧后端的 5005 端口分开。该首页目前不调用 API，健康检查仅验证服务及核心状态。

## 后续接入

Rust 源码位于根目录 `crates/`，通过根目录 Cargo workspace 管理。`handwriting-bridge/src/api.rs` 已建立 Rust 调用边界，后续接入 `flutter_rust_bridge` 的依赖、生成配置、绑定和原生构建。当前没有生成 FFI 文件，也没有链接 Rust 库。

Web 后续通过 HTTP 调用 `handwriting-server`；原生客户端通过桥接层直接调用核心。避免为原生客户端引入本地 HTTP 服务。

平台工程存在不代表对应平台已验证。Android、iOS、Windows 和 Linux 的完整构建与运行需在相应环境完成。
