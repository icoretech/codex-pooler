#!/usr/bin/env bash
set -euo pipefail

validate_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
validate_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }

if [[ "${1:-}" == "--self-test" ]]; then
  validate_sha 0123456789abcdef0123456789abcdef01234567
  ! validate_sha main
  validate_digest sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  ! validate_digest sha256:short
  printf 'read-only rollout observer self-test passed\n'
  exit 0
fi

context=""
namespace=""
source_sha=""
digest=""
label="app.kubernetes.io/name=codex-pooler"

while (($#)); do
  case "$1" in
    --context) context="${2:-}"; shift 2 ;;
    --namespace) namespace="${2:-}"; shift 2 ;;
    --source-sha) source_sha="${2:-}"; shift 2 ;;
    --platform-digest) digest="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

[[ "$context" =~ ^[a-zA-Z0-9._-]+$ ]] || { printf 'invalid context\n' >&2; exit 2; }
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'invalid namespace\n' >&2; exit 2; }
[[ "$label" =~ ^[a-zA-Z0-9./_-]+=[a-zA-Z0-9._-]+$ ]] || { printf 'invalid label\n' >&2; exit 2; }
validate_sha "$source_sha" || { printf 'invalid source sha\n' >&2; exit 2; }
validate_digest "$digest" || { printf 'invalid platform digest\n' >&2; exit 2; }

images="$(kubectl --context "$context" -n "$namespace" get pods -l "$label" \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}')"
[[ -n "$images" ]] || { printf 'no matching rollout images\n' >&2; exit 1; }
grep -Fq "@$digest" <<<"$images" || { printf 'expected digest not observed\n' >&2; exit 1; }
printf 'rollout observation passed source_sha=%s platform_digest=%s\n' "$source_sha" "$digest"
