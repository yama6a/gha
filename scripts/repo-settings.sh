#!/usr/bin/env bash
set -euo pipefail

# repo | default branch | merge commits | visibility | required status check contexts
# Contexts carry spaces and slashes, so fields are pipe-separated, contexts comma-separated.
REPOS='
airlock                     | main   | false | public  | shell,yaml,renovate-config,smoke,build
bolan-admin-fe              | master | false | private | node / node,renovate-config
bolan-api                   | main   | false | private | go / go,renovate-config
bolan-fe                    | master | false | private | node / node,e2e / e2e,renovate-config
bolan-self-crawler          | main   | false | private | go / go,renovate-config
codarr                      | main   | false | public  | go / go,node / node,renovate-config
gha                         | main   | false | public  | yaml,renovate-presets,kubeconform,shell-checks,hadolint,helm-chart-checks
longhorn-replica-affinity   | main   | false | public  | release label,go / go,chart,yaml,renovate-config
offgrid                     | main   | false | public  | helm,shell,yaml,renovate-config,chart-tests
offgrid-private             | main   | true  | private | helm,shell,yaml,renovate-config,chart-tests
pi5-k8s-sample-app          | main   | false | public  | go / go,renovate-config
pontiki-website             | main   | false | private | node / node,links,renovate-config
praxis                      | main   | false | public  | node / node,renovate-config
smartctl-exporter-multiarch | main   | false | public  | shell,docker,yaml,renovate-config
talos-raspberry-pi5         | main   | false | public  | shell,yaml,renovate-config,main-is-green
talos-raspberry-pi5-cluster | main   | false | public  | shell,yaml,renovate-config
'

OWNER=yama6a
MODE=apply
CONTEXTS=()
ROWS=()
REPO=

usage() {
  cat << 'EOF'
usage: scripts/repo-settings.sh [--dry-run | --verify]

  (no flag)   apply the settings in the table at the top of this script
  --dry-run   print every gh api call instead of running the writes
  --verify    read the settings back and print intended vs actual, exit 1 on any mismatch
EOF
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

split_contexts() {
  local raw=$1 item
  CONTEXTS=()
  while IFS= read -r item; do
    item=$(trim "$item")
    if [[ -n $item ]]; then
      CONTEXTS+=("$item")
    fi
  done <<< "${raw//,/$'\n'}"
}

join_sorted_contexts() {
  printf '%s\n' "${CONTEXTS[@]}" | LC_ALL=C sort | paste -sd, -
}

show() {
  printf 'gh api'
  printf ' %q' "$@"
  printf '\n'
}

api_write() {
  if [[ $MODE == dry-run ]]; then
    show "$@"
    return 0
  fi
  gh api "$@" > /dev/null
}

api_write_json() {
  local json=$1
  shift
  if [[ $MODE == dry-run ]]; then
    show "$@" --input -
    printf '%s\n' "$json"
    return 0
  fi
  printf '%s' "$json" | gh api "$@" --input - > /dev/null
}

repo_json() {
  jq -n --argjson merge "$1" '{
    allow_squash_merge: true,
    allow_merge_commit: $merge,
    allow_rebase_merge: false,
    allow_auto_merge: true,
    delete_branch_on_merge: true,
    squash_merge_commit_title: "PR_TITLE",
    squash_merge_commit_message: "BLANK"
  }'
}

secret_scanning_json() {
  jq -n '{
    security_and_analysis: {
      secret_scanning: {status: "enabled"},
      secret_scanning_push_protection: {status: "enabled"}
    }
  }'
}

protection_json() {
  local linear=$1
  shift
  # required_pull_request_reviews and restrictions must be present even as null, or the API 422s.
  # strict:false keeps auto-merge from needing a rebase round-trip, and no reviews lets auto-merge
  # fire on green checks for a solo owner.
  jq -n --argjson linear "$linear" --args '{
    required_status_checks: {strict: false, contexts: $ARGS.positional},
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: $linear,
    allow_force_pushes: false,
    allow_deletions: false,
    block_creations: false,
    required_conversation_resolution: false,
    lock_branch: false,
    allow_fork_syncing: false
  }' "$@"
}

main_ruleset_ids() {
  local out
  # A failed gh api still writes the error body to stdout, so drop it rather than parse it.
  if ! out=$(gh api "repos/$OWNER/$1/rulesets" \
    --jq '[.[] | select(.name == "main") | .id | tostring] | join(" ")' 2> /dev/null); then
    out=
  fi
  printf '%s' "$out"
}

disable_vulnerability_alerts() {
  local repo=$1 out
  if [[ $MODE == dry-run ]]; then
    show -X DELETE "repos/$OWNER/$repo/vulnerability-alerts"
    return 0
  fi
  if out=$(gh api -X DELETE "repos/$OWNER/$repo/vulnerability-alerts" 2>&1); then
    return 0
  fi
  case $out in
    *404*) return 0 ;;
    *)
      printf '%s\n' "$out" >&2
      return 1
      ;;
  esac
}

delete_main_rulesets() {
  local repo=$1 id ids
  # The delete needs an id, so this read runs in dry-run too and prints what would be removed.
  ids=$(main_ruleset_ids "$repo")
  for id in $ids; do
    printf 'ruleset named main: id %s\n' "$id"
    api_write -X DELETE "repos/$OWNER/$repo/rulesets/$id"
  done
}

apply_repo() {
  local repo=$1 branch=$2 merge=$3 vis=$4 linear
  if [[ $merge == true ]]; then
    linear=false
  else
    linear=true
  fi

  printf '== %s\n' "$repo"
  api_write_json "$(repo_json "$merge")" -X PATCH "repos/$OWNER/$repo"
  disable_vulnerability_alerts "$repo"
  # A private repo on a Pro plan reads back security_and_analysis: null; Secret Protection is
  # Team and Enterprise only.
  if [[ $vis == public ]]; then
    api_write_json "$(secret_scanning_json)" -X PATCH "repos/$OWNER/$repo"
  fi
  api_write_json "$(protection_json "$linear" "${CONTEXTS[@]}")" \
    -X PUT "repos/$OWNER/$repo/branches/$branch/protection"
  # A classic protection and a ruleset both apply as their union, which is stricter than the
  # protection above and blocks auto-merge.
  delete_main_rulesets "$repo"
}

cmp_field() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    return 0
  fi
  ROWS+=("$(printf '%-28s %-44s %-26s %s' "$REPO" "$name" "$want" "$got")")
}

verify_repo() {
  local repo=$1 branch=$2 merge=$3 vis=$4 linear
  local settings prot alerts rulesets
  local p_strict p_admins p_linear p_force p_delete p_block p_conv p_lock p_fork p_reviews p_restr

  if [[ $merge == true ]]; then
    linear=false
  else
    linear=true
  fi
  REPO=$repo
  ROWS=()

  settings=$(gh api "repos/$OWNER/$repo")
  cmp_field allow_squash_merge true "$(jq -r '.allow_squash_merge' <<< "$settings")"
  cmp_field allow_merge_commit "$merge" "$(jq -r '.allow_merge_commit' <<< "$settings")"
  cmp_field allow_rebase_merge false "$(jq -r '.allow_rebase_merge' <<< "$settings")"
  cmp_field allow_auto_merge true "$(jq -r '.allow_auto_merge' <<< "$settings")"
  cmp_field delete_branch_on_merge true "$(jq -r '.delete_branch_on_merge' <<< "$settings")"
  cmp_field squash_merge_commit_title PR_TITLE "$(jq -r '.squash_merge_commit_title' <<< "$settings")"
  cmp_field squash_merge_commit_message BLANK "$(jq -r '.squash_merge_commit_message' <<< "$settings")"
  cmp_field visibility "$vis" "$(jq -r '.visibility' <<< "$settings")"
  cmp_field default_branch "$branch" "$(jq -r '.default_branch' <<< "$settings")"

  if [[ $vis == public ]]; then
    cmp_field secret_scanning enabled \
      "$(jq -r '.security_and_analysis.secret_scanning.status // "none"' <<< "$settings")"
    cmp_field secret_scanning_push_protection enabled \
      "$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "none"' <<< "$settings")"
  fi

  if gh api "repos/$OWNER/$repo/vulnerability-alerts" > /dev/null 2>&1; then
    alerts=enabled
  else
    alerts=disabled
  fi
  cmp_field vulnerability_alerts disabled "$alerts"

  # A failed gh api still writes the error body to stdout, so drop it rather than parse it.
  if ! prot=$(gh api "repos/$OWNER/$repo/branches/$branch/protection" 2> /dev/null); then
    cmp_field protection configured none
  else
    read -r p_strict p_admins p_linear p_force p_delete p_block p_conv p_lock p_fork p_reviews p_restr \
      <<< "$(jq -r '[ (if .required_status_checks then .required_status_checks.strict else "none" end),
          .enforce_admins.enabled,
          .required_linear_history.enabled,
          .allow_force_pushes.enabled,
          .allow_deletions.enabled,
          .block_creations.enabled,
          .required_conversation_resolution.enabled,
          .lock_branch.enabled,
          .allow_fork_syncing.enabled,
          (if .required_pull_request_reviews then "set" else "null" end),
          (if .restrictions then "set" else "null" end)
        ] | map(tostring) | join(" ")' <<< "$prot")"

    cmp_field protection.strict false "$p_strict"
    cmp_field protection.contexts "$(join_sorted_contexts)" \
      "$(jq -r '(.required_status_checks.contexts // []) | sort | join(",") | if . == "" then "none" else . end' <<< "$prot")"
    cmp_field protection.enforce_admins false "$p_admins"
    cmp_field protection.required_pull_request_reviews null "$p_reviews"
    cmp_field protection.restrictions null "$p_restr"
    cmp_field protection.required_linear_history "$linear" "$p_linear"
    cmp_field protection.allow_force_pushes false "$p_force"
    cmp_field protection.allow_deletions false "$p_delete"
    cmp_field protection.block_creations false "$p_block"
    cmp_field protection.required_conversation_resolution false "$p_conv"
    cmp_field protection.lock_branch false "$p_lock"
    cmp_field protection.allow_fork_syncing false "$p_fork"
  fi

  rulesets=$(main_ruleset_ids "$repo")
  cmp_field 'rulesets named main' none "${rulesets:-none}"

  if [[ ${#ROWS[@]} -eq 0 ]]; then
    printf '%-28s ok\n' "$repo"
    return 0
  fi
  printf '%s\n' "${ROWS[@]}"
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

if [[ $MODE == verify ]]; then
  printf '%-28s %-44s %-26s %s\n' repo setting intended actual
fi

failed=0
while IFS='|' read -r repo branch merge vis contexts; do
  repo=$(trim "$repo")
  if [[ -z $repo ]]; then
    continue
  fi
  branch=$(trim "$branch")
  merge=$(trim "$merge")
  vis=$(trim "$vis")
  split_contexts "$contexts"

  if [[ $MODE == verify ]]; then
    verify_repo "$repo" "$branch" "$merge" "$vis" || failed=1
  else
    apply_repo "$repo" "$branch" "$merge" "$vis"
  fi
done <<< "$REPOS"

exit "$failed"
