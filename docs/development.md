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
# 完整质量检查：前后端静态检查、hooks 与桌面存储检查
pnpm run quality:check

# 查看暂存区将触发的检查；按暂存区运行相关测试
pnpm run checks:plan -- --staged
pnpm run test:affected -- --staged

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

桌面测试单独构建并驱动打包产物，不包含在 `test:all` 中：

```bash
pnpm run test:desktop
```

已有目录版产物时，可以直接运行 `pnpm --filter handwriting-web-e2e run test:desktop`。

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

`pnpm install` 自动安装 Lefthook。已有自定义 hooks 时需先整合，不能直接覆盖。
每个提交聚焦一个可独立审阅的变更，使用
`type(scope): 描述`，正文包含独立、非空的「背景：」「解决手段：」「收益：」段落。

scope 描述真实代码路径；前后端分别以 `fe/`、`be/` 为别名，例如：

```text
fix(fe/src/components): 改善参数面板的键盘操作
fix(be/math_page_layout.py): 修复公式分页边界
test(scripts): 补充检查范围的回归测试
ci(scripts): 调整检查范围与工作流的衔接
docs(docs/development.md): 说明本地验证入口
```

`fe/` 对应 `frontend/`，`be/` 对应 `backend/`；scope 中的目录或文件应覆盖本次实际改动。
新约定不要求改写历史提交。提交说明校验始终执行，普通提交不能通过跳过 CI 的标记免检。

用户可见文字同时提供中英文；E2E 操作元素添加 `data-testid`。
版本文件、发布 tag 与 `CHANGELOG.md` 由 semantic-release 管理。

## 按需检查与 CI

本地 hooks 和 CI 共用 `scripts/change-impact.cjs`，从 Git 实际改动路径规划检查，
不根据提交类型或 scope 跳过检查。多个范围取检查集合的并集；删除与重命名也参与判断。

- 提交前读取暂存区，执行相关质量检查和空白错误检查。相关文件存在未暂存修改时会停止，避免用工作区的新版本替代暂存版本进行验证。
- 推送前读取 Git 提供的全部待推送 ref，运行这些提交实际影响的测试。相关未提交修改需要先处理；待推送版本与当前检出版本不一致时需切换后验证。
- 新分支或缺失比较基线时执行完整验证；手动运行 Engineering quality 也执行完整验证。只删除远端 ref 时无需运行应用测试。
- `pnpm run quality:check` 保留完整质量检查；`test:all` 保留完整 Web 测试，`test:desktop` 单独验证打包桌面版。`pnpm run test:affected -- --all` 可主动运行全部按需测试组。

一般情况下，纯说明文档不触发应用检查；`docs/` 和 MkDocs 配置触发文档构建。
前端改动选择前端质量、单元测试、构建及相关浏览器验证；后端改动选择 Python 质量、单元测试及相关接口验证。
桌面桥、存储与打包入口改动增加桌面验证；共享依赖或无法归类的输入扩大检查范围。
精确映射以 `scripts/change-impact.cjs` 及其测试为准。

Engineering quality 在推送到 `custom-base`、面向 `custom-base` 的 PR 与手动运行时启动。
轻量范围规划和 `Engineering quality gate` 始终运行，其余质量、Docker、文档与桌面任务按计划执行。
分支保护应选择稳定的汇总门禁 `Engineering quality gate`。

自动发布和镜像构建消费同一次成功检查的计划与提交哈希：只有应用相关改动才进入版本分析，
镜像只在相应输入变化时构建。桌面发布读取对应版本发布的结果，构建确切的 tag；手动补构建入口保留。
文档部署只监听 `custom-base` 的文档输入。`main` 用于镜像同步上游，不触发自用构建与发布。
旧的独立后端、E2E 与 MySQL 工作流仅保留手动入口，避免重复自动执行。

Docker 发布需配置自有镜像地址变量 `FRONTEND_IMAGE`、`BACKEND_IMAGE` 和相应仓库凭据；
未配置镜像地址时不执行登录、构建或推送，不沿用上游账号地址。

## 文档站

MkDocs 将 `docs/` 中的 Markdown 生成静态文档，`mkdocs.yml` 负责导航、主题、仓库链接与站点地址。
文档站位于 <https://heliannuits.me/handwriting-web/>；它使用 GitHub Pages，不运行 FastAPI 手写应用。
手写应用的运行方式见[Docker 部署](self-hosting/docker.md)与本页的本地启动说明。

仓库 Settings → Pages 的构建来源需选 GitHub Actions。`Deploy Docs` 在 `custom-base` 的文档输入变化时
发布，也可手动选择分支运行。`github-pages` 环境需允许所选部署分支。
本站沿用个人 Pages 已配置的域名；修改站点地址时，同时更新 `site_url` 与文档入口链接。

```bash
uv tool run --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict
```
