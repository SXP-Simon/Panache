# Handwriting generator

A cross-platform handwriting tool built with Flutter and Rust. It supports text and document import, fonts and backgrounds, layout variation, image previews, and PNG / PDF / ZIP export.

- Android / iOS use a bundled Rust engine through Dart FFI.
- Windows / macOS / Linux automatically start a bundled Rust sidecar.
- Flutter Web connects to a Rust HTTP service that can also host the UI.

## Table enhancements over the original

Building on the original application's Markdown text cleanup, this fork adds a path that preserves table structure and renders two-dimensional handwritten tables:

- **Markdown to LaTeX:** choose **Tables: handwriting grid (LaTeX)** before cleanup. The existing item-list and aligned-text modes remain available.
- **Probability and formula tables:** ruled LaTeX `array` tables, including those wrapped in `\boxed{...}`, support Chinese text, numbers, and stacked fractions in cells.
- **Consistent layout:** complete outer borders and row/column lines use uniform stroke widths; rows have equal heights and cell contents are centered by their visible ink. The selected handwriting font and ink color still apply.
- **Whole-table fitting:** wide tables scale together and remain intact across page breaks. Supported empty cells and literal pipes or semicolons retain their column positions.
- **Conservative conversion:** unsupported tables remain editable text rather than losing content. Repeated cleanup and conversion preserve already converted table structures.

Use **Paste table → Clean Markdown → Convert LaTeX → Generate preview**. Existing LaTeX tables can go directly through LaTeX conversion.

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
