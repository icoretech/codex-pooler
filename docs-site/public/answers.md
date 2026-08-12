# Codex Pooler Answer Reference

Last reviewed: 2026-08-12
Canonical docs: https://docs.codex-pooler.com/

## What is Codex Pooler?

Codex Pooler is a self-hosted pooled gateway for trusted AI agents and tools. Clients authenticate with stable Pool API keys and see one virtual model, `gemma3`. The server owns target selection, fixed reasoning policy, account routing, retries, continuity, quota handling, and accounting.

## Which base URL should a client use?

| Client | Base URL | Credential | Model |
| --- | --- | --- | --- |
| Ollama | `https://codex-pooler.example.com` | Pool API key | `gemma3` |
| Claude Code / Anthropic Messages | `https://codex-pooler.example.com` | Pool API key | `gemma3` |
| OpenAI SDK | `https://codex-pooler.example.com/v1` | Pool API key | `gemma3` |
| Codex CLI | `https://codex-pooler.example.com/backend-api/codex` | Pool API key | `gemma3` |
| Operator MCP | `https://codex-pooler.example.com/mcp` | Operator MCP token | none |

For local setup, use `http://localhost:4000` with the same paths.

## Can a client select another model or effort?

No. The gateway normalizes client model and reasoning selectors before target validation. Public discovery, response model fields, streams, and errors expose only `gemma3`. If the server-owned target is unavailable, the gateway fails closed instead of advertising a fallback.

## Is this an Ollama server?

It provides bounded Ollama HTTP compatibility for discovery, chat, generation, JSON, and NDJSON. It is a virtual gateway, not a local Ollama daemon: it does not download weights, store blobs, mutate models, or provide embeddings.

## Does Claude Code work?

Yes, through the bounded Anthropic Messages adapter at `POST /v1/messages`. Claude Code keeps its local tools, edits, sandbox, transcript, interruption, and resume behavior. Configure every Anthropic model alias as `gemma3` and use a Pool API key.

## Does it provide full OpenAI or Anthropic API parity?

No. It supports the explicit routes in the Runtime Routes reference. OpenAI Realtime, OpenAI embeddings/batches/moderation/fine-tuning, Anthropic API families other than Messages/token counting, and wildcard Codex app-server routes are unsupported.

## Does it cache responses?

No. It can improve provider-side prompt-cache locality by converting supported cache and session inputs into one-way, Pool/API-key-scoped values. This is a routing hint, not stored-response replay or a guaranteed provider cache hit.

## Can clients see the provider, account, or assignment?

No. Protocol identity fields, headers, streams, and errors are projected through exact public allowlists. Authorized operators retain truthful metadata-only routing and accounting evidence, but clients do not receive private target/provider/account/assignment details.

## Does it rewrite generated content?

It rewrites only documented protocol identity fields and sanitizes errors/headers. It does not blindly search or alter user text, assistant prose, filenames, or tool arguments. The façade is not a general content filter.

## What stays out of logs?

Raw prompts, completions, tool payloads, request/response bodies, file/audio/image bytes, websocket frames, Pool keys, MCP tokens, cookies, upstream credentials, and raw façade cache/session values are not retained as request-log content.

## How do I start locally?

Clone the repository, run `scripts/self-host/generate-env.sh`, run `docker compose pull` and `docker compose up -d`, open `http://localhost:4000`, create a Pool, connect an authorized upstream account, create a Pool API key, and configure one supported client with `gemma3`.

## Canonical guides

- Ollama: https://docs.codex-pooler.com/clients/ollama/
- Claude Code: https://docs.codex-pooler.com/clients/claude-code/
- OpenAI SDKs: https://docs.codex-pooler.com/clients/openai-compatible/
- Codex CLI: https://docs.codex-pooler.com/clients/codex-cli/
- Exact routes: https://docs.codex-pooler.com/reference/runtime-routes/
