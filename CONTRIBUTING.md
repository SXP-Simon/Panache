# Contributing to Panache

[中文贡献指南](#中文贡献指南)

Start from `main`. The Flutter client lives in `app/`, the Rust engine in `crates/`, and the bilingual website in `website/`. To run the browser workbench, follow [Local development](https://heliannuits.me/Panache/en/development/). For native builds, see the [client guide](app/README.md) and [mobile toolchains](scripts/MOBILE_ENVIRONMENT.md).

Open a pull request against `main`. Describe the change and which platforms you tested. For bug fixes, include the steps that reproduced the issue. Update both Chinese and English UI strings and record user-visible changes under “未发布” in the [changelog](CHANGELOG.md).

Use Conventional Commits with a scope matching the affected directory. The commit body has three paragraphs headed `背景：` (background), `解决手段：` (implementation), and `收益：` (benefit). See the [repository conventions](AGENTS.md) for details.

## 中文贡献指南

从 `main` 开始开发。Flutter 客户端位于 `app/`，Rust 引擎位于 `crates/`，双语官网位于 `website/`。启动本地工作台见[本地开发](https://heliannuits.me/Panache/development/)，原生构建见[客户端说明](app/README.md)和[移动开发环境](scripts/MOBILE_ENVIRONMENT.md)。

向 `main` 提交 PR 时，说明改动内容和验证过的平台；修复问题时附上复现步骤。界面文案同时更新中英文，用户可见的变更记入[更新记录](CHANGELOG.md)的「未发布」。提交使用 Conventional Commits，scope 对应改动目录，正文分别写明「背景：」「解决手段：」「收益：」。详见[仓库开发约定](AGENTS.md)。

## Checks / 验证

PR checks are opt-in for all authors, including maintainers. To approve a check for a branch in this repository, open **Actions**, select the relevant workflow, click **Run workflow**, and select the PR’s head branch. Each run covers the revision selected at dispatch. For a fork, the contributor can run the same workflow manually in their fork.

所有 PR（包括维护者自己的 PR）均按需手动验证。在 **Actions** 选中所需检查，点 **Run workflow** 并选择 PR 的源分支。分支有新提交时，由维护者决定是否再次运行。来自 fork 的贡献者也可在自己的仓库手动运行相同检查。

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

对比两个提交的 Dart 函数复杂度、嵌套与长度，可使用[仓库自带的 Dart 结构计量命令](scripts/dart-quality/README.md)。
