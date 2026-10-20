# Panache · Flutter / Rust

使用 Flutter + Rust 实现的跨平台手写体生成工具，支持文字与文档导入、字体和背景选择、排版扰动、图片预览及 PNG / PDF / ZIP 导出。

- Android / iOS：通过 Dart FFI 调用随包 Rust 引擎，支持离线生成。
- Windows / macOS / Linux：Flutter 原生界面自动启动随包 Rust sidecar，支持离线生成。
- Web：Flutter Web 连接 Rust HTTP 服务，服务可同时托管页面。

界面采用绿色 Material Design 3 主题，中英文 UI 统一使用霞鹜文楷；纸张中的手写文字仍使用用户所选字体。手机工具入口同时显示图标和名称，展开菜单提供用途说明；生成任务可在工作台直接取消。

模块边界与状态管理见 [客户端架构](docs/flutter-architecture.md)，移动工具链与 Windows 环境入口见 [移动开发环境](scripts/MOBILE_ENVIRONMENT.md)。

## 相比原版的表格处理增强

在原版 Markdown 文本清洗的基础上，新增保留表格结构并生成二维手写表格的处理方式：

- **Markdown 表格转 LaTeX**：选择「表格：手写方格（LaTeX）」后清洗，保留行列结构；原有清单、对齐文本等模式仍可选择。
- **分布律与公式表格**：支持带分隔线的 LaTeX `array`，以及外层带 `\boxed{...}` 的表格；单元格可包含中文、数字和上下竖式分数。
- **完整方格与自然对齐**：绘制完整外框和行列格线，统一格线粗细与行高，按实际墨迹居中；纸面文字沿用所选手写字体和墨色。
- **整体缩放与分页**：过宽表格整体缩小，分页时保持整张表格完整；支持范围内的空单元格和含竖线、分号等特殊字符的内容不会错列。
- **保留不支持的输入**：无法可靠转换的表格保留为可编辑文本，不强行丢弃内容；重复清洗与转换保持已转写的表格结构。

使用顺序：**粘贴表格 → Markdown 清洗 → LaTeX 转换 → 生成预览**。已有 LaTeX 表格可直接点击 LaTeX 转换。

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
VERSION                      产品版本
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

## 持续验证与反馈

`flutter` 分支推送与相关 pull request 按路径触发 Flutter 检查、Rust 跨平台检查，以及 Android/iOS 模拟器上的随包引擎集成测试。独立桌面打包保留 pull request 与手动入口；这些工作流不发布版本。

问题与建议通过[当前 fork 的 GitHub Issues](https://github.com/SXP-Simon/Panache/issues)提交，客户端反馈入口会打开该页面。

## 许可

项目许可见 [LICENSE](LICENSE)，移植算法的声明与许可见 [NOTICE](crates/handwriting-core/NOTICE)。客户端可在“关于与反馈 → 开源许可”查看项目、算法及已确认的 OFL 字体许可；服务包、桌面包和 Rust Docker 镜像同时携带 LICENSE 与 licenses/。

共享字体的授权依据及尚待确认的字体见 [字体许可记录](assets/licenses/FONT-LICENSES.md)。项目 MIT 许可不覆盖第三方字体；保留字体文件不代表已取得其商用或再分发授权。
