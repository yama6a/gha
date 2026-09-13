#!/usr/bin/env bash
set -euo pipefail

greet() {
  local name="${1:-world}"
  echo "hello, ${name}"
}

greet "$@"
