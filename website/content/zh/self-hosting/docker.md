# 自行部署浏览器工作台

浏览器版连接 Rust HTTP 服务。服务可以同时提供 Flutter Web 静态文件。先在仓库根目录按[构建说明](site:development)准备 Flutter 和 Rust，再运行：

```bash
(cd app && flutter pub get)
python3 scripts/build-flutter-web.py
export HANDWRITING_ACCESS_TOKEN="$(openssl rand -hex 32)"
docker compose -f deploy/rust/compose.yml up --build -d
```

在主机打开 `http://127.0.0.1:5006`。Compose 默认把端口绑定在主机回环地址，浏览器使用 Basic auth，密码为刚设置的令牌。远程访问使用 HTTPS 反向代理，保留 Host、转发 WebSocket Upgrade，并将 `HANDWRITING_ALLOWED_ORIGINS` 设为实际访问来源。

[服务配置、数据目录与代理说明](https://github.com/SXP-Simon/Panache/blob/main/deploy/rust/README.md)
