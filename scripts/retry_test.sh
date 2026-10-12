#!/usr/bin/env bash
# Tests for scripts/retry.sh and the gh-release action. Run from the repo root.
set -euo pipefail

# shellcheck source=scripts/retry.sh
source scripts/retry.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

sleep() { :; }
export -f sleep

docker_patterns="$RETRY_RATE_LIMIT|$RETRY_REGISTRY_5XX"
logs=.github/testdata/retry
while read -r log pattern want; do
  got=no
  if retry_matches "${!pattern}" "$logs/$log"; then got=yes; fi
  if [ "$got" != "$want" ]; then fail "$log against $pattern: want $want, got $got"; fi
done << 'TABLE'
docker-rate-exceeded.log docker_patterns yes
docker-data-limit.log docker_patterns yes
docker-429.log docker_patterns yes
docker-503.log docker_patterns yes
docker-build-error.log docker_patterns no
gh-500.log RETRY_GH_5XX yes
gh-422.log RETRY_GH_5XX no
composer-curl.log RETRY_NETWORK yes
composer-502.log RETRY_NETWORK yes
composer-advisory.log RETRY_NETWORK no
docker-build-error.log RETRY_NETWORK no
TABLE

# flaky prints the log $1 to stderr and exits with $2 on the first $3 calls, then succeeds.
flaky() {
  local n
  n=$(($(cat "$work/calls" 2> /dev/null || echo 0) + 1))
  echo "$n" > "$work/calls"
  if [ "$n" -le "$3" ]; then
    cat "$1" >&2
    return "$2"
  fi
  echo built
}

run_case() {
  local name=$1 waits=$2 log=$3 code=$4 fails=$5 want_code=$6 want_calls=$7 out got_code=0
  rm -f "$work/calls"
  out=$(retry_run "$docker_patterns" "$waits" flaky "$logs/$log" "$code" "$fails" 2> /dev/null) || got_code=$?
  if [ "$got_code" != "$want_code" ]; then fail "$name: exit code $got_code, want $want_code"; fi
  if [ "$(cat "$work/calls")" != "$want_calls" ]; then fail "$name: $(cat "$work/calls") tries, want $want_calls"; fi
  if [ "$want_code" = 0 ] && [ "$out" != built ]; then fail "$name: stdout '$out', want 'built'"; fi
}

run_case "rate limit once, then success" 5 docker-rate-exceeded.log 1 1 0 2
run_case "build error fails at once" 5 docker-build-error.log 7 9 7 1
run_case "rate limit on every try" 5 docker-429.log 1 9 1 2
run_case "three tries on 5xx" "5 15" docker-503.log 1 9 1 3

# A fake gh that keeps its releases in $STATE. SCENARIO picks what the first create does.
mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'GH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE/calls"
case "$1 $2" in
  "release create")
    case "$SCENARIO:$(grep -c '^release create' "$STATE/calls")" in
      draft:1)
        # What a 500 between creating the draft and uploading the first asset leaves behind.
        echo '[{"id":101,"draft":true,"name":"7","target_commitish":"abc123","tag_name":"untagged-c1f81ffb6b70202c7e9b","assets":[]},
               {"id":55,"draft":true,"name":"draft by hand","target_commitish":"abc123","tag_name":"untagged-1"}]' > "$STATE/releases"
        echo 'HTTP 500: Internal Server Error (https://api.github.com/repos/o/r/releases)' >&2
        exit 1
        ;;
      published:1)
        touch "$STATE/published"
        echo 'HTTP 502: Bad Gateway (https://uploads.github.com/repos/o/r/releases/1/assets)' >&2
        exit 1
        ;;
      invalid:1)
        echo 'HTTP 422: Validation Failed (https://api.github.com/repos/o/r/releases)' >&2
        exit 1
        ;;
      *) touch "$STATE/published" ;;
    esac
    ;;
  "release view")
    if [ ! -f "$STATE/published" ]; then
      echo 'release not found' >&2
      exit 1
    fi
    ;;
  "api --paginate") cat "$STATE/releases" 2> /dev/null || echo '[]' ;;
  "api -X")
    jq --argjson id "${4##*/}" 'map(select(.id != $id))' "$STATE/releases" > "$STATE/releases.new"
    mv "$STATE/releases.new" "$STATE/releases"
    ;;
esac
GH
chmod +x "$work/bin/gh"
touch "$work/app.phar"

release_case() {
  local scenario=$1 want_code=$2 got_code=0
  export STATE="$work/$scenario" SCENARIO=$scenario
  mkdir -p "$STATE"
  PATH="$work/bin:$PATH" GH_REPO=o/r TAG=7 TARGET=abc123 FILES="$work/app.phar" \
    bash .github/actions/gh-release/release.sh > /dev/null 2>&1 || got_code=$?
  if [ "$got_code" != "$want_code" ]; then fail "gh-release $scenario: exit code $got_code, want $want_code"; fi
}

release_case draft 0
if [ "$(grep -c '^release create' "$work/draft/calls")" != 2 ]; then fail "gh-release draft: want a second create"; fi
if [ "$(jq -c 'map(.id)' "$work/draft/releases")" != '[55]' ]; then
  fail "gh-release draft: want only draft 101 deleted, left $(jq -c 'map(.id)' "$work/draft/releases")"
fi

release_case published 0
if [ "$(grep -c '^release create' "$work/published/calls")" != 1 ]; then fail "gh-release published: created twice"; fi
if ! grep -qx "release upload 7 $work/app.phar --clobber" "$work/published/calls"; then
  fail "gh-release published: the missing asset was not uploaded"
fi

release_case invalid 1
if [ "$(wc -l < "$work/invalid/calls")" != 1 ]; then fail "gh-release invalid: a 422 must not be retried"; fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all retry tests passed"
