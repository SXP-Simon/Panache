# Flutter 客户端

使用 Material Design 3 重建的手写体生成界面，通过 HTTP 连接现有 Python/FastAPI 后端。此次不改动 `backend/` 和 Rust workspace。原生 Flutter 客户端当前也需要后端连接，Rust 离线引擎属于后续阶段。

## 已实现

- 桌面三栏工作台、手机分段工作台、中文/英文、系统主题及明暗切换。
- 长文本编辑、撤销/重做、TXT/DOCX/PDF/RTF 导入、插图及比例设置、分页和右对齐。
- Markdown 预览与清洗（四种表格格式）、LaTeX 公式预览与 Unicode 转换、中文书信排版。
- 内置/上传字体、背景上传、背景边距识别、全部现有排版/扰动/墨色/删除线参数。
- 内置预设、自定义预设保存/加载、JSON 导入/导出、设备草稿自动保存。
- 单页/多页预览、缩放、页码切换、PNG 保存、PDF/ZIP 导出、任务进度与队列满提示。
- 使用指南、项目入口、反馈表单。账户接口在后端未启用，因此登录/注册入口展示不可用说明。

Web 第一次使用时读取同源旧 Vue `localStorage` 中的草稿与参数，保留原键；新数据写入独立的 `flutter.workspace`。旧版参数 JSON 的 camelCase 字段也可导入。字体与背景文件需重新选择；插图随草稿保存，浏览器存储容量仍有限。

## 本地启动

工具链：Flutter 3.47.5 / Dart 3.13.4；各原生平台另需对应 SDK。先按仓库 `AGENTS.md` 启动 Python 后端：

```bash
uv sync
cd backend
../.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 5005
```

在另一终端启动 Flutter：

```bash
cd app
flutter pub get
flutter run -d macos
# Web 开发模式连接现有后端（与 Flutter 开发服务端口不同）
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5005
```

Web release 默认请求同源 `/api`；原生默认连接 `http://127.0.0.1:5005`。顶栏云图标可修改服务地址。Android 模拟器连接主机时使用 `http://10.0.2.2:5005`；手机需填写电脑局域网地址，HTTPS 服务适用于所有平台。iOS 真机局域网权限、移动设备文件选择与导出需要对应设备验收。

## Web 与桌面打包

```bash
# 仓库根目录：构建 Flutter Web，并同步到现有桌面打包使用的 frontend/dist
bash scripts/build-flutter-web.sh
# 沿用 Electron 外壳与 PyInstaller 后端，加载 Flutter Web 界面
bash desktop/build.sh --app-only
# 原生 Flutter UI 构建（不包含 Python 后端，需独立启动服务）
cd app
flutter build macos
```

Python 后端可用既有 `HANDWRITING_DIST_DIR` 托管 `app/build/web`。Web 部署先执行 `cd app && flutter build web --release`，再执行 `docker build -t handwriting-frontend app`（从仓库根目录执行 Docker 命令）。`app/Dockerfile` 和 `app/nginx.conf` 托管构建产物，仍代理到 `backend:5005`，原来的 Docker Compose 服务关系不变。前端发布工作流已切到 Flutter。Flutter 脚本不含 Vue 的文件 hash，因此 Nginx 使用重新验证缓存策略；CanvasKit 从构建目录加载。

旧 `frontend/` 源码与 Vue E2E 暂留作迁移对照，线上与桌面构建入口已使用 Flutter。旧版 `/About`、`/Introduce`、`/Feedback` 等路径有对应入口。

## 验证

```bash
cd app
flutter analyze
flutter test
# 需要已启动的真实 Python 后端
flutter test test/live_api_test.dart --dart-define=LIVE_API_BASE=http://127.0.0.1:5005
flutter build web --release
flutter build macos --debug
# 仓库根目录；需要已经完成桌面构建
pnpm --filter handwriting-web-e2e run test:desktop
```

测试包含旧 LaTeX 的 46 个兼容样例、文本工具、API multipart 和返回格式，以及中英文 320/375/768/1024/1440px 工作台布局。桌面 E2E 使用 Flutter Web 的 `Semantics.identifier`（DOM 属性 `flt-semantics-identifier`）作为 `getByTestId` 选择器。

任务进度通过 HTTP 轮询读取 `task_status` / `task_progress`；目前后端没有取消接口，所以生成期间禁用重复提交。任务过期、HTTP 错误和队列满均在界面显示。后端生成效果及原有算法限制沿用当前行为。

Android/iOS/Windows/Linux 工程已接入文件与网络插件；本机不能证明这些平台的完整运行和分发已经通过。签名、公证和版本发布继续遵循仓库原有流程。
