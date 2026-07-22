#!/usr/bin/env bash
set -euo pipefail

validate_paths() {
  local paths_file="$1"
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
      lib/codex_pooler/quotas/evidence.ex|\
      lib/codex_pooler/quotas/evidence/codex_parsers.ex|\
      lib/codex_pooler/upstreams/quota/window_selector.ex|\
      lib/codex_pooler/upstreams/quota/windows.ex|\
      lib/codex_pooler/upstreams/quota/windows/cycle_confirmation.ex|\
      lib/codex_pooler/upstreams/quota/windows/evidence_store.ex|\
      lib/codex_pooler/upstreams/quota/windows/relative_liveness.ex|\
      lib/codex_pooler/upstreams/quota/windows/routing.ex|\
      lib/codex_pooler/upstreams/reconciliation/pool_reconciliation.ex|\
      lib/codex_pooler/upstreams/reconciliation/usage_probe.ex|\
      lib/codex_pooler/upstreams/saved_resets/auto_eligibility.ex|\
      test/codex_pooler/upstreams/saved_reset_redemption_test.exs|\
      test/codex_pooler/upstreams/quota/windows/provider_cycle_confirmation_test.exs|\
      test/codex_pooler/upstreams_test.exs|\
      test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs|\
      test/codex_pooler_web/live/admin/pages/upstreams_live_test.exs|\
      scripts/verification/quota-convergence/check-receipts.sh|\
      scripts/verification/quota-convergence/check-scope.sh|\
      scripts/verification/quota-convergence/observe-development-rollout.sh|\
      scripts/verification/quota-convergence/proof.exs|\
      scripts/verification/quota-convergence/provider_reset_inconsistency.exs|\
      scripts/verification/quota-convergence/run.sh|\
      scripts/verification/quota-convergence/verify-selectors.sh|\
      lib/codex_pooler/upstreams/reconciliation/quota_convergence_verifier.ex|\
      test/codex_pooler/upstreams/reconciliation/quota_convergence_verifier_test.exs|\
      RUNBOOK.md) ;;
      *) printf 'unsafe changed path: %s\n' "$path" >&2; return 1 ;;
    esac
  done <"$paths_file"
}

if [[ "${1:-}" == "--self-test" ]]; then
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  printf '%s\n' \
    'lib/codex_pooler/upstreams/quota/windows/cycle_confirmation.ex' \
    'scripts/verification/quota-convergence/provider_reset_inconsistency.exs' \
    'test/codex_pooler/upstreams/quota/windows/provider_cycle_confirmation_test.exs' \
    >"$temp_dir/safe"
  printf '%s\n' 'lib/codex_pooler/upstreams/quota/windows/evidence_store.ex' '.github/workflows/release.yml' >"$temp_dir/unsafe"
  validate_paths "$temp_dir/safe"
  if validate_paths "$temp_dir/unsafe"; then
    exit 1
  fi
  printf 'scope self-test passed\n'
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
base=""
head=""

while (($#)); do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

[[ "$base" =~ ^[0-9a-f]{40}$ ]] || { printf 'invalid base sha\n' >&2; exit 2; }
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { printf 'invalid head sha\n' >&2; exit 2; }
GIT_MASTER=1 git -C "$root" merge-base --is-ancestor "$base" "$head" || { printf 'base is not an ancestor of head\n' >&2; exit 1; }
temp_file="$(mktemp)"
trap 'rm -f "$temp_file"' EXIT
GIT_MASTER=1 git -C "$root" diff --name-only --relative "$base..$head" >"$temp_file"
validate_paths "$temp_file"
GIT_MASTER=1 git -C "$root" diff --check "$base..$head"
printf 'scope check passed\n'
