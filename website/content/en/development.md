# Local development

The current main branch uses Flutter 3.47.5, Dart 3.13.4 and Rust 1.94.1. Start the rendering service from the repository root:

```bash
cargo run --locked -p handwriting-server
```

Start the browser client in a second terminal:

```bash
cd app
flutter pub get
python3 ../scripts/build-text-worker.py
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:5006
```

Native builds also require platform SDKs. See the [client project](https://github.com/SXP-Simon/Panache/tree/main/app) and [mobile toolchains](https://github.com/SXP-Simon/Panache/blob/main/scripts/MOBILE_ENVIRONMENT.md).
