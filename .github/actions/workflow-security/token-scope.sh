#!/usr/bin/env bash
# Warns where GITHUB_TOKEN reaches more than the one step that needs it: workflow-level or job-level
# env, or the inputs and env of a third-party action or reusable workflow. zizmor does not check
# these. Arguments are the files to check. Without any, it checks the workflows and the actions
# under .github. It exits 0 on findings, and non-zero only when yq cannot parse a file.
set -euo pipefail

# A third-party action that gets the token here needs it. Each entry is <owner/repo>:<with|env>.<key>.
allowed=(
  docker/login-action:with.password
)

export TOKEN_RE='(?i)\$\{\{[^}]*(github\.token|secrets\.github_token)'

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
  if [ -d .github ]; then
    mapfile -t -O "${#files[@]}" files < <(find .github \( -name action.yml -o -name action.yaml \) -type f | LC_ALL=C sort)
  fi
fi

# third_party prints owner/repo of a uses: value, or nothing for a run: step, a local action, a
# docker:// image or an action of GitHub or yama6a.
third_party() {
  case "$1" in
    '' | actions/* | yama6a/* | ./* | \$/* | docker://*) ;;
    *)
      local owner=${1%%/*} rest=${1#*/}
      rest=${rest%%@*}
      echo "$owner/${rest%%/*}"
      ;;
  esac
}

is_allowed() {
  local entry
  for entry in "${allowed[@]}"; do
    if [ "$entry" = "$1" ]; then return 0; fi
  done
  return 1
}

count=0
warn() {
  echo "::warning file=$1,line=$2,title=token scope::$3"
  count=$((count + 1))
}

for f in "${files[@]}"; do
  # One line per string that holds the token: its path, its line, and the uses: two levels up.
  # Two levels up from with.<key> or env.<key> is the step or job that gets the value.
  matches=$(yq -o=tsv '.. | select(tag == "!!str" and test(strenv(TOKEN_RE))) | [(path | join(".")), line, (parent | parent | .uses // "")]' "$f")
  while IFS=$'\t' read -r path line uses; do
    [ -n "$path" ] || continue
    repo=$(third_party "$uses")
    if [[ $path =~ ^env\.[^.]+$ ]]; then
      warn "$f" "$line" "GITHUB_TOKEN in workflow-level env. Move it to the env of the step that uses it."
    elif [[ $path =~ ^jobs\.[^.]+\.env\.[^.]+$ ]]; then
      warn "$f" "$line" "GITHUB_TOKEN in job-level env. Move it to the env of the step that uses it."
    elif [[ $path =~ ^(jobs\.[^.]+\.|runs\.)steps\.[0-9]+\.((with|env)\.[^.]+)$ ]]; then
      if [ -n "$repo" ] && ! is_allowed "$repo:${BASH_REMATCH[2]}"; then
        warn "$f" "$line" "GITHUB_TOKEN passed to third-party action $repo."
      fi
    elif [[ $path =~ ^jobs\.[^.]+\.(with|secrets)\.[^.]+$ ]]; then
      if [ -n "$repo" ]; then
        warn "$f" "$line" "GITHUB_TOKEN passed to third-party reusable workflow $repo."
      fi
    fi
  done <<< "$matches"
done

echo "token scope: $count finding(s) in ${#files[@]} file(s)"
