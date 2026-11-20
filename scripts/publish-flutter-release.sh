#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?}" "${TAG:?}" "${SOURCE_SHA:?}"
ref="refs/tags/$TAG"
remote_ref="$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$TAG" --jq ".[] | select(.ref == \"$ref\") | .object.sha")"
if [[ -n "$remote_ref" && "$remote_ref" != "$SOURCE_SHA" ]]; then
  echo "::error::$TAG already points at a different commit."
  exit 1
fi

if draft="$(gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json isDraft,targetCommitish --jq '[.isDraft, .targetCommitish] | @tsv' 2>/dev/null)"; then
  if [[ "$draft" != $'true\t'"$SOURCE_SHA" ]]; then
    echo "::error::$TAG already has a release other than this commit's draft."
    exit 1
  fi
else
  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --draft --target "$SOURCE_SHA" \
    --title "$TAG" --notes-file release-plan/notes.md
fi

bash scripts/upload-release-assets.sh "$TAG" 'release-assets/*' 'release-plan/Flutter-source.json'
gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
