# 移动开发环境

Windows 可在独立目录中安装 Flutter、Rust 和 Android SDK，避免切换其它项目的工具链。
默认目录是 `%LOCALAPPDATA%\HandwriteToolchains`：`flutter-3.47.5`、`cargo`、
`rustup` 与 `android-sdk`。工具版本以根目录 `AGENTS.md` 为准。

```powershell
# 仓库根目录；环境只作用于当前终端。
. .\scripts\use-mobile-toolchains.ps1
Set-Location app
flutter pub get
flutter test
flutter devices
# Android 构建/运行与静态分析：中文仓库路径使用下面的英文 junction。
Set-Location ..
. .\scripts\use-mobile-toolchains.ps1 -EnterApp
flutter analyze
flutter run -d <设备ID>
flutter build apk --debug --target-platform android-arm64,android-x64
```

Android Gradle 拒绝 Windows 中文工程路径；Android 构建/运行和静态分析可从仓库根目录使用 `. .\scripts\use-mobile-toolchains.ps1 -EnterApp`，再运行
`flutter analyze`。`-EnterApp` 通过 `C:\src\handwrite-flutter` 的 ASCII junction 打开当前工作树的 `app`，
规避 Windows 上 Dart language server 在中文路径下初始化消息截断的问题。
不要把工作树 junction 放入 MSIX 应用重定向的 LocalAppData：Dart 的文件复制可能无法解析该路径。
宿主单元测试也可从真实仓库路径执行。
同一平台的 Flutter 构建或测试保持串行，运行期间不要清理共享构建缓存。
源码仍位于原仓库中。
自定义位置可传 `-ToolchainRoot`、`-FlutterRoot`、`-AndroidSdk` 和 `-WorkspacePath`；脚本不下载工具，
不修改系统环境，也不覆盖已有的其它项目 junction。

Android 需要 JDK 17+、command-line tools、platform-tools、Android SDK Platform 35/36、
Build Tools 36.0.0、NDK 28.2.13676358。从 [Android 官方站点](https://developer.android.com/studio#command-line-tools-only)
安装 command-line tools 后，通过 SDK 管理器安装所需组件并接受相应许可。
模拟器另需 `emulator` 和与目标架构匹配的 system image；Windows 主机使用 x86_64 image。

```powershell
rustup target add aarch64-linux-android x86_64-linux-android
sdkmanager --licenses
sdkmanager 'platform-tools' 'platforms;android-35' 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358'
sdkmanager 'emulator' 'system-images;android-36;google_apis;x86_64'
avdmanager create avd -n handwrite-api36 -k 'system-images;android-36;google_apis;x86_64' -d pixel_6
emulator -avd handwrite-api36
```

`app/android/local.properties` 保持本地忽略状态，`sdk.dir` 与 `flutter.sdk` 分别指向真实
Android 和 Flutter SDK 根目录，不要把 platform-tools 目录当作 SDK 根目录。
首次本机构建还会下载 Gradle 与 Maven 依赖，需要可访问其官方仓库。
实际引擎的移动集成验证命令见 [app/README.md](../app/README.md)。

Windows Rust 主机构建需要 Visual Studio C++ Build Tools 和 Windows SDK；环境脚本通过
`vswhere` 查找已安装版本。iOS 构建和模拟器验证需要 macOS、Xcode 与对应 Rust targets，
不能由 Windows 构建结果替代。
