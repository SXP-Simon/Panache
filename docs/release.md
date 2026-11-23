# Flutter / Rust 发布

[Publish Flutter Release](../.github/workflows/publish_flutter.yml) 使用 `main` 上的确切提交构建。Flutter UI、Rust 后端和 Flutter Mobile 必须在同一仓库、分支和 SHA 上全部通过。每次发布将 SHA、检查运行 ID 和版本固定在 `Flutter-source.json`，包旁的 JSON 记录 SHA-256。

## 准备与发布

日常改动记入 [CHANGELOG.md](../CHANGELOG.md) 的「未发布」。准备发版时，在 `main` 的仓库根目录运行以下命令。示例中的版本号替换为要发的版本。

```bash
node scripts/prepare-release.cjs v1.18.1
git show --stat HEAD
```

脚本将未发布说明移到新版本标题下，更新根目录 `VERSION`，创建只含这两个文件的 `chore(release): v1.18.1` 提交。标题中的日期是北京时间的版本准备日期。普通 PR 在合并前完成验证。准备发布时，推送版本提交，并趁它仍是 `main` 的最新提交启动三项检查。发布流程会核对每次运行的 SHA。

```bash
git -c push.followTags=false push origin main
gh workflow run flutter.yml --ref main
gh workflow run rust.yml --ref main
gh workflow run flutter_mobile.yml --ref main
```

确定公开发布时，为刚才的版本提交创建同名标签，并只推送该标签。如果此时分支已有后续提交，用版本提交的 SHA 替换下例的 `HEAD`。

```bash
git tag -a v1.18.1 HEAD -m "Panache v1.18.1"
git push origin refs/tags/v1.18.1
```

发布工作流检查标签指向的提交在 `main` 历史上、版本递增、提交标题与 `VERSION` 和更新记录匹配，并等待该 SHA 的三项验证通过。从对应的更新记录生成 Release 说明；安装包校验与上传完成后公开 Release。实际公开时间见 [GitHub Releases](https://github.com/SXP-Simon/Panache/releases)。发布中断时可以在 Actions 重跑同一次标签运行，继续同一提交的草稿。

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
