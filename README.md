# 手写体生成器

使用 Flutter + Rust 实现的跨平台手写体生成工具，支持文字与文档导入、字体和背景选择、排版扰动、图片预览及 PNG / PDF / ZIP 导出。

- Android / iOS：通过 Dart FFI 调用随包 Rust 引擎，支持离线生成。
- Windows / macOS / Linux：Flutter 原生界面自动启动随包 Rust sidecar，支持离线生成。
- Web：Flutter Web 连接 Rust HTTP 服务，服务可同时托管页面。

## 目录

```text
app/                         Flutter 客户端、平台工程与测试
assets/                      handwriting_assets package 与共享字体
crates/handwriting-core/     渲染、图片处理、文档导入与导出
crates/handwriting-bridge/   移动端 C ABI / FFI
crates/handwriting-server/   HTTP API、任务队列与静态托管
scripts/                     桌面、移动端和独立服务构建脚本
deploy/rust/                 Docker 与服务部署说明
.github/workflows/           Flutter / Rust 检查与打包
VERSION                      产品版本（保留原值）
```

## 开发

工具链：Flutter 3.47.5 / Dart 3.13.4、Rust 1.94.1；原生平台需安装相应 SDK。Python 仅用于原生构建脚本，应用运行不依赖 Python。

```bash
# 仓库根目录启动 Rust 服务，默认监听 127.0.0.1:5006
cargo run --locked -p handwriting-server
```

另一个终端：

```bash
cd app
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5006
# macOS 原生开发：自动构建并嵌入 Rust sidecar
flutter run -d macos
```

Web 跨 origin 开发需配置 `HANDWRITING_ALLOWED_ORIGINS`，详见 [部署说明](deploy/rust/README.md)。

## 构建与验证

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cd app
flutter analyze
flutter test
flutter build web --release
```

在仓库根目录构建独立桌面包或服务包：

```bash
python3 scripts/build-flutter-desktop.py
bash scripts/build-rust-service.sh
```

移动端构建、原生库集成、各平台签名与限制见 [Flutter 客户端说明](app/README.md)，Rust 架构见 [workspace 说明](crates/README.md)。产品版本读取根目录 `VERSION`；旧版发布流水线已移除，重写版自动发版尚未接入。`CHANGELOG.md` 保留历史发布记录。

## 许可

项目许可见 [LICENSE](LICENSE)，移植算法的声明与许可见 [NOTICE](crates/handwriting-core/NOTICE)。客户端可在“关于与反馈 → 开源许可”查看项目、算法及已确认的 OFL 字体许可；服务包、桌面包和 Rust Docker 镜像同时携带 LICENSE 与 licenses/。

九款共享字体保持不变，授权依据及尚待确认的字体见 [字体许可记录](assets/licenses/FONT-LICENSES.md)。项目 MIT 许可不覆盖第三方字体；保留字体文件不代表已取得其商用或再分发授权。
