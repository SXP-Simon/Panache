#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${TAG:?}" "${SOURCE_SHA:?}"
# Resolve both annotated and lightweight tags to the commit on GitHub.
remote_sha="$(gh api "repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$TAG" --jq .sha)"
if [[ "$remote_sha" != "$SOURCE_SHA" ]]; then
  echo "::error::$TAG no longer points to the checked release commit."
  exit 1
fi

if draft="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json isDraft,targetCommitish --jq '[.isDraft, .targetCommitish] | @tsv' 2>/dev/null)"; then
  if [[ "$draft" != $'true\t'"$SOURCE_SHA" ]]; then
    echo "::error::$TAG already has a release other than this commit's draft."
    exit 1
  fi
else
  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --draft --verify-tag --target "$SOURCE_SHA" \
    --title "$TAG" --notes-file release-plan/notes.md
fi

bash scripts/upload-release-assets.sh "$TAG" 'release-assets/*' 'release-plan/Flutter-source.json'
gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
