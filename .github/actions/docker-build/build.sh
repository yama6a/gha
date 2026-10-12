#!/usr/bin/env bash
# docker buildx build with the flags docker/build-push-action passes for the same inputs, and one
# retry after 5 s when a registry rate-limited the build or answered with a 5xx.
set -euo pipefail

# shellcheck source=scripts/retry.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/retry.sh"

# lines prints the non-empty lines of $1 without their surrounding whitespace.
lines() {
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ -n "$line" ]; then printf '%s\n' "$line"; fi
  done <<< "$1"
}

main() {
  local meta args=() line digest
  meta=$(mktemp)
  args+=(--metadata-file "$meta")
  if [ -n "${FILE:-}" ]; then args+=(--file "$FILE"); fi
  if [ -n "${PLATFORMS:-}" ]; then args+=(--platform "$PLATFORMS"); fi
  while IFS= read -r line; do args+=(--build-arg "$line"); done < <(lines "${BUILD_ARGS:-}")
  while IFS= read -r line; do args+=(--tag "$line"); done < <(lines "${TAGS:-}")
  while IFS= read -r line; do args+=(--output "$line"); done < <(lines "${OUTPUTS:-}")

  if [ -n "${PROVENANCE:-}" ]; then
    args+=(--attest "type=provenance,${PROVENANCE}")
  elif [ "${LOAD:-false}" != true ] && ! grep -q 'type=docker' <<< "${OUTPUTS:-}"; then
    # The default of docker/build-push-action, which buildx alone does not apply.
    if [ "${PRIVATE_REPO:-false}" = true ]; then
      args+=(--attest "type=provenance,mode=min,inline-only=true,builder-id=${BUILDER_ID}")
    else
      args+=(--attest "type=provenance,mode=max,builder-id=${BUILDER_ID}")
    fi
  fi
  case "${SBOM:-}" in
    '') ;;
    true) args+=(--attest 'type=sbom,disabled=false') ;;
    false) args+=(--attest 'type=sbom,disabled=true') ;;
    *) args+=(--attest "type=sbom,${SBOM}") ;;
  esac

  if [ "${PUSH:-false}" = true ]; then args+=(--push); fi
  if [ "${LOAD:-false}" = true ]; then args+=(--load); fi
  args+=("${CONTEXT:-.}")

  if [ -n "${HIDE_PATH:-}" ]; then
    local hidden
    hidden=$(mktemp -d -p "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")
    mv "$HIDE_PATH" "$hidden/hidden"
    # shellcheck disable=SC2064  # expand now, the locals are gone when the trap runs
    trap "mv '$hidden/hidden' '$HIDE_PATH'" EXIT
  fi

  echo "docker buildx build ${args[*]}"
  retry_run "$RETRY_RATE_LIMIT|$RETRY_REGISTRY_5XX" 5 docker buildx build "${args[@]}"

  digest=$(jq -r '."containerimage.digest" // empty' "$meta")
  echo "digest=${digest}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

main
