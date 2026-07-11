#!/usr/bin/env bash
set -euo pipefail

mode="stable"
samples="5"
interval_ms="1000"
output=""
self_test=false
context=""
namespace="codex-pooler"
pod=""

while (($#)); do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --samples) samples="${2:-}"; shift 2 ;;
    --interval-ms) interval_ms="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --context) context="${2:-}"; shift 2 ;;
    --namespace) namespace="${2:-}"; shift 2 ;;
    --pod) pod="${2:-}"; shift 2 ;;
    --self-test) self_test=true; shift ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

validate_output() {
  local file="$1"
  jq -e '
    type == "object" and
    .schema_version == 1 and
    .status == "passed" and
    (.mode | IN("stable", "stale", "converged")) and
    (.selector_fingerprint | test("^[A-Za-z0-9_-]{20}$")) and
    .descriptor_count == 1 and .persisted_row_count == 1 and
    (.scope | IN("account", "model", "upstream_model", "feature")) and
    (.family | type == "string" and length > 0 and length <= 80) and
    (.sample_count | type == "number" and . >= 2 and . <= 60) and
    (.samples | type == "array") and
    (.sample_count == (.samples | length)) and
    ([.samples[] |
      (.index | type == "number") and
      (.observed_at | test("Z$")) and
      (.converged | type == "boolean") and
      all([.provider, .persisted][];
        (.used_percent | test("^[0-9]+(\\.[0-9]+)?$")) and
        (.reset_at | test("Z$")) and
        (.freshness | IN("fresh", "stale")) and
        (.source_class | IN("provider_usage", "runtime_event", "runtime_header", "other"))
      )
    ] | all) and
    ((keys_unsorted - ["schema_version","status","mode","selector_fingerprint","descriptor_count","persisted_row_count","scope","family","sample_count","samples"]) | length == 0)
  ' "$file" >/dev/null || return 1

  if rg -i 'account[_ -]?id|assignment[_ -]?id|descriptor[_ -]?id|identity[_ -]?id|raw_|selector_value|api[_ -]?key|authorization|bearer|token|cookie|payload|label|workspace|email|uuid' "$file" >/dev/null; then
    printf 'raw-field leakage detected\n' >&2
    return 1
  fi
}

self_test_suite() {
  local fixture_dir
  fixture_dir="$(mktemp -d)"
  trap 'rm -rf "$fixture_dir"' RETURN

  printf '%s\n' '{"schema_version":1,"status":"passed","mode":"stable","selector_fingerprint":"AbCdEfGhIjKlMnOpQrSt","descriptor_count":1,"persisted_row_count":1,"scope":"model","family":"example","sample_count":2,"samples":[{"index":1,"observed_at":"2026-01-01T00:00:00Z","converged":true,"provider":{"used_percent":"10","reset_at":"2026-01-01T01:00:00Z","freshness":"fresh","source_class":"provider_usage"},"persisted":{"used_percent":"10","reset_at":"2026-01-01T01:00:00Z","freshness":"fresh","source_class":"provider_usage"}},{"index":2,"observed_at":"2026-01-01T00:00:01Z","converged":true,"provider":{"used_percent":"10","reset_at":"2026-01-01T01:00:00Z","freshness":"fresh","source_class":"provider_usage"},"persisted":{"used_percent":"10","reset_at":"2026-01-01T01:00:00Z","freshness":"fresh","source_class":"provider_usage"}}]}' >"$fixture_dir/valid.json"
  validate_output "$fixture_dir/valid.json"

  jq '.descriptor_count = 2' "$fixture_dir/valid.json" >"$fixture_dir/duplicate.json"
  jq '.persisted_row_count = 0' "$fixture_dir/valid.json" >"$fixture_dir/missing.json"
  printf '%s\n' '{"status":"passed"}' >"$fixture_dir/malformed.json"
  jq '.account_id = "forbidden"' "$fixture_dir/valid.json" >"$fixture_dir/leak.json"
  jq '.samples[1].provider.used_percent = "11"' "$fixture_dir/valid.json" >"$fixture_dir/unstable.json"
  jq '.mode = "stale" | .samples[].converged = true' "$fixture_dir/valid.json" >"$fixture_dir/stale-mismatch.json"
  jq '.mode = "converged" | .samples[-1].converged = false' "$fixture_dir/valid.json" >"$fixture_dir/converged-mismatch.json"
  jq '.selector_fingerprint = ""' "$fixture_dir/valid.json" >"$fixture_dir/no-selector.json"

  for invalid in duplicate missing malformed leak no-selector; do
    if validate_output "$fixture_dir/$invalid.json" 2>/dev/null; then
      printf 'self-test accepted invalid fixture=%s\n' "$invalid" >&2
      return 1
    fi
    printf 'self-test rejected fixture=%s\n' "$invalid"
  done

  if jq -e '([.samples[] | [.provider, .persisted, .converged]] | unique | length) == 1' "$fixture_dir/unstable.json" >/dev/null; then
    printf 'self-test accepted unstable pairs\n' >&2
    return 1
  fi
  printf 'self-test rejected fixture=unstable-pairs\n'

  if jq -e '.mode != "stale" or ([.samples[].converged] | all | not)' "$fixture_dir/stale-mismatch.json" >/dev/null; then
    printf 'self-test accepted stale mismatch\n' >&2
    return 1
  fi
  printf 'self-test rejected fixture=stale-expectation-mismatch\n'

  if jq -e '.mode != "converged" or .samples[-1].converged' "$fixture_dir/converged-mismatch.json" >/dev/null; then
    printf 'self-test accepted converged mismatch\n' >&2
    return 1
  fi
  printf 'self-test rejected fixture=converged-expectation-mismatch\n'
  printf 'selector verifier self-test passed\n'
}

if [[ "$self_test" == true ]]; then
  self_test_suite
  exit 0
fi

[[ "$mode" == "stable" || "$mode" == "stale" || "$mode" == "converged" ]] || { printf 'invalid mode\n' >&2; exit 2; }
[[ "$samples" =~ ^[0-9]+$ && "$samples" -ge 2 && "$samples" -le 60 ]] || { printf 'invalid samples\n' >&2; exit 2; }
[[ "$interval_ms" =~ ^[0-9]+$ && "$interval_ms" -le 60000 ]] || { printf 'invalid interval\n' >&2; exit 2; }
[[ -n "$context" ]] || { printf 'context is required\n' >&2; exit 2; }
[[ -n "$output" ]] || output="${TMPDIR:-/tmp}/quota-selector-verification.json"
if [[ -z "$pod" ]]; then
  pod="$(kubectl --context "$context" -n "$namespace" get pods -l app.kubernetes.io/component=app -o json | jq -er '.items | map(select(.status.phase == "Running")) | sort_by(.metadata.name) | .[0].metadata.name')"
fi

temp_output="${output}.tmp"
eval_code="{:ok, _started} = Application.ensure_all_started(:ecto_sql); {:ok, _started} = Application.ensure_all_started(:req); {:ok, _repo} = CodexPooler.Repo.start_link(); {:ok, _finch} = Finch.start_link(name: CodexPooler.Finch); result = CodexPooler.Upstreams.Reconciliation.QuotaConvergenceVerifier.run(mode: \"${mode}\", samples: ${samples}, interval_ms: ${interval_ms}); case result do {:ok, report} -> IO.puts(Jason.encode!(report)); {:error, error} -> IO.puts(Jason.encode!(error)); System.halt(1) end"
kubectl --context "$context" -n "$namespace" exec "$pod" -- env ERL_AFLAGS= RELEASE_NODE="quota_selector_$$" \
  /app/bin/codex_pooler eval "$eval_code" >"$temp_output"
validate_output "$temp_output"
mv "$temp_output" "$output"
printf 'selector verifier passed mode=%s samples=%s output=%s\n' "$mode" "$samples" "$(basename "$output")"
