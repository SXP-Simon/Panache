# 客户端与渲染引擎

Flutter 工作台负责编辑、预览、设备草稿和界面偏好。Rust 核心负责字形布局、文档导入、绘制和导出，原生客户端和浏览器版共用同一个渲染核心。

- 桌面客户端启动随包的本地 HTTP 服务。
- Android 与 iOS 通过 Dart FFI 调用 Rust 的 C ABI。
- Web 连接 Rust HTTP 服务，也可由同一服务托管页面。

当前源码在 `main`，历史 React/Python/Electron 实现在 `backup`。详见[客户端架构](https://github.com/SXP-Simon/Panache/blob/main/docs/flutter-architecture.md)。
