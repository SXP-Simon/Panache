# Docker 部署

Docker Compose 默认从本 fork 的源码构建前后端两个容器；自动更新服务按需启用。

## 前置条件

- 装了 Docker 和 Docker Compose
- 为 Docker 分配足够内存与磁盘；大纸张和长文本会增加渲染资源消耗

## 起来

```shell
git clone --branch custom-base https://github.com/SXP-Simon/Panache.git
cd handwriting-web
docker compose up -d --build frontend backend
```

默认端口是 **2345**，打开 <http://localhost:2345> 就能用。

## 服务与镜像

| 服务 | 镜像 | 作用 |
|---|---|---|
| `frontend` | `handwriting-frontend:local` | 从本地源码构建；Nginx 提供页面并转发 `/api/`，宿主机 `2345` → 容器 `80`。 |
| `backend` | `handwriting-backend:local` | 从本地源码构建；FastAPI 端口只绑定到宿主机 `127.0.0.1:5005`。 |
| `watchtower` | `containrrr/watchtower:latest` | 可选的 `auto-update` profile；仅更新带启用标签的容器。 |

前后端默认 `pull_policy: never`，不会拉取上游镜像。可用 `FRONTEND_IMAGE`、`BACKEND_IMAGE`
修改镜像标签，但仍需明确选择本地构建或远端拉取方式。

后端刻意不暴露到公网 —— 外部的请求一律先进 Nginx 再由它转发。想换个对外端口，改
`docker-compose.yml` 里 frontend 的 `"2345:80"` 左边那个数字。

## 字体

字体放在仓库根目录的 `ttf_files/`，Compose 会把它挂到容器的 `/app/font_assets_host`：

```yaml
volumes:
  - ./ttf_files:/app/font_assets_host
  - ./logs:/app/logs
```

放进去之后**重启后端容器**生效：

```shell
docker compose restart backend
```

这些字体就是界面上字体下拉框里的选项。

!!! note "为什么不直接挂载到字体目录"
    Compose 里没有把 `ttf_files` 直接挂到后端读字体的目录，而是挂到 `_host` 这个中转位置，
    由后端在启动时同步过去。直接挂载的话，容器里预置的字体会被宿主机的空目录盖掉。

## 日志

- 后端日志落在宿主机的 `./logs/`。
- 也能直接看容器的输出：

  ```shell
  docker compose logs -f backend
  ```

## 更新本地构建

确认工作区改动已妥善保存，再同步自用分支并重建：

```shell
git pull --ff-only origin custom-base
docker compose up -d --build frontend backend
```

## 可选：远端镜像自动更新

只有自行发布了镜像，才需要 Watchtower。在 `.env` 中设置自己的镜像地址和启用标签，例如：

```dotenv
FRONTEND_IMAGE=your-account/handwriting-frontend:latest
BACKEND_IMAGE=your-account/handwriting-backend:latest
WATCHTOWER_ENABLE=true
```

首次拉取并启动：

```shell
docker compose pull --policy always frontend backend
docker compose --profile auto-update up -d --no-build frontend backend watchtower
```

Watchtower 每 6 小时检查带标签的容器。私有仓库还需配置相应的拉取认证。
它通过 Docker socket 管理容器，只应在需要自动更新时启用；本地构建不依赖它。

## 停掉 / 清掉

```shell
docker compose down          # 停掉并删除容器
docker compose down -v       # 同上，另外删掉 Docker 管理的卷
```

!!! note "`-v` 删不掉你的字体和日志"
    `ttf_files` 和 `logs` 是**绑定挂载**到宿主机目录的，不属于 Docker 管理的卷，
    所以 `-v` 不会碰它们。这份 Compose 没有定义具名卷；删除本机字体或日志需自行处理对应目录。

## 反向代理和 HTTPS

Compose 里的 Nginx 只监听 HTTP。要挂到域名上、配证书，在它前面再放一层
（Caddy、Traefik，或者宿主机的 Nginx）转发到 `127.0.0.1:2345` 即可。

!!! warning "上传大文件的超时"
    长文本渲染要几十秒到几分钟。前面那层代理如果超时太短，请求会在浏览器里失败，
    但后端其实还在生成。把代理的读超时放宽一些。
