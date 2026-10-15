# Flutter 发布

开源仓库：[SXP-Simon/handwriting-web](https://github.com/SXP-Simon/handwriting-web)。
Flutter 与 React/Python 保持独立源码分支；共同的 GitHub Release 由 `custom-base`
的 [Flutter Release Assets](https://github.com/SXP-Simon/handwriting-web/blob/custom-base/.github/workflows/flutter_release.yml) 编排。

发布使用通过 Flutter、Rust 和移动端检查的完整提交 SHA，并在 Release 的
`Flutter-source.json` 中固定来源。补跑复用该来源，不自动换成分支最新代码。
Flutter 产物带 `Flutter-` 前缀，和 Electron 安装包区分。

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
