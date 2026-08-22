#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pattern='(?:task|todo)[ _-]?[0-9]+'

cd "$root_dir"

# Historical changelogs remain immutable release records. Dependency trees and
# generated build artifacts are not maintained source surfaces.
if rg -n -i --pcre2 \
  --glob '!CHANGELOG*' \
  --glob '!**/node_modules/**' \
  "$pattern" \
  dev_support lib test config scripts README.md README.zh-CN.md RUNBOOK.md docs-site; then
  echo "numeric workflow names remain in active sources" >&2
  exit 1
fi

echo "no numeric task/todo workflow names in active sources"
