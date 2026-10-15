# 本地开发

!!! info "深度内容在 AGENTS.md"
    这一页只讲怎么把项目跑起来。架构细节、编码约定、部署流水线、各类踩坑记录，
    都在仓库根的 [`AGENTS.md`](https://github.com/14790897/handwriting-web/blob/main/AGENTS.md) ——
    改代码之前先读它。

## 环境要求

- **Python 3.10 或 3.11**（3.8 – 3.13 都能跑）
- **Node.js 20 或更高**（E2E 用的 Playwright 有这个要求）

## 起后端（5005）

**必须用仓库里的 venv，不要用系统 Python。** 系统环境里的 `fastapi` + `starlette`
版本组合会让应用起不来，报 `TypeError: Router.__init__() got an unexpected keyword argument 'on_startup'`。

第一次先建虚拟环境并装依赖：

```shell
python -m venv venv
venv/Scripts/python.exe -m pip install -r backend/requirements.txt
```

（Linux / macOS 把 `venv/Scripts/python.exe` 换成 `venv/bin/python`。）

然后启动：

```shell
cd backend
../venv/Scripts/python.exe -m uvicorn app:app --reload --host 0.0.0.0 --port 5005
```

## 起前端（8080）

```shell
cd frontend
npm install
npm run serve
```

打开 <http://localhost:8080>。前端的开发服务器会把 `/api` 代理到 `127.0.0.1:5005`，
所以本地不需要配跨域。

VS Code 用户可以直接按 `Ctrl+Shift+B`，有现成的任务可以并行拉起前后端。

## 跑测试

**后端单元测试** ——

```shell
cd backend
../venv/Scripts/python.exe -m pytest
```

**端到端测试（Playwright）** —— `e2e/` 目录会用**真实的前后端**跑完整流程
（真的渲染图片、真的下载附件），少数难以真实触发的分支（比如队列满的 503）用路由拦截模拟。

```shell
cd e2e
npm install
npx playwright install chromium
npm test
```

- 没在跑的开发服务器会被自动拉起来（后端 5005、前端 8080），跑完自动关掉。
- 已经在跑的会被复用，不会重复启动。
- 测试期间会设 `CPU_USAGE_LIMIT=100`，免得开发机被 webpack 占满 CPU 时误触发后端的过载保护。
- 失败的截图、录像和 trace 在 `e2e/test-results/`，HTML 报告用 `npm run report` 打开。
- 找不到 Python 解释器时用 `E2E_PYTHON` 指定。

每个 PR 会由 `.github/workflows/e2e.yml` 自动跑一遍。

**桌面版端到端** —— 驱动的是真实打包产物，得先构建：

```shell
bash desktop/build.sh --app-only
cd e2e && npm run test:desktop
```

## 代码大概长什么样

| 位置 | 内容 |
|---|---|
| `frontend/src/views/HomeView.vue` | 主页面，参数、预览、生成流程都在这里 |
| `frontend/src/views/TextInput.vue` | 文字输入框 + 文档上传 |
| `frontend/src/components/` | 书信排版、生成状态、启动动画、PWA 安装提示 |
| `frontend/src/i18n.js` | 中英文案 |
| `backend/app.py` | 全部路由 + 渲染逻辑（约 1300 行） |
| `backend/task_store.py` | SQLite 任务队列（WAL，30 分钟过期） |
| `backend/identify.py` | 从背景图里检测边距和行距 |
| `backend/pdf.py` | 生成 PDF |

请求进来后：提交任务 → 写进 SQLite → 立刻返回 `task_id` → 后台协程排队渲染
→ 前端通过 WebSocket（连不上就轮询）拿进度 → 完成后取结果。

## 数学转换与维护边界（2026-10-15）

Vue/Python 版本的链路是：输入 → 可选 Markdown 清洗 → 用户点击 LaTeX 转换 →
Unicode 数学文本 → 后端动态分式/根式字形 → 手写图片。上传 Word 使用另一条提取链路；
后端并非完整 LaTeX 解释器，直接调用 API 时只额外识别有限的分式和根式语法。

本次审查发现并修复了以下会改变内容的问题：

| 原问题 | 当前行为 |
|---|---|
| 先删公式定界符，再将含公式的整行解析，导致英文正文丢空格 | 共享扫描器只解析公式范围，代码、网址、路径及图片保持原文 |
| Markdown 把 `$a<b>c$` 当 HTML，把公式竖线当表格列 | 清洗前暂存公式，清洗后完整恢复；不完整或超限公式也保护 |
| `a^b` 变成 `ab`，`x_A` 变成 `xA` | 全部字符有对应字形才使用 Unicode，否则输出 `a^(b)`、`x_(A)` |
| 组合数被写成分式，复合底数的幂丢分组 | `\binom{n}{k}` 输出 `C(n, k)`，`{a+b}^2` 输出 `(a+b)²` |
| 数学字体、分段条件或未知 AST 内容丢失 | 支持黑板体集合、分段函数、嵌套矩阵及常见注释；未知节点保留整段公式源码 |
| 日期/URL 误识别为分数，`2√x` 的系数被吞 | 普通文字范围跳过数学转换，只有上标根指数作为指数处理 |
| 第 513 个动态分式与根式私用字符碰撞 | 使用不重叠的辅助私用区，注册表有数量与深度上限，保留已有引用 |

矩阵和分段函数目前以列间空格、行间分号线性化；带增广分隔线、取消线、未支持字体或
未知命令的公式保留源码。输出不是完整二维 TeX 排版，嵌套公式的高度/基线、组合附加符
与罕见 Unicode 字形仍取决于渲染器和可用字体。不要把“能解析”当成“已正确绘制”。

扫描器的单段公式限制为 32768 字符/64 层；AST 转换进一步限制为 16000 字符/64 层、
500 次宏展开，超限保留源码。后端数学深度限制为 48，分式和根式注册预算各最多约 4096 项，
饱和后新表达式回退可读源码，已有节点继续有效。KaTeX 的 `__parse` 是内部 API，升级依赖时
必须运行语义回归；错误与展开限制参考 [KaTeX 配置](https://katex.org/docs/options)。

```shell
pnpm --filter handwrite run test:latex-unicode
pnpm --filter handwrite run test:clean-markdown
uv run --extra dev python -m pytest backend/tests
pnpm --filter handwriting-web-e2e exec playwright test tests/math-support.spec.js
```

独立 `flutter` 分支保留 HakimYu 的 Flutter/Rust 迁移。本轮强化针对 Vue/Python，尚未移植到
Dart/Rust。迁移版仍存在正文空格、未知上下标、高次根及私用分数字符不一致的问题；
`Math.tex` 预览和 Rust 最终出图也不是同一套数学排版能力，应在迁移这些回归后再评估替代。

## 提交约定

- **Commit message 必须遵循 [Conventional Commits](https://www.conventionalcommits.org/)** ——
  发版号由 semantic-release 根据它自动决定，写错了版本就升错。
- 用户可见的文字要**同时提供中英文**，加在 `frontend/src/i18n.js`。
- 需要被 E2E 点到的元素加 `data-testid`，测试侧只用 `getByTestId`，不要依赖文案或 CSS 类。
- 不要手工改 `CHANGELOG.md` 和版本号 —— 它们由发版流程维护。
