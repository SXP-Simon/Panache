# Handwriting Web Backend

手写生成服务后端，使用 Python 3.12+ 与 FastAPI。架构与存储边界见
[架构与技术栈](../docs/architecture.md)，开发与验证入口见[本地开发](../docs/development.md)。

## 启动与检查

```bash
# 仓库根目录：准备依赖与 .venv
uv sync --locked --extra dev
cd backend
uv run --project .. uvicorn app:app --reload --host 127.0.0.1 --port 5005
```

以下检查从仓库根目录运行：

```bash
pnpm run quality:python
uv run --extra dev python -m pytest backend/tests
```

## 接口

| 接口 | 方法 | 说明 |
|---|---|---|
| `/api/generate_handwriting` | POST | 提交任务并返回任务 ID |
| `/api/generate_handwriting/task/{task_id}` | GET | 查询任务状态 |
| `/api/generate_handwriting/task/{task_id}/result` | GET | 获取生成结果 |
| `/api/generate_handwriting/ws/{task_id}` | WebSocket | 观测任务进度 |
| `/api/fonts_info` | GET | 获取可用字体列表 |
| `/api/version` | GET | 获取应用版本 |
| `/api/textfileprocess` | POST | 提取文档正文 |
| `/api/imagefileprocess` | POST | 检测背景边距与行距 |

请求字段与校验以 `task_types.py` 为准，路由与生成编排在 `app.py`，
任务持久化在 `task_store.py`，数学字形与页面排版在独立的 `math_*.py` 和 `symbol_fallback.py` 中。

## 队列与资源

任务存入 SQLite，由信号量限制同时执行的渲染数量；队列满时返回 `503`，
CPU 过载或接口限流时返回 `429`。默认并发、容量和过期规则见
[字体与资源限制](../docs/self-hosting/fonts-and-limits.md)。

服务端数据生命周期与编辑器草稿独立。WebSocket 不可用时，前端通过状态接口轮询。
客户端取消观测不代表删除服务端任务。

## 压测

先在另一终端启动本地后端。以下命令从仓库根目录运行；Locust 通过临时依赖执行，
不加入应用运行依赖。

```bash
# 完整流程：提交、等待、获取结果
uv run --extra dev --with locust locust -f backend/tests/locustfile.py --host=http://127.0.0.1:5005 --headless -u 8 -r 1 --run-time 60s HandwritingUser

# 仅提交任务：观察队列达到上限时的拒绝行为
uv run --extra dev --with locust locust -f backend/tests/locustfile.py --host=http://127.0.0.1:5005 --headless -u 8 -r 1 --run-time 30s HandwritingSubmitOnly

# 交互模式：打开 http://127.0.0.1:8089
uv run --extra dev --with locust locust -f backend/tests/locustfile.py --host=http://127.0.0.1:5005 HandwritingUser

# pytest 并发流程验证：需要实际运行的后端
uv run --extra dev python -m pytest backend/tests/test_generate_concurrency.py -v
```

Locust 的 `-u` 是并发用户数、`-r` 是每秒启动用户数、`--run-time` 是运行时长；
末尾的类名选择场景。仅提交场景不会等待渲染完成，因此会持续增加服务端负载。
评估结果需同时记录机器、容器配额、字体、纸张尺寸和文本长度，不能把某次耗时当作固定性能保证。

pytest 场景可通过 `HANDWRITING_BASE_URL`、`HANDWRITING_LOAD_REQUESTS`、
`HANDWRITING_LOAD_CONCURRENCY`、`HANDWRITING_TASK_TIMEOUT`、`HANDWRITING_POLL_INTERVAL`
和 `HANDWRITING_TEXT_REPEAT` 配置目标与负载。
