#!/usr/bin/env bash
# 验证当前 Compose 的 Nginx、Gunicorn、真实渲染及统一日志，不发布镜像。
set -euo pipefail

BASE_URL="${DOCKER_SMOKE_URL:-http://127.0.0.1:2345}"
OUTPUT="${DOCKER_SMOKE_OUTPUT:-preview_outputs/docker-smoke}"
mkdir -p "$OUTPUT"

curl --fail --silent --show-error --retry 60 --retry-delay 2 --retry-all-errors \
  --max-time 10 "$BASE_URL/api/version" -o "$OUTPUT/version.json"
curl --fail --silent --show-error "$BASE_URL/api/fonts_info" -o "$OUTPUT/fonts.json"
curl --fail --silent --show-error "$BASE_URL/" -o "$OUTPUT/index.html"
curl --fail --silent --show-error "$BASE_URL/compose-spa-smoke" -o "$OUTPUT/spa.html"
cmp "$OUTPUT/index.html" "$OUTPUT/spa.html"
grep -F 'id="app"' "$OUTPUT/index.html"

python3 - "$OUTPUT" <<'PY'
import json
import re
import sys
from pathlib import Path

output = Path(sys.argv[1])
assert json.loads((output / "version.json").read_text())["version"] == Path("backend/VERSION").read_text().strip()
fonts = json.loads((output / "fonts.json").read_text())
assert isinstance(fonts, list) and fonts and all(isinstance(font, str) for font in fonts)
entry = re.search(r'<script[^>]+src="([^"]+\.js)"', (output / "index.html").read_text())
assert entry and "/assets/" in entry[1]
(output / "entry.txt").write_text(entry[1])
PY
curl --fail --silent --show-error "$BASE_URL$(cat "$OUTPUT/entry.txt")" -o "$OUTPUT/entry.js"
for worker in service-worker.js sw.js studio-worker.js; do
  curl --fail --silent --show-error --dump-header "$OUTPUT/$worker.headers" \
    "$BASE_URL/$worker" -o "$OUTPUT/$worker"
  grep -Eiq '^cache-control:.*no-cache' "$OUTPUT/$worker.headers"
done

FONT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[0])' "$OUTPUT/fonts.json")"
curl --fail --silent --show-error -X POST "$BASE_URL/api/generate_handwriting" \
  --form-string 'text=容器 smoke x² + √(a/b)' --form-string "font_option=$FONT" \
  --form-string 'font_size=40' --form-string 'line_spacing=60' \
  --form-string 'fill=(0,0,0,255)' --form-string 'left_margin=15' \
  --form-string 'right_margin=15' --form-string 'top_margin=15' \
  --form-string 'bottom_margin=15' --form-string 'word_spacing=1' \
  --form-string 'line_spacing_sigma=0' --form-string 'font_size_sigma=0' \
  --form-string 'word_spacing_sigma=0' --form-string 'perturb_x_sigma=0' \
  --form-string 'perturb_y_sigma=0' --form-string 'perturb_theta_sigma=0' \
  --form-string 'preview=true' --form-string 'full_preview=false' \
  --form-string 'isUnderlined=false' --form-string 'width=400' \
  --form-string 'height=300' -o "$OUTPUT/created.json"
TASK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["task_id"])' "$OUTPUT/created.json")"
STATUS=""
for attempt in $(seq 1 90); do
  curl --fail --silent --show-error "$BASE_URL/api/generate_handwriting/task/$TASK" -o "$OUTPUT/task.json"
  STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["task_status"])' "$OUTPUT/task.json")"
  case "$STATUS" in
    completed) break ;;
    failed) cat "$OUTPUT/task.json"; exit 1 ;;
  esac
  sleep 1
done
if [ "$STATUS" != completed ]; then
  cat "$OUTPUT/task.json"
  echo "Generation timed out" >&2
  exit 1
fi
curl --fail --silent --show-error --dump-header "$OUTPUT/preview.headers" \
  "$BASE_URL/api/generate_handwriting/task/$TASK/result" -o "$OUTPUT/preview.png"
grep -Eiq '^content-type: image/png' "$OUTPUT/preview.headers"
docker compose cp "$OUTPUT/preview.png" backend:/tmp/compose-smoke.png
docker compose exec -T backend python -c 'from PIL import Image; image=Image.open("/tmp/compose-smoke.png").convert("RGB"); assert image.size == (400,300), image.size; assert min(channel[0] for channel in image.getextrema()) < 220; print("PNG pixels verified", image.size)'

docker compose logs --no-color backend > "$OUTPUT/backend.log" 2>&1
docker compose exec -T backend sh -c 'cat logs/app-*.log' > "$OUTPUT/files.log"
python3 - "$OUTPUT" "$TASK" <<'PY'
import re
import sys
from pathlib import Path

output = Path(sys.argv[1])
for filename in ("backend.log", "files.log"):
    logs = (output / filename).read_text(encoding="utf-8")
    assert "\x1b[" not in logs, filename
    for source in ("gunicorn.error", "uvicorn.access", "app"):
        assert re.search(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \| \[[A-Z]+\s*\] \| " + re.escape(source) + r" \| .+:\d+ \| .+\(\) \|", logs), (filename, source)
    for event in ("started", "completed"):
        marker = f"Generation task {event}, task_id={sys.argv[2]}"
        assert logs.count(marker) == 1, (filename, marker)
print("Compose SPA/API/PNG and Gunicorn unified logs verified")
PY
