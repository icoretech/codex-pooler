#!/usr/bin/env bash
set -euo pipefail

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

base_url="${base_url%/}"
contract_dir="$(mktemp -d)"
trap 'rm -rf "$contract_dir"' EXIT INT TERM

post_json() {
  local label="$1"
  local path="$2"
  local protocol="$3"
  local payload="$4"
  local -a headers

  headers=(-H 'content-type: application/json')

  if [[ "$protocol" == 'anthropic' ]]; then
    headers+=(-H "x-api-key: $pool_key" -H 'anthropic-version: 2023-06-01')
  else
    headers+=(-H "authorization: Bearer $pool_key")
  fi

  curl --silent --show-error --fail-with-body --max-time 20 \
    -D "$contract_dir/$label.headers" \
    -o "$contract_dir/$label.body" \
    -X POST "${base_url}${path}" \
    "${headers[@]}" \
    --data-binary "$payload"
}

ollama_tools='[{"type":"function","function":{"name":"inspect_fixture","description":"Inspect a fixture","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}]'
responses_tools='[{"type":"function","name":"inspect_fixture","description":"Inspect a fixture","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]'
anthropic_tools='[{"name":"inspect_fixture","description":"Inspect a fixture","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]'

post_json 'ollama-chat-json' '/api/chat' 'ollama' \
  "{\"messages\":[{\"role\":\"user\",\"content\":\"You must call inspect_fixture exactly once with path fixture. Do not answer with text.\"}],\"tools\":$ollama_tools,\"stream\":false}"

post_json 'ollama-chat-stream' '/api/chat' 'ollama' \
  "{\"messages\":[{\"role\":\"user\",\"content\":\"You must call inspect_fixture exactly once with path fixture. Do not answer with text.\"}],\"tools\":$ollama_tools,\"stream\":true}"

post_json 'ollama-generate-json' '/api/generate' 'ollama' \
  '{"prompt":"contract","stream":false}'

post_json 'ollama-generate-stream' '/api/generate' 'ollama' \
  '{"prompt":"contract","stream":true}'

post_json 'openai-responses-json' '/v1/responses' 'openai' \
  "{\"input\":\"contract\",\"tools\":$responses_tools,\"stream\":false}"

post_json 'openai-responses-stream' '/v1/responses' 'openai' \
  "{\"input\":\"contract\",\"tools\":$responses_tools,\"stream\":true}"

post_json 'anthropic-messages-json' '/v1/messages' 'anthropic' \
  "{\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":\"Call inspect_fixture with path fixture.\"}],\"tools\":$anthropic_tools,\"tool_choice\":{\"type\":\"any\"},\"stream\":false}"

post_json 'anthropic-messages-stream' '/v1/messages' 'anthropic' \
  "{\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":\"Call inspect_fixture with path fixture.\"}],\"tools\":$anthropic_tools,\"tool_choice\":{\"type\":\"any\"},\"stream\":true}"

CONTRACT_DIR="$contract_dir" FACADE_POOL_API_KEY="$pool_key" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["CONTRACT_DIR"])
secret = os.environ["FACADE_POOL_API_KEY"]
forbidden = [
    "gpt-5.6-sol",
    "facade-provider-private-sentinel",
    "facade-account-private-sentinel",
    "facade-assignment-private-sentinel",
    "facade-provider-request-id-sentinel",
    "facade-upstream-credential-sentinel",
    "upstream.facade-private.invalid",
    secret,
]


def fail(label, message):
    raise SystemExit(f"{label}: {message}")


def load_json(label):
    try:
        value = json.loads((root / f"{label}.body").read_text())
    except (OSError, json.JSONDecodeError):
        fail(label, "response is not valid JSON")
    if not isinstance(value, dict):
        fail(label, "response must be a JSON object")
    return value


def ndjson(label):
    values = []
    for line in (root / f"{label}.body").read_text().splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            fail(label, "stream contains invalid NDJSON")
        if not isinstance(value, dict):
            fail(label, "NDJSON entries must be objects")
        values.append(value)
    if not values:
        fail(label, "stream is empty")
    return values


def sse(label):
    values = []
    for block in (root / f"{label}.body").read_text().replace("\r\n", "\n").split("\n\n"):
        data = [line[5:].lstrip() for line in block.splitlines() if line.startswith("data:")]
        if not data or data == ["[DONE]"]:
            continue
        try:
            value = json.loads("\n".join(data))
        except json.JSONDecodeError:
            fail(label, "stream contains invalid SSE JSON")
        if not isinstance(value, dict):
            fail(label, "SSE data must be an object")
        values.append(value)
    if not values:
        fail(label, "stream is empty")
    return values


def walk_models(value):
    if isinstance(value, dict):
        for key, nested in value.items():
            if key == "model" and isinstance(nested, str):
                yield nested
            yield from walk_models(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from walk_models(nested)


def validate_public(label, values):
    encoded = "\n".join(json.dumps(value, sort_keys=True) for value in values)
    for hidden in forbidden:
        if hidden and hidden in encoded:
            fail(label, "private facade identity escaped")
    models = list(walk_models(values))
    if not models:
        fail(label, "no public model identity was advertised")
    if any(model != "gemma3" for model in models):
        fail(label, "a model other than gemma3 was advertised")

    headers = (root / f"{label}.headers").read_text().lower()
    for hidden in forbidden:
        if hidden and hidden.lower() in headers:
            fail(label, "private facade identity escaped in headers")
    for prefix in ("x-openai-", "x-provider-", "x-account-", "x-assignment-", "x-upstream-"):
        if f"\n{prefix}" in headers:
            fail(label, "private upstream header escaped")


ollama_chat = load_json("ollama-chat-json")
validate_public("ollama-chat-json", [ollama_chat])
if ollama_chat.get("done") is not True or not ollama_chat.get("message", {}).get("tool_calls"):
    fail("ollama-chat-json", "missing terminal or tool call")

ollama_generate = load_json("ollama-generate-json")
validate_public("ollama-generate-json", [ollama_generate])
if ollama_generate.get("done") is not True:
    fail("ollama-generate-json", "missing terminal")

for label in ("ollama-chat-stream", "ollama-generate-stream"):
    values = ndjson(label)
    validate_public(label, values)
    if sum(value.get("done") is True for value in values) != 1:
        fail(label, "expected exactly one terminal object")

openai_json = load_json("openai-responses-json")
validate_public("openai-responses-json", [openai_json])
if openai_json.get("status") != "completed" or not openai_json.get("output"):
    fail("openai-responses-json", "missing completed output")

openai_stream = sse("openai-responses-stream")
validate_public("openai-responses-stream", openai_stream)
if sum(value.get("type") == "response.completed" for value in openai_stream) != 1:
    fail("openai-responses-stream", "expected one completed event")

anthropic_json = load_json("anthropic-messages-json")
validate_public("anthropic-messages-json", [anthropic_json])
if anthropic_json.get("type") != "message" or not any(
    block.get("type") == "tool_use" for block in anthropic_json.get("content", [])
):
    fail("anthropic-messages-json", "missing message tool-use output")

anthropic_stream = sse("anthropic-messages-stream")
validate_public("anthropic-messages-stream", anthropic_stream)
if sum(value.get("type") == "message_stop" for value in anthropic_stream) != 1:
    fail("anthropic-messages-stream", "expected one message_stop event")

print("facade contract passed: ollama openai anthropic json stream tools gemma3-only")
PY
