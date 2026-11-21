# 本地开发

当前主线使用 Flutter 3.47.5、Dart 3.13.4 和 Rust 1.94.1。从仓库根目录启动本地渲染服务：

```bash
cargo run --locked -p handwriting-server
```

在另一个终端启动浏览器客户端：

```bash
cd app
flutter pub get
python3 ../scripts/build-text-worker.py
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5006
```

桌面和移动构建各自需要平台 SDK。入口见[客户端工程](https://github.com/SXP-Simon/Panache/tree/main/app)和[移动开发环境](https://github.com/SXP-Simon/Panache/blob/main/scripts/MOBILE_ENVIRONMENT.md)。
