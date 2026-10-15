# 同一发布中的 Flutter 安装包

`custom-base` 是自用发布主线。`Flutter Release Assets` 在该分支的 Semantic Release 成功后，读取**触发运行自身**的 `release-result`，将 Flutter 包追加到同一个已有 Release；不创建 tag、不修改源码版本或发布另一套版本。

## 来源固定与质量门禁

首次自动运行解析 `flutter` 的完整提交 SHA，要求同一仓库、`flutter` 分支、同一 SHA 的 `Flutter UI`、`Rust 后端`、`Flutter Mobile` 三个质量工作流全部成功。接受同仓库、同 `flutter` 分支、精确 SHA 的 push 或手动运行；最新一次匹配运行若失败或未完成，不能用较早成功替代，PR 和其它 fork 也不能作为证据。

三个质量工作流保留路径过滤。若文档或打包脚本改动未触发某项检查，可在 Actions 手动运行缺失工作流，选择 `flutter` 分支，确认其 SHA 与拟发布来源一致；通过后再补跑安装包工作流。

通过门禁后，工作流先将 `Flutter-source.json` 上传到目标 Release，记录版本、稳定构建号、Flutter SHA 和质量运行 ID。该文件不覆盖。桌面与移动构建只检出此 SHA，控制脚本检出工作流自身的 SHA；不会将两个分支混成一棵源码树。

Flutter 来源必须支持显式版本构建和正式 Android 签名接口；旧 SHA 不支持时直接失败。Release 版本传入桌面构建的 `--version`、`--build-number` 与 `HANDWRITING_BUILD_VERSION`，保证系统包版本、随包 Rust API 和界面版本一致。构建号固定为 `major × 1,000,000 + minor × 1,000 + patch`，minor/patch 均需小于 1000，结果在 Android 支持范围内；当前只接收稳定 `vX.Y.Z` tag。

对已固定 SHA 的待运行或进行中检查，工作流每 30 秒等待一次，三项检查合计最多等待 30 分钟；尚未创建运行时给予 90 秒调度宽限。失败或取消立即拒绝，超时后可用同一 SHA 手动补跑；等待过程中不会重新解析分支、改用其它提交或跳过失败检查。

## 产物

- `Flutter-HandwritingWeb-<version>-windows-x64.zip`
- `Flutter-HandwritingWeb-<version>-linux-x64.tar.gz`
- `Flutter-HandwritingWeb-<version>-macos-arm64.zip`
- 配置正式签名后：`Flutter-HandwritingWeb-<version>-android-arm64-v8a.apk`（手机优先）和 `Flutter-HandwritingWeb-<version>-android-x86_64.apk`（x86_64 模拟器或设备）

每个包带独立 `.json` 证明文件，包含源 SHA、版本与 SHA-256。全部必要桌面包构建、打包后版本验证及证明检查通过后，统一使用带重试的上传脚本发布，避免部分构建失败时提前发布另一组包。`Flutter-` 前缀与 Electron 安装包区分。

桌面包按对应平台构建；macOS 仍为 ad-hoc 签名，首次打开与系统限制见[桌面说明](desktop.md)。不分发未配置 Apple 分发签名的 IPA。

## Android 正式签名

在当前仓库 Actions secrets 配置：

| Secret | 用途 |
|---|---|
| `HANDWRITING_ANDROID_KEYSTORE_BASE64` | 自有正式 keystore 的 Base64 内容 |
| `HANDWRITING_ANDROID_STORE_PASSWORD` | keystore 密码 |
| `HANDWRITING_ANDROID_KEY_ALIAS` | 正式签名别名 |
| `HANDWRITING_ANDROID_KEY_PASSWORD` | 私钥密码 |

四项全部配置才构建和上传 Android APK；缺失时，源 manifest 记录首次跳过原因，Actions summary 明确说明，桌面构建继续执行。临时 keystore 仅供构建使用，结束后删除；上传前执行 `apksigner verify`，拒绝 Android Debug 证书。不得将本地 debug 签名 APK 作为正式发布替代品。

## 补跑

Actions → Flutter Release Assets → Run workflow：

- `tag`：已有的 `custom-base` 发布，例如 `v1.2.0`。
- `flutter_ref`：首次为历史 Release 添加 Flutter 包时，必须填写已通过三项门禁的完整 40 位 SHA。
- Release 已有 `Flutter-source.json` 时可以省略 `flutter_ref`，只能复用其固定来源；填写不同 SHA 会被拒绝。

若首次运行在写入 manifest 前失败，不能直接重跑自动运行来重新选择分支；应通过 Run workflow 显式填写首次等待日志中的原 SHA。

补跑会重新核验该 SHA 的必要工作流并保持相同构建号。配置签名后，可用同一 manifest/SHA 补充正式 APK；不会移动来源，也不会选用 `flutter` 最新版本。
