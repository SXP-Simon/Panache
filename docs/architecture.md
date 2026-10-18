# 架构与技术栈

本文描述 `custom-base` 的 React / Python / Electron 应用。`main` 用于同步上游，
`flutter` 独立维护 Flutter / Rust 版本；本页不描述这两个分支的实现。
开发命令见[本地开发](development.md)，分支规则见仓库的
[AGENTS.md](https://github.com/SXP-Simon/Panache/blob/custom-base/AGENTS.md)。

## 技术栈

| 职责 | 技术与用途 |
|---|---|
| 前端界面与构建 | React、TypeScript、Vite；Tailwind CSS 与项目样式，Motion 动效、Lucide 图标 |
| 客户端业务状态 | Zustand；按正文、设置、预览、偏好和通知划分 store |
| 服务端数据 | TanStack Query；原生 Fetch 请求，Valibot 校验响应与保存格式 |
| 数学与文本转换 | KaTeX 解析及项目转换工具；Markdown 清洗、书信排版、插图占位符处理 |
| 本地保存 | Web 使用 localStorage + IndexedDB；桌面通过受限 Electron IPC 读写应用数据目录 |
| 生成服务 | Python、FastAPI；Uvicorn 开发服务，Gunicorn / Uvicorn Worker 生产服务 |
| 排版与导出 | handrightbeta、Pillow、项目数学字形与布局模块；OpenCV 检测背景，PyMuPDF 导出 PDF |
| 后端任务 | SQLite 持久化队列；WebSocket 推送进度，HTTP 轮询作为回退 |
| 桌面与离线入口 | Electron + PyInstaller；Web 使用项目自有 TypeScript Service Worker 缓存应用外壳 |
| 验证与工程工具 | Playwright、Node 测试、pytest；Oxlint / Oxfmt、Ruff / Pyright、Lefthook、semantic-release |

具体版本以 `frontend/package.json`、`desktop/package.json`、`pyproject.toml` 和锁文件为准。
界面统一使用霞鹜文楷；纸张内的字形由用户选择的手写字体与后端缺字回退逻辑决定。

## 目录与职责

主界面为单工作台，使用帮助、桌面下载等入口以弹窗展示。业务模块按 `features/` 组织。

| 位置 | 职责 |
|---|---|
| `frontend/src/main.tsx` | 先恢复本地工作区，再安装保存订阅、Query Provider 与业务操作入口 |
| `frontend/src/App.tsx`、`components/` | 界面组合、表单与交互；组件按需订阅状态 |
| `frontend/src/shared/` | 共用 UI、图标与动效基础 |
| `frontend/src/features/*/store.ts` | 各业务域的内存状态与同步状态变更 |
| `frontend/src/features/workspace/` | 导入、设置、生成等跨域操作编排，以及工作区恢复与保存订阅 |
| `frontend/src/features/settings/` | 参数解析、旧格式转换和预设仓库 |
| `frontend/src/features/generation/` | 生成操作、任务会话、Query 缓存订阅与重试倒计时 |
| `frontend/src/api/` | 请求、响应校验、Query 配置、任务接口与下载适配 |
| `frontend/src/persistence/` | 记录协议、Web / 桌面存储适配、资源快照与引用保护 |
| `frontend/src/utils/`、`i18n.ts` | 纯文本 / 数学转换与集中中英文案 |
| `frontend/worker/` | 应用外壳缓存；API 请求不进入离线缓存 |
| `backend/app.py` | HTTP / WebSocket 路由、任务调度与生成流程 |
| `backend/task_store.py`、`task_types.py` | 任务持久化与数据契约 |
| `backend/symbol_fallback.py`、`math_*.py` | 数学字形回退、几何与页面布局 |
| `backend/identify.py`、`pdf.py`、`logging_setup.py` | 背景检测、PDF 导出与统一日志 |
| `desktop/main.js`、`preload.js` | 后端进程、窗口、下载与隔离的渲染进程桥 |
| `desktop/studio-storage.js` | 固定键存储 IPC、来源校验、原子文件写入与写队列等待 |
| `e2e/` | Web 与真实桌面打包产物的端到端验证 |

界面将用户操作交给工作区业务入口；业务入口组合 store、API、预设仓库和资源服务。
API 层处理传输与数据契约，存储适配层处理持久化。store 保留状态与同步变更，
不承担网络请求、文件写入或对象 URL 的创建与释放。

## 状态归属

| 状态 | 所有者 | 保存策略 |
|---|---|---|
| 正文、插图映射、导入文件名 | document store | 工作区快照与二进制资源 |
| 手写参数、字体、背景、生成选项 | settings store | 工作区快照；上传文件保存为资源 |
| 语言、明暗模式、界面主题色、表格转换模式 | preferences store | 工作区快照 |
| 预览图片 URL、当前页、下载展示信息 | preview store | 内存展示状态；不保存为草稿 |
| 字体目录、版本、任务状态、原始生成结果 | TanStack Query | 内存缓存；不把整份 Query 缓存写入本地 |
| 生成任务 ID 与导出模式 | 生成流程 / `studio.generation` | 用于刷新后续接服务端任务 |
| 操作通知、保存状态 | 独立 store | 内存状态 |
| 弹窗、折叠、选区、数字框暂存文本 | 组件状态与 ref | 随组件生命周期结束 |

组件通过字段 selector 或 `useShallow` 订阅需要的值。正文输入不会通过一个巨大的
Context value 传播到整页；任务进度由状态展示组件单独订阅。Context 用于语言环境和
稳定的工作区操作入口，`QueryClientProvider` 提供服务端缓存。

## 生成数据流

1. 业务入口读取正文和参数快照，先做本地校验；提交时将插图占位符展开为接口所需内容。
2. API 层提交任务。后端将任务写入 SQLite，并返回任务 ID。
3. 客户端保存任务 ID 与导出模式，优先通过 WebSocket 观测进度；连接不可用时回退到 HTTP 轮询。
4. 推送和轮询更新同一份 Query 任务缓存。完成后获取图片、ZIP 或 PDF，再交给预览与下载适配器。
5. 刷新时读取已保存的任务身份，继续观测原任务，不重新 POST。服务端任务必须仍在有效期内。

生成 POST 不自动重试；队列满时按服务端返回的期限禁用提交。取消、卸载和页面离开会
中止客户端请求并清理观测连接，不代表删除后端任务。暂时的网络错误或超时保留任务身份，
成功获取结果、明确失败或任务已不存在时清除对应记录。上传快照在 POST 结束后释放引用。

## 本地持久化

### 元数据与二进制分开保存

| 内容 | Web | 桌面 |
|---|---|---|
| `studio.workspace`、预设、活跃任务记录 | 当前来源的 localStorage | 应用数据目录的 `studio/records/` |
| 插图、上传字体、纸张背景 | IndexedDB 的 `handwriting-studio` / `assets` | 应用数据目录的 `studio/assets/` |

桌面数据目录由主进程决定：Windows 为 `%LOCALAPPDATA%/HandwritingWeb`，macOS 为
`~/Library/Application Support/HandwritingWeb`。存储不依赖本次后端随机端口。
后端的 SQLite 任务队列与这里的编辑器草稿是不同的数据及生命周期。

`studio.workspace` 将正文、参数、偏好和资源引用放在一份快照中；预设使用独立记录。
插图与上传文件按内容哈希去重。快照保存资源 ID 和文件元数据，不保存 `blob:` URL，
也不把整份 Base64 图片塞进草稿记录；恢复时重新构造 File、插图映射和必要的对象 URL。

### 保存与恢复边界

- 普通编辑防抖保存，失焦、页面隐藏和离开时补写；已经准备好的资源允许同步提交 Web 元数据。
- 上传资源先持久化，再发布对应界面状态；存储不可用时仍保留内存中的编辑，并明确显示保存失败。
- 二进制先写入，再提交引用它的完整元数据快照。失败不会用半份新快照覆盖上一份完整草稿。
- 桌面文件通过临时文件、同步与重命名替换；同一记录的写入串行，读取等待此前已接收的写入。
- 启动时优先读取当前快照，缺少快照时读取旧 `studio.*`、camelCase 设置及 `myPreset`。
  恢复失败会提示，并阻止自动覆盖无法读取的工作区。
- 对象 URL 由资源服务管理，替换预览或背景时释放旧 URL；较慢的异步结果不能覆盖更新的编辑状态。

Web 存储按来源隔离，没有跨标签页的协作合并。为避免误删另一标签页的在途资源，Web 不自动回收
无引用的二进制；桌面只回收本次已识别且不被工作区、预设或在途操作保护的应用资源。
读取或保存失败时，本会话停止自动回收。

### 桌面退出

正常关窗或退出应用时，主进程先保留页面并请求保存，收到确认后等待已接收的写入队列，再退出。
保存失败或等待超时时可取消退出；强制结束进程或断电只能依赖此前已提交的快照。
存储桥仅接受当前主窗口主 frame 的精确同源请求，并限制记录键、资源 ID、大小和在途操作，
不向页面开放任意文件路径。

## 扩展约定

- 新增客户端状态先确定所属业务域；临时交互状态留在组件，服务端数据进入 Query 缓存。
- 新接口在 `api/` 中定义契约、校验和 Query key；跨域副作用由工作区业务入口组合。
- 新增保存内容通过持久化适配器，保留迁移与失败处理；扩展记录键时同步渲染端协议与桌面桥白名单。
- 改动刷新恢复、任务观测或退出保存时，覆盖相应单元测试与端到端路径。
- 精确字段、大小限制、超时和缓存参数以源码与测试为准；版本与提交历史不在本页重复维护。
