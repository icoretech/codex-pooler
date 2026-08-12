#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_url="${FACADE_BASE_URL:-}"
pool_key="${FACADE_POOL_API_KEY:-}"

[[ "$base_url" =~ ^https?://[^[:space:]]+$ ]] || {
  printf 'FACADE_BASE_URL must be an http(s) URL\n' >&2
  exit 2
}

[[ -n "$pool_key" && "$pool_key" != *$'\n'* && "$pool_key" != *$'\r'* ]] || {
  printf 'FACADE_POOL_API_KEY is required\n' >&2
  exit 2
}

for command in bash curl git node npm python3 timeout codex claude; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'required client is unavailable: %s\n' "$command" >&2
    exit 2
  }
done

base_url="${base_url%/}"
if [[ -n "${FACADE_LIVE_ARTIFACT_DIR:-}" ]]; then
  live_dir="$FACADE_LIVE_ARTIFACT_DIR"
  mkdir -p "$live_dir"
else
  live_dir="$(mktemp -d)"
  trap 'rm -rf "$live_dir"' EXIT INT TERM
fi

if [[ ! -d "$script_dir/node_modules" ]]; then
  npm ci --prefix "$script_dir" --ignore-scripts --no-audit --no-fund >/dev/null
fi

printf 'facade live versions: node=%s codex=%s claude=%s\n' \
  "$(node --version)" \
  "$(codex --version | tr -d '\r\n')" \
  "$(claude --version | tr -d '\r\n')"

FACADE_BASE_URL="$base_url" FACADE_POOL_API_KEY="$pool_key" \
  bash "$script_dir/run-contract.sh"

FACADE_BASE_URL="$base_url" FACADE_POOL_API_KEY="$pool_key" \
  node "$script_dir/clients.mjs"

create_fixture() {
  local fixture_dir="$1"
  mkdir -p "$fixture_dir"

  python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
(root / "package.json").write_text('''{
  "name": "facade-cli-fixture",
  "private": true,
  "type": "module",
  "scripts": {"test": "node --test"}
}
''')
(root / "calculator.js").write_text('''export function add(left, right) {
  return left + right - 1;
}
''')
(root / "calculator.test.js").write_text('''import assert from "node:assert/strict";
import test from "node:test";
import { add } from "./calculator.js";

test("adds two numbers", () => {
  assert.equal(add(2, 2), 4);
});
''')
(root / "LONG_CONTEXT.md").write_text(
    "Facade long-session cache fixture. Preserve this exact project scope.\n" * 1200
)
PY

  git -C "$fixture_dir" init -q
  git -C "$fixture_dir" add .
  git -C "$fixture_dir" \
    -c user.name='Facade Verification' \
    -c user.email='facade-verification@localhost' \
    commit -qm 'fixture baseline'
}

assert_fixture_fixed() {
  local fixture_dir="$1"
  local marker="$2"

  if ! npm test --prefix "$fixture_dir" >/dev/null; then
    printf 'CLI smoke left the fixture test failing\n' >&2
    exit 1
  fi

  [[ -f "$fixture_dir/$marker" ]] || {
    printf 'CLI smoke did not create marker: %s\n' "$marker" >&2
    exit 1
  }
}

assert_no_private_output() {
  local output_file="$1"

  if grep -Eq 'gpt-5\.6-sol|facade-provider-private-sentinel|facade-account-private-sentinel|facade-assignment-private-sentinel|facade-upstream-credential-sentinel' "$output_file"; then
    printf 'private facade identity escaped into CLI output\n' >&2
    exit 1
  fi
}

cache_read_tokens() {
  local output_file="$1"

  python3 - "$output_file" <<'PY'
import json
import sys
from pathlib import Path

try:
    result = json.loads(Path(sys.argv[1]).read_text())
except (OSError, json.JSONDecodeError):
    raise SystemExit("Claude Code output is not valid JSON")

print(int(result.get("usage", {}).get("cache_read_input_tokens", 0) or 0))
PY
}

codex_fixture="$live_dir/codex-fixture"
codex_home="$live_dir/codex-home"
codex_user_home="$live_dir/codex-user-home"
mkdir -p "$codex_home" "$codex_user_home"
create_fixture "$codex_fixture"

codex_output="$live_dir/codex-output.log"

if ! HOME="$codex_user_home" \
  CODEX_HOME="$codex_home" \
  FACADE_POOL_API_KEY="$pool_key" \
  timeout --signal=INT --kill-after=10 300 \
    codex exec \
      --ignore-user-config \
      --ignore-rules \
      --skip-git-repo-check \
      --ephemeral \
      -C "$codex_fixture" \
      -s danger-full-access \
      -m gemma3 \
      -c 'model_provider="facade"' \
      -c 'model_providers.facade.name="OpenAI"' \
      -c "model_providers.facade.base_url=\"${base_url}/backend-api/codex\"" \
      -c 'model_providers.facade.env_key="FACADE_POOL_API_KEY"' \
      -c 'model_providers.facade.wire_api="responses"' \
      -c 'model_providers.facade.supports_websockets=true' \
      -c 'model_providers.facade.requires_openai_auth=false' \
      -o "$live_dir/codex-last-message.txt" \
      'Inspect the fixture, read LONG_CONTEXT.md, run npm test, fix only calculator.js, rerun the test, and create codex-marker.txt containing exactly codex-ok.' \
      >"$codex_output" 2>&1; then
  printf 'Codex CLI smoke exited nonzero\n' >&2
  exit 1
fi

assert_fixture_fixed "$codex_fixture" 'codex-marker.txt'
grep -qx 'codex-ok' "$codex_fixture/codex-marker.txt" || {
  printf 'Codex marker content is incorrect\n' >&2
  exit 1
}
assert_no_private_output "$codex_output"

claude_fixture="$live_dir/claude-fixture"
claude_home="$live_dir/claude-user-home"
mkdir -p "$claude_home"
create_fixture "$claude_fixture"
claude_session="$(python3 -c 'import uuid; print(uuid.uuid4())')"

claude_env=(
  env
  "HOME=$claude_home"
  "ANTHROPIC_BASE_URL=$base_url"
  "ANTHROPIC_AUTH_TOKEN=$pool_key"
  "ANTHROPIC_API_KEY=$pool_key"
  "ANTHROPIC_MODEL=gemma3"
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=gemma3"
  "ANTHROPIC_DEFAULT_SONNET_MODEL=gemma3"
  "ANTHROPIC_DEFAULT_OPUS_MODEL=gemma3"
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1'
)

claude_common=(
  claude
  -p
  --bare
  --model gemma3
  --effort max
  --dangerously-skip-permissions
  --tools 'Read,Edit,Bash'
  --output-format json
)

claude_first_output="$live_dir/claude-first.log"
if ! (
  cd "$claude_fixture"
  timeout --signal=INT --kill-after=10 300 \
    "${claude_env[@]}" "${claude_common[@]}" \
    --session-id "$claude_session" \
    'Inspect the fixture, read LONG_CONTEXT.md, run npm test, fix only calculator.js, rerun the test, and create claude-marker.txt containing exactly claude-ok.' \
    >"$claude_first_output" 2>&1
); then
  printf 'Claude Code initial smoke exited nonzero\n' >&2
  exit 1
fi

assert_fixture_fixed "$claude_fixture" 'claude-marker.txt'
grep -qx 'claude-ok' "$claude_fixture/claude-marker.txt" || {
  printf 'Claude marker content is incorrect\n' >&2
  exit 1
}
assert_no_private_output "$claude_first_output"

# Interrupt an in-session shell action, then prove the same conversation can
# continue without replaying a completed file edit or changing identity.
claude_interrupt_output="$live_dir/claude-interrupt.log"
set +e
(
  cd "$claude_fixture"
  timeout --signal=INT --kill-after=5 1 \
    "${claude_env[@]}" "${claude_common[@]}" \
    --resume "$claude_session" \
    'Use Bash to sleep for 10 seconds, then report the calculator test status.' \
    >"$claude_interrupt_output" 2>&1
)
interrupt_status=$?
set -e

if [[ "$interrupt_status" -ne 0 && "$interrupt_status" -ne 124 && "$interrupt_status" -ne 130 && "$interrupt_status" -ne 137 ]]; then
  printf 'Claude interruption returned an unexpected status\n' >&2
  exit 1
fi
assert_no_private_output "$claude_interrupt_output"

cache_read_total="$(cache_read_tokens "$claude_first_output")"

# A fresh upstream prompt-cache entry may not become readable immediately.
# Keep the session's prefix stable and retry a bounded number of real turns;
# completion still requires a reported cache hit.
for ((turn = 1; turn <= 6; turn++)); do
  claude_resume_output="$live_dir/claude-resume-${turn}.log"
  if ! (
    cd "$claude_fixture"
    timeout --signal=INT --kill-after=10 300 \
      "${claude_env[@]}" "${claude_common[@]}" \
      --resume "$claude_session" \
      "Re-read the long-context fixture, run npm test, and on turn ${turn} create continuation-${turn}.txt containing exactly continuation-${turn}-ok." \
      >"$claude_resume_output" 2>&1
  ); then
    printf 'Claude Code continuation %s exited nonzero\n' "$turn" >&2
    exit 1
  fi

  grep -qx "continuation-${turn}-ok" "$claude_fixture/continuation-${turn}.txt" || {
    printf 'Claude continuation marker is missing or incorrect\n' >&2
    exit 1
  }
  assert_no_private_output "$claude_resume_output"

  turn_cache_read="$(cache_read_tokens "$claude_resume_output")"
  cache_read_total=$((cache_read_total + turn_cache_read))

  if ((cache_read_total > 0)); then
    break
  fi
done

if ((cache_read_total <= 0)); then
  printf 'Claude Code continuation did not observe a prompt-cache read\n' >&2
  exit 1
fi

printf 'facade live clients passed: SDKs Codex CLI Claude Code tools interruption continuation cache\n'
