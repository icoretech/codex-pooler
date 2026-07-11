#!/usr/bin/env bash
set -euo pipefail

mode=""
receipt=""

validate() {
  local expected_mode="$1"
  local receipt_path="$2"
  local expected_account expected_model

  [[ -f "$receipt_path" ]] || return 1
  [[ "$expected_mode" == "equivalent" || "$expected_mode" == "changed-second" ]] || return 1

  if [[ "$expected_mode" == "equivalent" ]]; then
    expected_account='^transition\tequivalent\taccount\t22(\.0+)?\t22(\.0+)?\t14(\.0+)?\tpassed$'
    expected_model='^transition\tequivalent\tmodel\t22(\.0+)?\t22(\.0+)?\t1(\.0+)?\tpassed$'
  else
    expected_account='^transition\tchanged-second\taccount\t22(\.0+)?\t22(\.0+)?\t22(\.0+)?\tpassed$'
    expected_model='^transition\tchanged-second\tmodel\t22(\.0+)?\t22(\.0+)?\t22(\.0+)?\tpassed$'
  fi

  grep -Eq "$expected_account" "$receipt_path" || return 1
  grep -Eq "$expected_model" "$receipt_path" || return 1
  grep -Fqx $'cleanup\tproof-identity\tpassed' "$receipt_path" || return 1
  grep -Eq '^projection\tquota_scope,quota_family,quota_key,window_kind,source,source_precision,freshness_state,observed_at,reset_at,used_percent\tpassed$' "$receipt_path" || return 1
  [[ "$(grep -Ec '^row\t(account|model)\t' "$receipt_path")" == "2" ]] || return 1
  ! grep -Eqi '(postgres(ql)?://|bearer |authorization|token|password|chatgpt|account_id|raw_limit|raw_metered|metadata)' "$receipt_path"
}

if [[ "${1:-}" == "--self-test" ]]; then
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  valid="$temp_dir/valid.tsv"
  cat >"$valid" <<'EOF'
transition	equivalent	account	22	22	14	passed
transition	equivalent	model	22	22	1	passed
row	account	account	account	primary	codex_usage_api	observed	fresh	2026-01-01T00:00:00Z	2026-01-01T02:00:00Z	14
row	model	codex_model	model-quota	primary	codex_usage_api	observed	fresh	2026-01-01T00:00:00Z	2026-01-01T02:00:00Z	1
projection	quota_scope,quota_family,quota_key,window_kind,source,source_precision,freshness_state,observed_at,reset_at,used_percent	passed
cleanup	proof-identity	passed
EOF
  validate equivalent "$valid"
  printf 'authorization: bearer unsafe\n' >>"$valid"
  ! validate equivalent "$valid"
  ! validate changed-second /dev/null
  printf 'receipt self-test passed\n'
  exit 0
fi

while (($#)); do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --receipt) receipt="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

validate "$mode" "$receipt" || { printf 'invalid receipt\n' >&2; exit 1; }
