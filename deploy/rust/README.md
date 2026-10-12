# 独立 Rust 服务

服务包目录包含 `handwriting-server`（Windows 为 `.exe`）、`web/`、`font_assets/`、`VERSION` 和算法许可证。启动程序后打开 <http://127.0.0.1:5006>，无需安装 Python、Rust 或 Flutter；目录整体移动时请保留资源目录。macOS 程序当前未经签名或公证，分发需遵循项目现有 Gatekeeper 说明。

## 开发与打包

在仓库根目录运行：

```bash
cargo run --locked -p handwriting-server
# 当前平台服务包，要求 Flutter 与 Rust 工具链
bash scripts/build-rust-service.sh
# 已有 app/build/web 时跳过 Web 构建
bash scripts/build-rust-service.sh --skip-web
# 产物在 target/service-package/
```

服务包是 HTTP 服务及浏览器界面，不是原生 Flutter FFI 安装包。构建使用当前机器架构；Windows、Linux 与 macOS 的编译测试由独立 CI matrix 执行。

## Docker

```bash
cd app && flutter build web --release && cd ..
export HANDWRITING_ACCESS_TOKEN="$(openssl rand -hex 32)"
docker compose -f deploy/rust/compose.yml up --build -d
```

Compose 将端口绑定在主机 `127.0.0.1:5006`。浏览器访问时使用 Basic auth，用户名任意，密码为访问令牌。API 客户端使用 `Authorization: Bearer <token>`。远程部署需配置 HTTPS 反向代理，并将 `HANDWRITING_ALLOWED_ORIGINS` 设置为用户访问的 origin，例如 `https://write.example.com`；代理保留该请求的 Host，不使用 `*`。反向代理需要转发 WebSocket Upgrade。令牌不应编译进 Flutter Web 或提交进仓库。Flutter 原生客户端可用 `--dart-define=HANDWRITING_ACCESS_TOKEN=<token>` 配置请求令牌；Web 不读取此配置，使用浏览器 Basic auth。客户端 UI 暂无令牌输入框。

## 配置

| 环境变量 | 默认行为 |
| --- | --- |
| `HANDWRITING_LISTEN_ADDR` | `127.0.0.1:5006`；非 loopback 必须提供至少 32 字节令牌 |
| `HANDWRITING_ACCESS_TOKEN` | 本地默认无令牌，配置后 HTTP、静态资源和 WebSocket 均需认证 |
| `HANDWRITING_ALLOWED_ORIGINS` | 实际监听地址和 localhost 的 HTTP origin，以逗号分隔 |
| `HANDWRITING_DATA_DIR` | 平台用户可写目录中的 HandwritingWebRust / handwriting-rust |
| `HANDWRITING_FONT_DIR` | 程序旁 `font_assets/`，开发时 `assets/font_assets/`；兼容 `FONT_ASSETS_DIR` |
| `HANDWRITING_WEB_DIR` | 程序旁 `web/` 或 `app/build/web`；显式设置需包含 index.html |
| `HANDWRITING_APP_VERSION` | 程序旁 VERSION，开发时使用根目录 VERSION |
| `HANDWRITING_CONCURRENCY` | 2；文档/图片处理共享同一执行配额 |
| `HANDWRITING_MAX_ACTIVE` | 8 个 pending/processing 生成任务 |
| `HANDWRITING_TASK_TTL_SECONDS` | 1800；终态最后更新后计时，下载中保留 |
| `HANDWRITING_MAX_PIXELS` | 16000000 |
| `HANDWRITING_MAX_FILE_BYTES` | 33554432；总表单体上限为其 3 倍 |
| `HANDWRITING_MAX_ARCHIVE_BYTES` | 67108864；DOCX 解压预算 |
| `HANDWRITING_MAX_TEXT_CHARS` | 100000 |
| `HANDWRITING_MAX_PAGES` | 200 |

每个源 IP 的上传/生成接口每 5 分钟最多 200 次，其余 API 最多 600 次。来源校验覆盖 Origin、Referer、Sec-Fetch-Site 和 Host；允许的来源具有 CORS preflight 和凭据响应。任务 id 是随机访问句柄，服务没有独立账号或每用户授权模型。

## API 与生命周期

兼容原接口：`/api/fonts_info`、`/api/version`、`/api/textfileprocess`、`/api/imagefileprocess`、`/api/generate_handwriting`、`/api/generate_handwriting/task/{id}`、其 `/result` 和 `/api/generate_handwriting/ws/{id}`。生成接受 multipart 或 URL 编码表单，上传字段沿用 `file`、`font_file`、`background_image`。`GET /api/health` 返回 `rendering_available: true` 和 `algorithm_version: "1"`。

新增 `POST /api/generate_handwriting/task/{id}/cancel`。状态为 pending → processing → completed/failed/cancelled；重复取消终态任务不会改写结果。队列满返回 503、`status: queue_full` 和等待提示。错误返回 `error_code` 与 `message`；任务错误写入 `error_code`/`error_message`。核心支持显式 seed，固定构建内可复现；不保证与 Python 或其它平台逐像素一致。

SQLite `rust-tasks.db` 仅存元数据，结果放 `results/`，与 Python 数据隔离。重复下载返回相同结果；重启保留完成结果，将未完成任务标为 `interrupted`，不会恢复计算。写入先用 `.partial`，成功后提交，取消时清除未完成文件。

## 已知边界

支持中文、英文与现有数学节点，不提供复杂文字 shaping 或完整 LaTeX/Word 版式。TXT/RTF 沿用原文本读取行为；DOCX 提取正文、OMML 文本和表格；PDF 导入使用 pdf-extract。PDF 页面保留旧规则：像素宽高直接作为 point，JPEG 质量 75；多页 PDF 的编码数据仍保留在内存，不宣称恒定内存。

图片识别以横线带中心估算真实行距，空白或不稳定图片返回 `identification_unreliable`；合成与倾斜样例已经测试，真实纸张照片仍需更广泛样本验收。输入大小、图片像素和 DOCX 解压有预算；PDF 内部压缩流及字体解析没有硬隔离内存预算，处理不可信文件的公网部署仍需进程级资源限制。默认字体沿用仓库资产，字体分发权限须按各字体单独审计。

## 本机验收与性能记录

2026-10-12 在 macOS arm64 / Apple M5 / Rust 1.94.1 release 构建上验证：14 项核心测试、10 项服务测试、61 项 Flutter 测试（包含真实 Rust API）通过，Clippy 与 Flutter analyze 通过。独立服务包启动和 Docker 中的鉴权、CORS、静态页面、真实 PNG 生成已经验证。Windows/Linux/macOS CI matrix 已添加，其远程执行结果仍需 CI 验收；本机不代表所有平台已经验证。

单任务测试使用霞鹜文楷、seed 42，耗时包括提交、10 ms 间隔轮询及结果下载。800×600 样例含约百字中文、英文与公式；A4 为 2480×3508、64 px 字号、100 px 行距、约千字；3 页 PDF 使用手动分页。以下为单次记录，不是性能保证或速度提升倍数：

| 场景 | 耗时 |
| --- | --- |
| 进程到健康检查就绪，不含首次字体解析 | 0.021 s |
| 800×600 冷字体首次预览 | 0.386 s |
| 同参数暖预览 | 0.014 s |
| A4，关闭扰动 | 0.065 s |
| A4，开启位移/旋转/墨色/字号扰动 | 0.055 s |
| 3 页 A4 PDF | 0.237 s |

以 20 ms 间隔采样进程 RSS，本轮最高约 660 MiB，包含中文字体解析、页面缓冲与缓存；短请求未必覆盖采样点。这表明仍有较大的内存成本，应按机器容量配置执行配额，移动端原生接入前还需专门优化和测量。取消 API 确认耗时约 0.4 ms，100 ms 后未见任务临时文件；API 返回状态不代表所有 CPU 工作在同一瞬间停止，运行中取消测试另验证 3 s 内释放执行配额。

Python/Rust 无扰动样张和包含删除线、公式、插图滤镜的 Rust 样张已人工检查。字体度量、随机数与编码器不同，输出体积或逐像素差异不作为缺陷判据。
