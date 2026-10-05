#!/usr/bin/env bash
# npm audit --audit-level=high with an allowlist. npm audit has no ignore flag, and an advisory
# with no patched release (GHSA-vfj7-8cjw-p6xm on braces is one) then fails every repo that
# pulls the package in, forever. So: JSON out, keep the high and critical advisories, which is
# what --audit-level=high exits 1 on, subtract the repo's .npm-audit-ignore, fail on the rest.
#
# .npm-audit-ignore: one GHSA id per line, reason after a `#`. Blank lines ignored.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# npm audit exits 1 whenever it finds anything, so the exit code says nothing here.
npm audit --json > "$work/audit.json" || true

if ! jq -e '.vulnerabilities | type == "object"' "$work/audit.json" > /dev/null 2>&1; then
  cat "$work/audit.json"
  echo "::error::npm audit did not return a report"
  exit 1
fi

jq -r '[.vulnerabilities[].via[] | objects
         | select(.severity == "high" or .severity == "critical")
         | .url | sub(".*/"; "")] | unique | .[]' \
  "$work/audit.json" > "$work/high.txt"

: > "$work/ignored.txt"
if [ -f .npm-audit-ignore ]; then
  sed -e 's/#.*//' -e 's/[[:space:]]//g' .npm-audit-ignore \
    | grep -v '^$' | sort -u > "$work/ignored.txt" || true
fi

while read -r id; do
  echo "::warning::$id is in .npm-audit-ignore but npm audit no longer reports it as high or critical; drop the entry"
done < <(comm -13 "$work/high.txt" "$work/ignored.txt")

unfixed="$(comm -23 "$work/high.txt" "$work/ignored.txt")"
if [ -z "$unfixed" ]; then
  echo "npm audit: no high or critical advisories outside .npm-audit-ignore"
  exit 0
fi

for id in $unfixed; do
  jq -r --arg id "$id" '
    [.vulnerabilities[].via[] | objects | select(.url | endswith("/" + $id))] as $a
    | "\($id) (\($a[0].severity)): \($a[0].title)",
      "  \($a[0].url)",
      ($a | map("  \(.name) \(.range)") | unique | .[])
  ' "$work/audit.json"
done

echo "::error::npm audit: high or critical advisories not in .npm-audit-ignore: $(paste -sd ' ' <<< "$unfixed")"
exit 1
