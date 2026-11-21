# Flutter / Rust 发布

[Publish Flutter Release](../.github/workflows/publish_flutter.yml) 使用 `main` 上的确切提交构建。Flutter UI、Rust 后端和 Flutter Mobile 必须在同一仓库、分支和 SHA 上全部通过。每次发布将 SHA、检查运行 ID 和版本固定在 `Flutter-source.json`，包旁的 JSON 记录 SHA-256。

推送到 `main` 后，GitHub Actions 会对相关改动运行 CI。准备发版时，在 Actions 中打开 **Publish Flutter Release**，点击 **Run workflow**，选择 `main` 并填写比上次发布更高的稳定版本号，例如 `v1.18.1`。工作流会核验所选提交的三项检查，并从上次发布的源码提交起收集变更说明。任务中断后可重试同一提交产生的草稿。通过版本与签名校验并上传全部适用包后，CI 才公开 Release。

安装包包括 Windows x64、Linux x64、macOS arm64 和已配置正式签名时的 Android arm64-v8a / x86_64。历史 Release 和已有下载链接继续保留。旧 Web/Electron 源码可以在 `backup` 查看。

桌面构建可通过 `scripts/build-flutter-desktop.py --version <版本> --build-number <构建号>`
注入版本；普通开发不需要这些参数。`HANDWRITING_BUILD_VERSION` 同时决定 Rust
后端/FFI 的构建版本，打包的后台 `VERSION` 文件与 Flutter 应用版本保持一致。
构建不会提交或改写源码中的版本文件。

Android 正式发布需要以下 GitHub Actions Secrets：

| Secret | 内容 |
|---|---|
| `HANDWRITING_ANDROID_KEYSTORE_BASE64` | 正式 JKS 签名文件的 Base64 |
| `HANDWRITING_ANDROID_STORE_PASSWORD` | 密钥库密码 |
| `HANDWRITING_ANDROID_KEY_ALIAS` | 正式密钥别名 |
| `HANDWRITING_ANDROID_KEY_PASSWORD` | 密钥密码 |

构建时由 CI 把密钥解码到临时目录，并通过 `HANDWRITING_ANDROID_KEYSTORE_PATH`
传给 Gradle，构建结束清理。没有完整签名配置时省略 Android 发布；普通本地
release-mode 调试仍可使用调试签名，调试签名包不能作为正式发布产物上传。

macOS 桌面包使用 ad-hoc 签名，未配置 Apple Developer ID 或公证；首次使用时
可能需要在系统隐私与安全性设置中允许打开。iOS 需要分发证书与 provisioning，
未配置时不发布不可安装的 IPA。
