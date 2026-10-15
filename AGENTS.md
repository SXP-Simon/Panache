# AGENTS.md

> 本仓库的长期项目事实与开发约定。

## 文档维护

- 只保留稳定的项目事实、分支职责、操作入口与开发约定。
- 不记录工作过程、提交清单、同步快照、测试成绩、临时环境状态或故障经过。
- 实现细节、参数与功能支持情况按需查阅源码和相关测试，不在本文件重复说明。

## 项目与分支

本仓库是 Simon 的手写体生成应用 fork。

| 分支 | 职责 |
|---|---|
| `custom-base` | 默认自用开发主线，使用 Vue、Python/FastAPI 和 Electron |
| `main` | 同步原项目的 `upstream/main`，不加入自用功能 |
| `flutter` | 独立维护 Flutter/Rust 迁移版，选择性接收 HakimYu 的迁移更新 |

| 远端 | 仓库 |
|---|---|
| `origin` | `https://github.com/SXP-Simon/handwriting-web.git` |
| `upstream` | `https://github.com/14790897/handwriting-web.git` |
| `hakimyu` | `https://github.com/HakimYu/handwriting.git` |

### 分支使用

- 自用改动默认在 `custom-base` 上完成；用户要求独立分支时再创建功能分支。
- `main` 使用快进方式同步 `upstream/main`；不能快进时先检查分歧，不强制重置。
- `custom-base` 审查后通过 `cherry-pick -x` 选择性吸收上游功能和修复。
- 上游纯发布提交通常只留在 `main`，不为对齐历史而搬入自用分支。
- `flutter` 通过 `cherry-pick -x` 接收 `hakimyu/refactor/flutter-rust` 的更新，不整分支合入 `custom-base`。
- Vue/Python 与 Flutter/Rust 的功能需要分别移植和验证，不假定跨分支自动共享。
- 操作前检查 `git status`、`git branch -vv` 和 `git worktree list`。
- 用 `git cherry -v custom-base upstream/main` 辅助识别等价补丁，再审查实际改动；不同提交哈希不代表功能缺失。
- 向原项目贡献改动通过 PR。

## 开发入口

`custom-base` 的前端、后端、桌面版和端到端测试分别位于 `frontend/`、`backend/`、
`desktop/`、`e2e/`；构建与发布入口位于 `scripts/` 和 `.github/workflows/`。
Flutter/Rust 版的操作入口以该分支的文档和工程配置为准。

```bash
# 安装依赖
pnpm install
uv sync --extra dev

# 启动前端
pnpm --filter handwrite run serve

# 启动后端：以 backend/ 为工作目录
cd backend
uv run --project .. uvicorn app:app --host 127.0.0.1 --port 5005
cd ..

# 前端检查与构建
pnpm --filter handwrite run lint
pnpm --filter handwrite run build

# 后端与端到端测试
uv run --extra dev python -m pytest backend/tests
pnpm --filter handwriting-web-e2e run test

# 桌面版构建
bash desktop/build.sh
```

桌面版按构建机的平台与架构出包，产物上传使用 `scripts/upload-release-assets.sh`。

## 开发约定

- 提交遵循 Conventional Commits，建议使用清晰的中文说明；每个提交聚焦一个逻辑变更。
- 根据改动运行相关检查，提交前处理新增错误。
- 用户可见文字同时提供中英文，翻译集中在 `frontend/src/i18n.js`。
- 界面复用站点已有样式；需要测试操作的元素添加 `data-testid`，E2E 使用 `getByTestId`。
- 后端注释使用中文并标注日期；前端遵循项目 ESLint 和 Prettier 配置。
- 不手动修改 `CHANGELOG.md`、发布版本号或创建发布 tag，由 semantic-release 维护。
- 修改桌面运行、打包或发布流程前，先阅读相应源码和测试，保留既有安全及跨平台约束。
