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
| `custom-base` | 默认自用开发主线，使用 React、Python/FastAPI 和 Electron |
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
- React/Python 与 Flutter/Rust 的功能需要分别移植和验证，不假定跨分支自动共享。
- 操作前检查 `git status`、`git branch -vv` 和 `git worktree list`。
- 用 `git cherry -v custom-base upstream/main` 辅助识别等价补丁，再审查实际改动；不同提交哈希不代表功能缺失。
- 向原项目贡献改动通过 PR。

## 架构约定

- 前端使用 React、TypeScript 与 Vite；Zustand 管理分域客户端状态，TanStack Query 管理服务端数据。
- 组件保留局部交互状态并按需订阅业务状态；Context 提供语言与稳定操作入口。
- 业务操作、请求契约和持久化分层维护，store 不承担网络、文件写入与对象 URL 生命周期。
- Web 使用 localStorage 与 IndexedDB；桌面通过受限 Electron IPC 保存到应用数据目录。
- 架构、模块职责与存储边界见 [docs/architecture.md](docs/architecture.md)，开发入口见 [docs/development.md](docs/development.md)。

## 开发入口

工具链：Node.js 24+、pnpm 10.13.1、Python 3.12+ 和 uv。

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

# 工程质量门禁与构建
pnpm run quality:check
pnpm --filter handwrite run build

# 单元测试与全部测试（包含浏览器 E2E）
pnpm run test:unit
pnpm --filter handwriting-web-e2e exec playwright install chromium
pnpm run test:all

# 桌面版构建
bash desktop/build.sh
```

自用发布从 `custom-base` 进行：工程质量工作流通过后触发 semantic-release，再由桌面工作流构建安装包。`main` 只同步上游。
桌面版按构建机的平台与架构出包，产物上传使用 `scripts/upload-release-assets.sh`。

本地 `pnpm install` 自动安装 Lefthook；需要重装时运行 `pnpm run hooks:install`。
提交前执行完整质量门禁，推送前执行完整测试；CI 直接运行相同检查，不安装本机 hooks。
已有自定义 hooks 必须先整合，不能通过覆盖或跳过检查安装新 hooks。

## 开发约定

- 提交遵循 Conventional Commits；正文必须包含「背景：」「解决手段：」「收益：」三个独立非空段落，每个提交聚焦一个逻辑变更。
- 提交消息由 `scripts/check-commit-message.cjs` 校验；只有发布流程生成的精确版本发布消息可免正文，普通提交不能使用跳过 CI 的指令。CI 不追溯规则引入前的历史提交。
- 根据改动运行相关检查，提交前处理新增错误。
- 用户可见文字同时提供中英文，复用前端的集中翻译入口。
- 界面复用站点已有样式；需要测试操作的元素添加 `data-testid`，E2E 使用 `getByTestId`。
- 后端注释使用中文并标注日期；Python 使用 Ruff 与 Pyright strict，前端使用严格类型检查、Oxlint 与项目格式配置；不通过忽略类型错误、关闭规则或显式 any 绕过检查。
- 不手动修改 `CHANGELOG.md`、发布版本号或创建发布 tag，由 semantic-release 维护。
- 修改桌面运行、打包或发布流程前，先阅读相应源码和测试，保留既有安全及跨平台约束。
