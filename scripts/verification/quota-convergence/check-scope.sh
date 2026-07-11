#!/usr/bin/env bash
set -euo pipefail

validate_paths() {
  local paths_file="$1"
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
      lib/codex_pooler/*|lib/codex_pooler_web/*|test/codex_pooler/*|test/codex_pooler_web/*|scripts/verification/quota-convergence/*|RUNBOOK.md) ;;
      *) printf 'unsafe changed path: %s\n' "$path" >&2; return 1 ;;
    esac
  done <"$paths_file"
}

if [[ "${1:-}" == "--self-test" ]]; then
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  printf '%s\n' 'lib/codex_pooler/example.ex' 'scripts/verification/quota-convergence/run.sh' >"$temp_dir/safe"
  printf '%s\n' 'lib/codex_pooler/example.ex' '.github/workflows/release.yml' >"$temp_dir/unsafe"
  validate_paths "$temp_dir/safe"
  ! validate_paths "$temp_dir/unsafe"
  printf 'scope self-test passed\n'
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
temp_file="$(mktemp)"
trap 'rm -f "$temp_file"' EXIT
GIT_MASTER=1 git -C "$root" diff --name-only --relative >"$temp_file"
validate_paths "$temp_file"
GIT_MASTER=1 git -C "$root" diff --check
printf 'scope check passed\n'
