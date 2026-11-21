# Client and rendering engine

The Flutter workbench owns editing, preview, local drafts and appearance preferences. Rust handles glyph layout, imports, drawing and export. The browser and native apps share the rendering core.

- Desktop starts a bundled local HTTP sidecar.
- Android and iOS call a Rust C ABI through Dart FFI.
- Web connects to a Rust HTTP service that can also host the client.

Current sources live on `main`. The earlier React/Python/Electron implementation is archived on `backup`. Read the [client architecture](https://github.com/SXP-Simon/Panache/blob/main/docs/flutter-architecture.md).
