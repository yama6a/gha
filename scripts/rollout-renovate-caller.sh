#!/usr/bin/env bash
set -euo pipefail

# repo | default branch | allowed-commands (chart-lock, or empty)
REPOS='
airlock                     | main   |
bolan-admin-fe              | master |
bolan-api                   | main   |
bolan-fe                    | master |
bolan-self-crawler          | main   |
codarr                      | main   |
longhorn-replica-affinity   | main   |
offgrid                     | main   | chart-lock
offgrid-private             | main   | chart-lock
pi5-k8s-sample-app          | main   |
pontiki-website             | main   |
praxis                      | main   |
smartctl-exporter-multiarch | main   |
talos-raspberry-pi5         | main   |
talos-raspberry-pi5-cluster | main   |
'

OWNER=yama6a
MODE=apply
FILE=.github/workflows/renovate.yaml
HEAD_BRANCH=renovate-caller
TEMPLATE=$(dirname "$0")/../templates/renovate.yaml

usage() {
  cat << 'EOF2'
usage: scripts/rollout-renovate-caller.sh [--dry-run | --verify]

  (no flag)   open and auto-merge a PR in every repo whose renovate.yaml differs from the template
  --dry-run   print the rendered file and every write instead of running it
  --verify    print intended vs actual, exit 1 on any mismatch
EOF2
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

show() {
  printf 'gh'
  printf ' %q' "$@"
  printf '\n'
}

render() {
  local allowed=$1
  case $allowed in
    '')
      grep -v '__ALLOWED_COMMANDS__' "$TEMPLATE"
      ;;
    chart-lock)
      # This input, not renovate.json5, is what authorizes the postUpgradeTasks command to run.
      sed "s|__ALLOWED_COMMANDS__|allowed-commands: '[\"^find \\\\\\\\. -name Chart\\\\\\\\.lock -exec sed -i \"]'|" "$TEMPLATE"
      ;;
    *)
      printf 'unknown allowed-commands key: %s\n' "$allowed" >&2
      return 1
      ;;
  esac
}

current() {
  local repo=$1 branch=$2
  # A failed gh api still writes the error body to stdout, so drop it rather than parse it.
  gh api "repos/$OWNER/$repo/contents/$FILE?ref=$branch" --jq '.content' 2> /dev/null | base64 -d || true
}

apply_repo() {
  local repo=$1 branch=$2 allowed=$3 rendered base_sha file_sha
  rendered=$(render "$allowed")
  if [[ $rendered == "$(current "$repo" "$branch")" ]]; then
    printf '%-28s ok\n' "$repo"
    return 0
  fi
  printf '== %s\n' "$repo"
  if [[ $MODE == dry-run ]]; then
    printf '%s\n' "$rendered"
    show api -X DELETE "repos/$OWNER/$repo/git/refs/heads/$HEAD_BRANCH"
    show api -X POST "repos/$OWNER/$repo/git/refs" -f "ref=refs/heads/$HEAD_BRANCH" -f "sha=<$branch>"
    show api -X PUT "repos/$OWNER/$repo/contents/$FILE" -f "branch=$HEAD_BRANCH" -f 'message=Move to one Renovate run and grant copilot-requests' -f 'content=<base64>' -f 'sha=<current>'
    show pr create --repo "$OWNER/$repo" --base "$branch" --head "$HEAD_BRANCH" --title 'Move to one Renovate run and grant copilot-requests' --body ''
    show pr merge --repo "$OWNER/$repo" "$HEAD_BRANCH" --squash --auto
    return 0
  fi
  gh api -X DELETE "repos/$OWNER/$repo/git/refs/heads/$HEAD_BRANCH" > /dev/null 2>&1 || true
  base_sha=$(gh api "repos/$OWNER/$repo/git/ref/heads/$branch" --jq '.object.sha')
  gh api -X POST "repos/$OWNER/$repo/git/refs" -f "ref=refs/heads/$HEAD_BRANCH" -f "sha=$base_sha" > /dev/null
  file_sha=$(gh api "repos/$OWNER/$repo/contents/$FILE?ref=$branch" --jq '.sha')
  gh api -X PUT "repos/$OWNER/$repo/contents/$FILE" \
    -f "branch=$HEAD_BRANCH" \
    -f 'message=Move to one Renovate run and grant copilot-requests' \
    -f "content=$(printf '%s\n' "$rendered" | base64 | tr -d '\n')" \
    -f "sha=$file_sha" > /dev/null
  gh pr create --repo "$OWNER/$repo" --base "$branch" --head "$HEAD_BRANCH" \
    --title 'Move to one Renovate run and grant copilot-requests' --body ''
  gh pr merge --repo "$OWNER/$repo" "$HEAD_BRANCH" --squash --auto
}

verify_repo() {
  local repo=$1 branch=$2 allowed=$3
  if [[ $(render "$allowed") == "$(current "$repo" "$branch")" ]]; then
    printf '%-28s ok\n' "$repo"
    return 0
  fi
  printf '%-28s %s differs from templates/renovate.yaml\n' "$repo" "$FILE"
  return 1
}

case ${1-} in
  --dry-run) MODE=dry-run ;;
  --verify) MODE=verify ;;
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *)
    usage >&2
    exit 2
    ;;
esac

failed=0
while IFS='|' read -r repo branch allowed; do
  repo=$(trim "$repo")
  if [[ -z $repo ]]; then
    continue
  fi
  branch=$(trim "$branch")
  allowed=$(trim "${allowed-}")

  if [[ $MODE == verify ]]; then
    verify_repo "$repo" "$branch" "$allowed" || failed=1
  else
    apply_repo "$repo" "$branch" "$allowed"
  fi
done <<< "$REPOS"

exit "$failed"
