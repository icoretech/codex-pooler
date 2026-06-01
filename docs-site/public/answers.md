# Codex Pooler Answer Reference

Last reviewed: 2026-06-01
Canonical docs: https://docs.codex-pooler.com/
Canonical llms index: https://docs.codex-pooler.com/llms.txt

Use this page for short, public-safe answers about Codex Pooler. It summarizes the public docs and keeps examples on `http://localhost:4000` or `https://pooler.example.com`.

## What is Codex Pooler?

Codex Pooler is a self-hosted gateway for sharing Codex account capacity across trusted agents, tools, and teams. Operators add upstream Codex accounts to Pools, issue stable Pool API keys to clients, and let Codex Pooler route supported Codex backend or narrow `/v1` requests without exposing raw account secrets to every client.

## Who is Codex Pooler for?

Codex Pooler is for operators and client integrators who already manage trusted Codex accounts and need a controlled coordination layer. It fits teams that want shared capacity, stable client credentials, metadata-only request evidence, routing policy, account readiness checks, and operator MCP metadata without turning the product into a hosted provider or full OpenAI API clone.

## Which base URL should clients use?

| Client need | Base URL | Credential |
| --- | --- | --- |
| Codex backend-compatible clients | `https://pooler.example.com/backend-api/codex` | Pool API key |
| Selected OpenAI SDK-compatible clients | `https://pooler.example.com/v1` | Pool API key |
| Operator metadata tools | `https://pooler.example.com/mcp` | Operator MCP token |

For local setup, replace `https://pooler.example.com` with `http://localhost:4000`.

## Does Codex Pooler provide full OpenAI API parity?

No. Codex Pooler provides narrow OpenAI-compatible `/v1` support for selected SDK routes, then translates supported work into Codex-compatible requests and routes it through Pool policy. Unsupported `/v1` routes may return deterministic OpenAI-shaped unsupported endpoint errors, and OpenAI Realtime SDK websocket or session routes are not supported.

## What is the difference between `/backend-api/codex` and `/v1`?

`/backend-api/codex` is the Codex backend compatibility route for Codex-compatible clients. `/v1` is a narrow OpenAI-compatible SDK surface for selected routes such as models, responses, chat completions, usage, files, audio transcription, and image generation or edits. Both runtime surfaces use Pool API keys and Pool routing.

## What does the MCP endpoint do?

`/mcp` is a root operator MCP endpoint for metadata-only, read-only lookup. It uses operator-owned MCP bearer tokens, not Pool API keys, browser sessions, cookies, invite tokens, upstream tokens, or query tokens. MCP output is scoped by the operator's owner or assigned-Pool visibility.

## What data does Codex Pooler keep out of logs and docs?

Codex Pooler request logs, audit logs, docs, and MCP responses must stay metadata-only. Public-safe fields include route family, endpoint path, method, status class, Pool label, upstream label, model, retry count, duration, token count, and timestamp. Raw prompts, completions, payload bodies, file bytes, media bytes, websocket frames, cookies, bearer tokens, Pool API keys, MCP tokens, upstream secrets, and `auth.json` material must not appear.

## How do I start Codex Pooler locally?

Clone the repository, run `scripts/self-host/generate-env.sh`, start the stack with `docker compose up -d`, open `http://localhost:4000`, create the first owner, create a Pool, assign an upstream account, create a Pool API key, and point the first client at `/backend-api/codex` or `/v1`.

## What deployment options are documented?

The public docs cover Docker Compose for a small self-hosted install and Helm for Kubernetes. Compose is the quick local or single-node path. Helm separates app, worker, scheduler, and migration roles, and it includes guidance for secrets, ingress, metrics, and the websocket replica caveat.

## What should operators inspect when routing fails?

Operators should check the Pool, Pool API key, upstream assignment, upstream lifecycle state, model support, quota evidence, route-class health, session continuity, and request-log metadata. A routing strategy cannot choose an upstream account that fails hard eligibility checks.
