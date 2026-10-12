#!/usr/bin/env bash
# 2026-10-12：当前平台的独立服务包，不依赖 Python 运行时。
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ "${1:-}" != "--skip-web" ]]; then
  (cd app && flutter pub get && flutter build web --release)
fi
[[ -f app/build/web/index.html ]] || { echo "缺少 Flutter Web 产物，请先构建。" >&2; exit 1; }
cargo build --locked --release -p handwriting-server
PACKAGE_DIR="$PROJECT_ROOT/target/service-package"
mkdir -p "$PACKAGE_DIR/web" "$PACKAGE_DIR/font_assets" "$PACKAGE_DIR/licenses"
# 专用产物目录，每次清除旧 Web 文件，避免残留缓存。
find "$PACKAGE_DIR/web" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R app/build/web/. "$PACKAGE_DIR/web/"
cp assets/font_assets/* "$PACKAGE_DIR/font_assets/"
cp VERSION "$PACKAGE_DIR/VERSION"
cp LICENSE "$PACKAGE_DIR/LICENSE"
cp crates/handwriting-core/NOTICE "$PACKAGE_DIR/NOTICE"
cp crates/handwriting-core/licenses/* "$PACKAGE_DIR/licenses/"
cp assets/licenses/* "$PACKAGE_DIR/licenses/"
cp deploy/rust/README.md "$PACKAGE_DIR/README.md"
if [[ -f target/release/handwriting-server.exe ]]; then
  rm -f "$PACKAGE_DIR/handwriting-server.exe"
  cp target/release/handwriting-server.exe "$PACKAGE_DIR/"
else
  rm -f "$PACKAGE_DIR/handwriting-server"
  cp target/release/handwriting-server "$PACKAGE_DIR/"
fi
printf '服务包：%s\n' "$PACKAGE_DIR"
