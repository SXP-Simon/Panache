{{flutter_js}}
{{flutter_build_config}}
// 使用构建产物中的 CanvasKit，桌面版无需从 CDN 加载渲染引擎。
_flutter.loader.load({config: {canvasKitBaseUrl: 'canvaskit/'}});
