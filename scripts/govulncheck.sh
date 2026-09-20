#!/usr/bin/env bash
# govulncheck with an allowlist. govulncheck has no ignore flag, and an advisory whose OSV
# record carries no fixed version (GO-2026-6452 is one) then fails every repo that calls the
# symbol, forever. So: JSON out, keep the findings that have a call trace, which is what plain
# govulncheck exits 3 on, subtract the repo's .govulncheck-ignore, fail on the rest.
#
# .govulncheck-ignore: one OSV id per line, reason after a `#`. Blank lines ignored.
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

go run golang.org/x/vuln/cmd/govulncheck@latest -format json ./... > "$work/vuln.json"

jq -rs '[.[] | select(.finding.trace[0].function != null) | .finding.osv] | unique | .[]' \
  "$work/vuln.json" > "$work/called.txt"

: > "$work/ignored.txt"
if [ -f .govulncheck-ignore ]; then
  sed -e 's/#.*//' -e 's/[[:space:]]//g' .govulncheck-ignore \
    | grep -v '^$' | sort -u > "$work/ignored.txt" || true
fi

while read -r id; do
  echo "::warning::$id is in .govulncheck-ignore but govulncheck no longer reports it; drop the entry"
done < <(comm -13 "$work/called.txt" "$work/ignored.txt")

unfixed="$(comm -23 "$work/called.txt" "$work/ignored.txt")"
if [ -z "$unfixed" ]; then
  echo "govulncheck: no called vulnerabilities outside .govulncheck-ignore"
  exit 0
fi

for id in $unfixed; do
  jq -rs --arg id "$id" '
    def sym: [
        (.package | split("/")
          | if (.[-1] | test("^v[0-9]+$")) and (length > 1) then .[-2] else .[-1] end),
        (.receiver | ltrimstr("*")),
        .function
      ] | map(select(. != null and . != "")) | join(".");
    first(.[] | select(.osv.id == $id) | .osv) as $o
    | "\($id): \($o.summary // "")",
      "  https://pkg.go.dev/vuln/\($id)",
      ([.[] | select(.finding.osv == $id and .finding.trace[0].function != null) | .finding
        | (.trace[1] // .trace[0]) as $c
        | "  \($c.position.filename):\($c.position.line):\($c.position.column): \($c | sym) calls \(.trace[0] | sym)"]
       | unique | .[])
  ' "$work/vuln.json"
done

echo "::error::govulncheck: called vulnerabilities not in .govulncheck-ignore: $(echo "$unfixed" | tr '\n' ' ')"
exit 1
