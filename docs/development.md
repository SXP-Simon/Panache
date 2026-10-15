# 本地开发

本文适用于 `custom-base`。技术栈、模块职责与数据流见[架构与技术栈](architecture.md)，
分支职责和开发约定见仓库根的
[AGENTS.md](https://github.com/SXP-Simon/handwriting-web/blob/custom-base/AGENTS.md)。

## 环境与依赖

需要 Node.js 24+、pnpm 10.13.1、Python 3.12+ 和 uv。在仓库根目录执行：

```bash
pnpm install --frozen-lockfile
uv sync --locked --extra dev
```

pnpm 管理前端、Electron 和 E2E 工作区；uv 根据 `pyproject.toml` 与 `uv.lock`
维护根目录的 `.venv`。使用该环境启动后端与运行检查。

## 启动前后端

在两个终端分别启动：

```bash
# 终端一：仓库根目录
pnpm --filter handwrite run serve

# 终端二：从仓库根目录进入 backend
cd backend
uv run --project .. uvicorn app:app --reload --host 127.0.0.1 --port 5005
```

打开 <http://127.0.0.1:8080>。Vite 将 `/api` 代理到 `127.0.0.1:5005`；
前端直接请求同源的 `/api` 路径。

VS Code 的 `Ctrl+Shift+B` 任务会安装依赖、并行启动服务并打开浏览器；
`F5` 可选择 Chrome / Edge 调试。配置位于 `.vscode/tasks.json` 与 `.vscode/launch.json`。

## 检查、测试与构建

以下命令均在仓库根目录执行：

```bash
# TypeScript、Oxlint、格式、Ruff 与 Pyright
pnpm run quality:check

# 提交约定、前端转换与生成、桌面存储、后端单元测试
pnpm run test:unit

# Web E2E：首次安装浏览器后运行
pnpm --filter handwriting-web-e2e exec playwright install chromium
pnpm --filter handwriting-web-e2e run test

# 前端生产构建；PWA 缓存升级验证
pnpm --filter handwrite run build
pnpm run test:sw-upgrade

# 单元测试 + 前端构建 + PWA 升级 + Web E2E
pnpm run test:all
```

Web E2E 驱动真实前后端进行渲染与下载，部分异常分支使用路由拦截。
未运行的开发服务会自动启动并在测试后关闭，本地已运行的服务会复用；
自动启动的后端设置 `CPU_USAGE_LIMIT=100`，复用服务则沿用其现有环境。
找不到解释器时，可通过 `E2E_PYTHON` 指定。失败截图与 trace 位于
`e2e/test-results/`，用 `pnpm --filter handwriting-web-e2e run report` 打开 HTML 报告。

桌面测试单独驱动打包产物，不包含在 `test:all` 中：

```bash
bash desktop/build.sh --app-only
pnpm --filter handwriting-web-e2e run test:desktop
```

桌面构建使用 uv 的 `build` extra；`--skip-deps` 前需自行准备环境：

```bash
uv sync --locked --extra dev --extra build
bash desktop/build.sh --app-only --skip-deps
```

构建脚本通过当前平台的 Electron 和 PyInstaller 出包，不能跨平台编译后端。
`uv sync` / `uv run` 会按选择的 extra 调整环境；不要在桌面打包期间并发运行
会重新同步同一 `.venv` 的质量检查或安装命令。正常构建流程和数据目录见[桌面版](desktop.md)。

## 修改入口

- 界面组合与局部交互：`frontend/src/components/`；共用界面在 `src/shared/`。
- 客户端共享状态：`frontend/src/features/*/store.ts`；跨域业务操作在 `features/workspace/`。
- 服务端契约与 Query 配置：`frontend/src/api/`；本地存储适配在 `src/persistence/`。
- 文本、数学与排版的纯转换：`frontend/src/utils/`；中英文案在 `src/i18n.ts`。
- 后端任务与渲染：`backend/app.py`、`task_store.py` 与数学布局模块。
- 桌面进程与桥：`desktop/main.js`、`preload.js`、`studio-storage.js`。

状态归属、刷新恢复和任务续接的边界以[架构说明](architecture.md)为准；
精确字段与参数按需查阅代码和测试。

## 提交约定

`pnpm install` 自动安装 Lefthook。提交前执行完整质量门禁，推送前执行完整测试；
不能通过跳过 hook 代替修复。每个提交聚焦一个可独立审阅的变更，使用
`type(scope): 描述`，正文包含独立、非空的「背景：」「解决手段：」「收益：」段落。

用户可见文字同时提供中英文；E2E 操作元素添加 `data-testid`。
版本文件、发布 tag 与 `CHANGELOG.md` 由 semantic-release 管理。
