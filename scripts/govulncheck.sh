#!/usr/bin/env bash
# Fails on a vulnerable symbol the code calls, unless its ID is listed in .govulncheck-ignore
# (one per line, trailing # comment allowed). An ignored ID that gains a fixed version fails
# again, so an ignore cannot outlive the fix.
set -euo pipefail

ignore='[]'
if [ -f .govulncheck-ignore ]; then
  ignore=$({ grep -vE '^\s*(#|$)' .govulncheck-ignore || true; } | awk '{print $1}' | jq -R . | jq -sc .)
fi

report=$(mktemp)
go run golang.org/x/vuln/cmd/govulncheck@latest -json ./... | jq -rs --argjson ignore "$ignore" '
  (map(select(.osv)) | map({key: .osv.id, value: .osv.summary}) | from_entries) as $summary
  | [ .[] | select(.finding and .finding.trace[0].function) | .finding ]
  | group_by(.osv)
  | map({
      id: .[0].osv,
      fixed: (map(.fixed_version) | map(select(. != null)) | first),
      callers: (map((.trace[1] // .trace[-1]) | "\(.package).\(.function) \(.position.filename // "?"):\(.position.line // "?")") | unique)
    })
  | .[]
  | (if (.id | IN($ignore[])) then (if .fixed then "stale" else "ignored" end) else "found" end) as $state
  | "\($state)\t\(.id)\t\($summary[.id])\tfixed: \(.fixed // "none")\t\(.callers | join(", "))"
' | tee "$report"

if grep -q '^found' "$report"; then
  echo "::error::vulnerable code is called; update the module, or list the ID in .govulncheck-ignore if no fix exists"
  exit 1
fi
if grep -q '^stale' "$report"; then
  echo "::error::an ignored vulnerability has a fix; update the module and drop the ID from .govulncheck-ignore"
  exit 1
fi
