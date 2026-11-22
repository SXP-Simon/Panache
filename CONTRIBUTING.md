# Contributing to Panache

[中文贡献指南](#中文贡献指南)

Start from `main`. The Flutter client lives in `app/`, the Rust engine in `crates/`, and the bilingual website in `website/`. To run the browser workbench, follow [Local development](https://heliannuits.me/Panache/en/development/). For native builds, see the [client guide](app/README.md) and [mobile toolchains](scripts/MOBILE_ENVIRONMENT.md).

Open a pull request against `main`. Describe the change and which platforms you tested. For bug fixes, include the steps that reproduced the issue. Update both Chinese and English UI strings and record user-visible changes under “未发布” in the [changelog](CHANGELOG.md).

Use Conventional Commits with a scope matching the affected directory. The commit body has three paragraphs headed `背景：` (background), `解决手段：` (implementation), and `收益：` (benefit). See the [repository conventions](AGENTS.md) for details.

## 中文贡献指南

从 `main` 开始开发。Flutter 客户端位于 `app/`，Rust 引擎位于 `crates/`，双语官网位于 `website/`。启动本地工作台见[本地开发](https://heliannuits.me/Panache/development/)，原生构建见[客户端说明](app/README.md)和[移动开发环境](scripts/MOBILE_ENVIRONMENT.md)。

向 `main` 提交 PR 时，说明改动内容和验证过的平台；修复问题时附上复现步骤。界面文案同时更新中英文，用户可见的变更记入[更新记录](CHANGELOG.md)的「未发布」。提交使用 Conventional Commits，scope 对应改动目录，正文分别写明「背景：」「解决手段：」「收益：」。详见[仓库开发约定](AGENTS.md)。

## Checks / 验证

Run the checks for the part you changed, starting from the repository root. 从仓库根目录运行与改动相关的检查。

**Flutter**

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

**Rust**

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
```
