#!/usr/bin/env bash
# Sourced by the shared workflows and actions. retry_run reruns a command only when its output
# matches one of the patterns below, so a real build or API error still fails on the first try.
# shellcheck disable=SC2034  # the patterns are read by the scripts that source this file

RETRY_RATE_LIMIT='toomanyrequests|429 Too Many Requests|Rate exceeded'
RETRY_REGISTRY_5XX='500 Internal Server Error|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout'
RETRY_GH_5XX='HTTP 5[0-9]{2}'
# The word boundaries keep version numbers such as 5.0.0 and CVE ids such as CVE-2024-50012 out.
RETRY_NETWORK='curl error|HTTP/2 5[0-9]{2}|\b50[0-4]\b|timed out'

# retry_matches PATTERN LOG succeeds when a line of LOG matches the extended regex PATTERN.
retry_matches() {
  grep -Eq -- "$1" "$2"
}

# retry_capture LOG COMMAND... runs COMMAND once and appends its stdout and stderr to LOG.
# Both streams also pass through unchanged, so a caller can still read stdout with $(...).
retry_capture() {
  local log=$1
  shift
  { { "$@" | tee -a "$log"; } 2>&1 1>&3 | tee -a "$log" >&2; } 3>&1
}

# retry_run PATTERN WAITS COMMAND... runs COMMAND, and after a failure whose output matches
# PATTERN sleeps for the next number of seconds in WAITS and runs it again. WAITS "5 15" allows
# three tries. Returns the exit code of the last try.
retry_run() {
  local pattern=$1 waits=$2 log wait code
  shift 2
  log=$(mktemp)
  for wait in $waits ''; do
    : > "$log"
    code=0
    retry_capture "$log" "$@" || code=$?
    if [ "$code" -eq 0 ] || [ -z "$wait" ] || ! retry_matches "$pattern" "$log"; then
      break
    fi
    echo "::warning::$1 failed with a transient error, trying again in ${wait}s" >&2
    sleep "$wait"
  done
  rm -f "$log"
  return "$code"
}
