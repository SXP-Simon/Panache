# 手写工作台前端

`custom-base` 使用 React、TypeScript 与 Vite。客户端状态由 Zustand 管理，
服务端数据由 TanStack Query 管理，请求使用 Fetch，数据校验使用 Valibot。
界面复用项目样式、Tailwind CSS、Motion 与 Lucide，统一使用霞鹜文楷。
纸张内的手写字体由用户选择，独立于界面字体。

## 模块入口

| 目录 / 文件 | 职责 |
|---|---|
| `src/main.tsx` | 恢复本地数据、安装保存订阅和 Provider |
| `src/App.tsx`、`src/components/` | 界面与局部交互，按字段订阅业务状态 |
| `src/features/` | 分域 store、配置与预设、任务观测、工作区操作编排 |
| `src/api/` | 请求契约、响应校验、Query key 与请求配置 |
| `src/persistence/` | 记录协议、存储适配、二进制资源快照与生命周期 |
| `src/shared/` | 通用界面、图标与动效 |
| `src/utils/`、`src/i18n.ts` | 纯转换工具与中英文案 |
| `worker/` | Web 应用外壳的离线缓存 |

组件局部状态负责弹窗、折叠和未提交的输入文本；业务 store 负责共享客户端状态；
Query 缓存负责服务端数据。Context 提供语言与稳定操作入口，不承载整份工作区状态。
正文与参数通过独立持久化流程保存，未使用 Zustand persist 自动序列化全部 store。

Web 元数据存入 localStorage，插图、上传字体和背景存入 IndexedDB；桌面版通过
受限存储桥写入应用数据目录。详情见[架构与技术栈](../docs/architecture.md)，
English: [Architecture and Technology Stack](../docs/en/architecture.md)。

## 开发与检查

以下命令在仓库根目录执行；环境安装与后端启动见[本地开发](../docs/development.md)。

```bash
pnpm install --frozen-lockfile
pnpm --filter handwrite run serve
pnpm --filter handwrite run typecheck
pnpm --filter handwrite run lint
pnpm --filter handwrite run format:check
pnpm --filter handwrite run build
```

开发入口为 `http://127.0.0.1:8080`，Vite 将 `/api` 代理至 `127.0.0.1:5005`。
生产构建输出到 `frontend/dist/`；Web 由 Nginx 提供静态文件，桌面由内置后端同源提供。
