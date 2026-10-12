#!/usr/bin/env bash
# 2026-10-12：生成供现有 Python 静态托管/桌面打包读取的 Flutter Web UI。
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT/app"
flutter pub get
flutter build web --release
mkdir -p "$PROJECT_ROOT/frontend/dist"
# 替换专用构建目录，避免旧 Vue service worker 继续提供旧界面。
find "$PROJECT_ROOT/frontend/dist" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R build/web/. "$PROJECT_ROOT/frontend/dist/"
