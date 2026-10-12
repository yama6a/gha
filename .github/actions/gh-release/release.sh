#!/usr/bin/env bash
# gh release create, tried up to three times on an HTTP 5xx. A failed create can still leave a
# release or a draft behind, so every retry cleans up or finishes that first.
set -euo pipefail

# shellcheck source=scripts/retry.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/retry.sh"

: "${TAG:?}" "${TARGET:?}" "${GH_REPO:?}"
title=${TITLE:-$TAG}

files=()
while IFS= read -r file; do
  if [ -n "$file" ]; then files+=("$file"); fi
done <<< "${FILES:-}"

args=("$TAG" "${files[@]}" --target "$TARGET" --title "$title")
if [ -n "${NOTES:-}" ]; then args+=(--notes "$NOTES"); fi
if [ "${GENERATE_NOTES:-false}" = true ]; then args+=(--generate-notes); fi

# gh uploads assets to a draft and publishes it last. A draft carries an untagged-* tag name,
# so gh release view TAG cannot find it, and the only match left is its name and target.
delete_drafts() {
  local releases id
  releases=$(retry_run "$RETRY_GH_5XX" "5 15" gh api --paginate "repos/${GH_REPO}/releases")
  for id in $(jq -r --arg name "$title" --arg target "$TARGET" \
    '.[] | select(.draft and .name == $name and .target_commitish == $target) | .id' <<< "$releases"); do
    echo "deleting draft release $id left by the failed try"
    retry_run "$RETRY_GH_5XX" "5 15" gh api -X DELETE "repos/${GH_REPO}/releases/${id}"
  done
}

# Succeeds when the failed try still published the release, after uploading what it lacks.
finish_published() {
  local assets file missing=()
  assets=$(retry_run "$RETRY_GH_5XX" "5 15" gh release view "$TAG" --json assets --jq '.assets[].name') || return 1
  for file in "${files[@]}"; do
    if ! grep -qxF -- "$(basename "$file")" <<< "$assets"; then missing+=("$file"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    retry_run "$RETRY_GH_5XX" "5 15" gh release upload "$TAG" "${missing[@]}" --clobber
  fi
  echo "release $TAG exists, created by the failed try"
}

log=$(mktemp)
trap 'rm -f "$log"' EXIT
for wait in 5 15 ''; do
  : > "$log"
  code=0
  retry_capture "$log" gh release create "${args[@]}" || code=$?
  if [ "$code" -eq 0 ]; then exit 0; fi
  if [ -z "$wait" ] || ! retry_matches "$RETRY_GH_5XX" "$log"; then exit "$code"; fi
  echo "::warning::gh release create failed with a transient error, trying again in ${wait}s" >&2
  sleep "$wait"
  delete_drafts
  if finish_published; then exit 0; fi
done
