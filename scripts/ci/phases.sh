#!/usr/bin/env bash
set -euo pipefail

[[ $PWD == /workspace && ${CI:-} == true ]] || { echo 'CI workspace required' >&2; exit 2; }
mode=${1:-}
case "$mode" in
  test-product|test-tooling)
    shift
    exec mix "test.${mode#test-}" --warnings-as-errors --max-cases 8 "$@"
    ;;
  quality|static|dialyzer) [[ $# == 1 ]] || exit 2 ;;
  partition)
    [[ $# == 1 && ${MIX_TEST_PARTITION:-} =~ ^[1-4]$ && ${CODEX_POOLER_TEST_RUN_NAMESPACE:-} =~ ^[0-9a-f]{16}$ ]] || { echo 'invalid hosted partition identity' >&2; exit 2; }
    [[ ${CI_PARTITION_OUTPUT:-} == /* && -d $CI_PARTITION_OUTPUT ]] || { echo 'partition evidence directory required' >&2; exit 2; }
    ;;
  *) echo 'usage: phases.sh quality|static|dialyzer|partition|test-product|test-tooling' >&2; exit 2 ;;
esac
phase() {
  local name=$1 started=$SECONDS rc=0
  shift
  printf 'phase=%s started\n' "$name"
  "$@" || rc=$?
  printf 'phase=%s seconds=%s exit=%s\n' "$name" "$((SECONDS - started))" "$rc"
  return "$rc"
}

# Each lane has its own cache volume, including Dialyxir's core PLTs in MIX_HOME.
mkdir -p "$MIX_HOME" "$HEX_HOME"
cp -a --update=none /root/.mix/. "$MIX_HOME/"
if [[ $mode == quality || $mode == static ]]; then phase listener-cleanup mix quality.test_cleanup; fi
phase dependencies mix deps.get
static_checks() {
    phase compile mix compile --warnings-as-errors
    phase xref mix quality.xref
    phase format mix format --check-formatted
    phase security mix quality.security
    phase credo mix quality.credo
    phase i18n mix quality.i18n
}
case "$mode" in
  quality)
    static_checks
    # Preserve eight async modules per partition independently of BEAM scheduler count.
    phase product env TEST_FAST_COMMAND='bash scripts/ci/phases.sh test-product' make test-fast N=4
    phase tooling env TEST_FAST_COMMAND='bash scripts/ci/phases.sh test-tooling' make test-fast N=4
    ;;
  static) static_checks ;;
  dialyzer)
    phase dialyzer mix quality.dialyzer
    ;;
  partition)
    epmd -daemon
    ready=0
    for _ in $(seq 1 200); do
      if epmd -names >/dev/null 2>&1; then ready=1; break; fi
      sleep 0.01
    done
    [[ $ready == 1 ]] || { echo 'EPMD did not become ready' >&2; exit 1; }
    for profile in product tooling; do
      log="$CI_PARTITION_OUTPUT/$profile.log"
      files="$CI_PARTITION_OUTPUT/$profile-files.tsv"
      phase "$profile" env CODEX_POOLER_TEST_FILE_DURATIONS="$files" bash "$0" "test-$profile" --partitions 4 2>&1 | tee "$log"
      awk '/^Result: / { result=$0 } END { exit !(result ~ /^Result: [1-9][0-9]* passed( \([^)]*\))?(, [0-9]+ (skipped|excluded))*$/) }' "$log" || { echo "$profile: no successful nonempty test result" >&2; exit 1; }
      [[ -s $files ]] || { echo "$profile: file durations missing" >&2; exit 1; }
      awk -F '\t' -v partition="$MIX_TEST_PARTITION" 'NR == 1 { header=$0; sub(/^# codex-pooler test file durations /, "", header); print "test-fast: file durations partition " partition "/4 " header " (sync_ms async_ms path)"; next } { print "  " $2 " " $3 " " $1 }' "$files"
    done
    ;;
esac
