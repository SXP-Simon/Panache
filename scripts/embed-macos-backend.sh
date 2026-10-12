#!/usr/bin/env bash
# 2026-10-12：Xcode 构建 Debug/Profile/Release 时嵌入同一套 Rust 引擎。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_BIN="${CARGO:-$(command -v cargo || true)}"
if [[ -z "$CARGO_BIN" && -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO_BIN" ]]; then
  echo 'error: 未找到 cargo，请安装 Rust 工具链后重新运行 Flutter。' >&2
  exit 1
fi
# 即使 Flutter 为 Debug，也使用 release 引擎；Cargo 自身负责增量构建。
"$CARGO_BIN" build --manifest-path "$REPO_ROOT/Cargo.toml" --target-dir "$REPO_ROOT/target" --locked --release -p handwriting-server
BACKEND_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/backend"
mkdir -p "$BACKEND_DIR/font_assets" "$BACKEND_DIR/licenses"
# 不覆写已签名的 Mach-O inode，避免 macOS 命中旧签名缓存。
rm -f "$BACKEND_DIR/handwriting-server"
cp "$REPO_ROOT/target/release/handwriting-server" "$BACKEND_DIR/"
rsync -a --delete "$REPO_ROOT/backend/font_assets/" "$BACKEND_DIR/font_assets/"
rsync -a --delete "$REPO_ROOT/crates/handwriting-core/licenses/" "$BACKEND_DIR/licenses/"
cp "$REPO_ROOT/backend/VERSION" "$BACKEND_DIR/VERSION"
cp "$REPO_ROOT/crates/handwriting-core/NOTICE" "$BACKEND_DIR/NOTICE"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$REPO_ROOT/app/macos/sidecar.entitlements" "$BACKEND_DIR/handwriting-server"
