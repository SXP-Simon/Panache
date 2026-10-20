# Handwriting generator

A cross-platform handwriting tool built with Flutter and Rust. It supports text and document import, fonts and backgrounds, layout variation, image previews, and PNG / PDF / ZIP export.

- Android / iOS use a bundled Rust engine through Dart FFI.
- Windows / macOS / Linux automatically start a bundled Rust sidecar.
- Flutter Web connects to a Rust HTTP service that can also host the UI.

## Layout

| Path | Purpose |
| --- | --- |
| `app/` | Flutter client, platform projects, and tests |
| `assets/` | Shared font assets as a Flutter package |
| `crates/` | Rust rendering core, mobile bridge, and HTTP server |
| `scripts/` | Desktop, mobile, and service build scripts |
| `deploy/rust/` | Docker and service deployment |
| `VERSION` | Product version |

## Development

Toolchain: Flutter 3.47.5 / Dart 3.13.4 and Rust 1.94.1, plus the SDK for each native platform. Python is only used by native build scripts.

```bash
# Repository root
cargo run --locked -p handwriting-server
# Another terminal
cd app
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5006
```

For cross-origin development, configure `HANDWRITING_ALLOWED_ORIGINS`. See the [client guide](app/README.md), [Rust workspace guide](crates/README.md), and [deployment guide](deploy/rust/README.md) for builds, tests, signing, and platform limitations.

The product version comes from the root `VERSION` file. The legacy release pipeline has been removed; automated releases for the rewrite are not yet configured. `CHANGELOG.md` retains historical releases.

See [LICENSE](LICENSE) and the algorithm [NOTICE](crates/handwriting-core/NOTICE). Font redistribution is subject to each font's license.
