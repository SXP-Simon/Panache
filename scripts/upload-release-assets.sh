#!/usr/bin/env bash
# Upload verified assets to the draft and retry transient upload errors.
set -euo pipefail
shopt -s nullglob

tag="${1:-}"
if [ -z "$tag" ] || [ "$#" -lt 2 ]; then
  echo "用法: bash scripts/upload-release-assets.sh <tag> <glob> [<glob>...]" >&2
  exit 1
fi
shift

# Always upload to the explicitly selected repository.
repository="${GITHUB_REPOSITORY:-${GH_REPO:-}}"
if [ -z "$repository" ]; then
  origin_url="$(git remote get-url origin)"
  repository="${origin_url#https://github.com/}"
  repository="${repository#git@github.com:}"
  repository="${repository%.git}"
fi
if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "无法确定上传仓库，请设置 GITHUB_REPOSITORY 或 GH_REPO" >&2
  exit 1
fi

max_attempts="${UPLOAD_MAX_ATTEMPTS:-3}"
base_delay="${UPLOAD_RETRY_DELAY:-30}"

# 展开 glob。没匹配上的模式在 nullglob 下直接消失
files=()
for pattern in "$@"; do
  for file in $pattern; do
    files+=("$file")
  done
done

if [ ${#files[@]} -eq 0 ]; then
  echo "没有匹配到任何产物：$*" >&2
  exit 1
fi

echo "上传到 ${tag}："
printf '  %s\n' "${files[@]}"

# 一个文件一个文件地传：一次传多个时 gh 会整体失败，前面已经传成功的也白传；
# 分开传则每个文件各自重试，互不影响。
for file in "${files[@]}"; do
  attempt=1
  while :; do
    if gh release upload "$tag" "$file" --clobber --repo "$repository"; then
      echo "OK   $file"
      break
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "::error::$file 连续 ${max_attempts} 次上传失败，放弃" >&2
      exit 1
    fi
    delay=$((attempt * base_delay))
    echo "::warning::$file 第 ${attempt} 次上传失败，${delay}s 后重试" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
done

echo "全部产物已上传到 ${tag}"
