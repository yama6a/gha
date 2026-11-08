#!/usr/bin/env bash
# Tests for token-scope.sh against the fixtures in .github/testdata/token-scope. Run from the repo root.
set -euo pipefail

script=.github/actions/workflow-security/token-scope.sh
fixtures=.github/testdata/token-scope
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Each row is a fixture, then the line and the message of the warning it must print, or "-" for none.
while read -r fixture line message; do
  file="$fixtures/$fixture"
  want=""
  if [ "$line" != - ]; then want="::warning file=$file,line=$line,title=token scope::$message"; fi
  got=$("$script" "$file" | grep '^::warning' || true)
  if [ "$got" != "$want" ]; then fail "$fixture: want '$want', got '$got'"; fi
done << 'TABLE'
workflow-env.yaml 3 GITHUB_TOKEN in workflow-level env. Move it to the env of the step that uses it.
job-env.yaml 6 GITHUB_TOKEN in job-level env. Move it to the env of the step that uses it.
third-party-with.yaml 9 GITHUB_TOKEN passed to third-party action aquasecurity/trivy-action.
third-party-env.yaml 8 GITHUB_TOKEN passed to third-party action some-owner/some-action.
third-party-workflow.yaml 6 GITHUB_TOKEN passed to third-party reusable workflow some-owner/workflows.
composite.yaml 12 GITHUB_TOKEN passed to third-party action some-owner/some-action.
clean.yaml -
TABLE

broken=$(mktemp)
trap 'rm -f "$broken"' EXIT
printf 'jobs: [\n' > "$broken"
if "$script" "$broken" > /dev/null 2>&1; then fail "a file yq cannot parse: want a non-zero exit"; fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all token-scope tests passed"
