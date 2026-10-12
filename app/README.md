# Flutter 客户端

使用 Material Design 3 重建的手写体生成界面。Windows/macOS/Linux 桌面分发包内置 Rust 引擎和字体，打开客户端即可离线生成，无需安装 Python、Rust 或手动启动服务器。Web 连接 HTTP 后端；Android/iOS 随包内置 Rust FFI 引擎，生成、导入和导出可离线完成。

## 已实现

- 桌面三栏工作台、手机分段工作台、中文/英文、系统主题及明暗切换。
- 长文本编辑、撤销/重做、TXT/DOCX/PDF/RTF 导入、插图及比例设置、分页和右对齐。
- Markdown 预览与清洗（四种表格格式）、LaTeX 公式预览与 Unicode 转换、中文书信排版。
- 内置/上传字体、背景上传、背景边距识别、全部现有排版/扰动/墨色/删除线参数。
- 内置预设、自定义预设保存/加载、JSON 导入/导出、设备草稿自动保存。
- 单页/多页预览、缩放、页码切换、PNG 保存、PDF/ZIP 导出、任务进度与队列满提示。
- 使用指南、项目入口、反馈表单。账户接口在后端未启用，因此登录/注册入口展示不可用说明。

Web 第一次使用时读取同源旧 Vue `localStorage` 中的草稿与参数，保留原键；新数据写入独立的 `flutter.workspace`。旧版参数 JSON 的 camelCase 字段也可导入。字体与背景文件需重新选择；插图随草稿保存，浏览器存储容量仍有限。

## 桌面独立客户端

工具链：Flutter 3.47.5 / Dart 3.13.4、Rust 1.94.1；另需当前平台的 Flutter 桌面 SDK。仓库根目录执行：

```bash
python3 scripts/build-flutter-desktop.py
# Flutter 未加入 PATH 时
python3 scripts/build-flutter-desktop.py --flutter /path/to/flutter
```

脚本构建当前平台的原生 UI 和 Rust 服务，随包复制默认字体、VERSION 和许可。产物在 `target/desktop-package/<platform>/`：macOS 为 `.app` 和 ZIP，Windows 为完整应用目录和 ZIP，Linux 为应用目录和 tar.gz。Windows 可用 `python` 执行脚本。必须分发完整目录，不能只复制 UI 可执行文件。版本读取 semantic-release 维护的 `backend/VERSION`。

启动 `.app`、Windows 目录中的 `.exe` 或 Linux 目录中的 `handwriting_app` 即可。客户端自动拉起内置服务，等待握手和健康检查，再恢复草稿并连接工作台。服务只绑定 `127.0.0.1` 的随机端口，访问令牌每次随机生成；桌面模式忽略保存的远程地址并禁用地址切换。生成、文档导入、背景识别与导出不需要网络；项目链接和发送反馈需要网络。

运行数据由 `path_provider` 放在用户应用支持目录中，macOS 使用 sandbox 容器目录。正常退出先关闭 stdin 管道，协作取消任务，最多等待 5 秒后强制回收；客户端崩溃也会触发管道 EOF。后端启动失败或意外退出时展示重新启动入口。

macOS 使用 ad-hoc 签名，并未进行 Developer ID 签名和公证。下载后若被 Gatekeeper 拦截，将 `.app` 放到 `/Applications` 后执行：

```bash
xattr -dr com.apple.quarantine /Applications/HandwritingWeb.app
```

Rust sidecar 的架构取决于构建机。当前 macOS 实测为 arm64，不支持直接将此包用于 Intel Mac。Windows/Linux 构建与进程测试已加入 `.github/workflows/flutter_desktop.yml`，需等待对应 runner 验证。macOS 已在 Xcode 构建阶段自动构建、复制和签名 sidecar，`cd app && flutter run -d macos`、`flutter build macos` 均可直接使用内置引擎。首次启动需安装 Rust 工具链，之后 Cargo 增量构建。Windows/Linux 当前仍使用上面的完整打包脚本嵌入后端。

## Web 开发

先按仓库 `AGENTS.md` 启动 Python 后端，或在根目录执行 `cargo run --locked -p handwriting-server` 启动 Rust 服务（默认端口 5006）。随后：

```bash
cd app
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5005
```

Web release 默认请求同源 `/api`。Rust 开发跨 origin 时需配置 `HANDWRITING_ALLOWED_ORIGINS`。Web 托管、独立服务包与 Docker 见 [部署说明](../deploy/rust/README.md)。

## 移动端独立客户端

Android/iOS 直接调用随包 Rust 引擎，不监听 HTTP 端口，也无需启动外部后端。Android 打包 `libhandwriting_bridge.so`，iOS 链接静态库；Gradle/Xcode 在 `flutter run` 和 `flutter build` 时自动执行 `scripts/build-mobile-engine.py`。构建机需要 Rust，最终用户无需安装 Rust 或 Python。

```bash
# 仓库根目录：按目标平台安装 Rust 标准库
rustup target add aarch64-linux-android x86_64-linux-android
# iOS 需要 macOS + Xcode
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cd app
flutter pub get
flutter run -d <移动设备或模拟器ID>
# Android：安装 NDK 28.2.13676358，支持 API 24+ 的 arm64/x86_64
flutter build apk --release --target-platform android-arm64,android-x64
flutter build appbundle --release --target-platform android-arm64,android-x64
# iOS 15+：本地检查编译，生成未签名 .app
flutter build ios --release --no-codesign
# 发布 IPA 需配置 Apple 签名后使用 flutter build ipa
```

Android release 当前沿用脚手架的 debug 签名，正式发布前需配置自己的签名。iOS 的未签名 `.app` 不能直接安装到真机。Android 不支持 armv7；iOS 真机为 arm64，模拟器支持 arm64/x86_64。

阻塞 FFI 调用运行在 Dart background isolate，生成运行在 Rust worker thread；参数、状态和私有目录路径通过 JSON 传递，PNG/PDF/ZIP 从文件读取。字体由本地 `handwriting_assets` package 复用 `backend/font_assets/`，避免重复维护；首次启动将内置字体提取到应用缓存目录，草稿继续保存在 preferences；生成结果是可清理的缓存，需主动保存导出。单次只执行一个生成任务，最多保留 8 个任务结果。热重启会先取消原生任务并清理旧缓存；应用进入 paused 状态请求协作取消，恢复后可重新生成。

移动端限制：单页最多 12M pixels、20K 字符、20 页、单文件 16MiB、DOCX 解压总量 32MiB；优先使用较小内置字体，缺字时加载 fallback，不长期缓存解析后的字体。预览仍会将全部 PNG 读入 Flutter 内存，大字体和高分辨率在低内存真机上的表现需要进一步验收。

```bash
# 实际移动设备：覆盖随包加载、TXT 导入、两页 PNG、PDF/ZIP 和取消
flutter test integration_test/mobile_engine_test.dart -d <设备ID>
# macOS host 真实 FFI 回归测试
# 先在仓库根目录 cargo build --release -p handwriting-bridge
flutter test test/mobile_api_test.dart --dart-define=MOBILE_ENGINE_LIBRARY=<仓库绝对路径>/target/release/libhandwriting_bridge.dylib
```

本次本地验证通过：Android arm64 模拟器和 iOS arm64 模拟器的离线集成测试、Android arm64/x86_64 release APK、iOS arm64 未签名 release `.app`；Android release APK 已实际启动工作台。Flutter analyze、64 项测试（包含真实 FFI 和桌面 sidecar）以及 Web release 构建通过。模拟器结果不替代低内存真机验收。

移动构建与模拟器集成测试 CI 见 `.github/workflows/flutter_mobile.yml`，尚未在远程 runner 执行。系统文件选择和保存使用现有 Flutter 插件；需要真机检查系统授权、分享/保存目标和后台切换。

既有 Electron/Python 打包入口仍可使用：

```bash
bash scripts/build-flutter-web.sh
bash desktop/build.sh --app-only
```

## 验证

```bash
cd app
flutter analyze
flutter test
# 需要已启动的真实后端；Rust 使用端口 5006
flutter test test/live_api_test.dart --dart-define=LIVE_API_BASE=http://127.0.0.1:5005
flutter build web --release
# 完整原生桌面包在仓库根目录构建：python3 scripts/build-flutter-desktop.py
# 仓库根目录；需要已经完成桌面构建
pnpm --filter handwriting-web-e2e run test:desktop
```

测试包含旧 LaTeX 的 46 个兼容样例、文本工具、API multipart 和返回格式，以及中英文 320/375/768/1024/1440px 工作台布局。桌面 E2E 使用 Flutter Web 的 `Semantics.identifier`（DOM 属性 `flt-semantics-identifier`）作为 `getByTestId` 选择器。

任务进度通过 HTTP 轮询读取 `task_status` / `task_progress`；Rust 提供取消 API 和 cancelled 状态，客户端已将其作为终态处理；移动端 UI 提供取消按钮，生成期间禁用重复提交。任务过期、HTTP 错误和队列满均在界面显示。后端生成效果及原有算法限制沿用当前行为。

内置进程集成测试可传入 `--dart-define=DESKTOP_BACKEND_EXECUTABLE=<打包后的服务绝对路径>`，覆盖自动启动、令牌、地址隔离、真实生成及退出。Rust 另有管道 EOF 退出测试。macOS 实际应用已验证启动和父进程崩溃回收；Windows/Linux 与移动端真机仍需对应平台验收。
