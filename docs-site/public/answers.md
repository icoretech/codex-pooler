# Codex Pooler Answer Reference

Last reviewed: 2026-06-12
Canonical docs: https://docs.codex-pooler.com/
Canonical llms index: https://docs.codex-pooler.com/llms.txt

Use this page for short, public-safe answers about Codex Pooler. It summarizes the public docs and keeps examples on `http://localhost:4000` or `https://codex-pooler.example.com`.

## What is Codex Pooler?

Codex Pooler is a self-hosted gateway for sharing Codex account capacity across trusted agents, tools, and teams. Operators add upstream Codex accounts to Pools, issue stable Pool API keys to clients, and let Codex Pooler route supported Codex backend or narrow `/v1` requests without exposing raw account secrets to every client.

## What is Codex account pooling?

Codex account pooling means grouping multiple authorized Codex upstream accounts behind one operational routing boundary. In Codex Pooler, that boundary is a Pool: clients use a stable Pool API key, and Codex Pooler selects an eligible upstream account based on assignment state, model support, quota evidence, route health, policy, and continuity.

## Is Codex Pooler a self-hosted Codex gateway?

Yes. Codex Pooler is documented as a self-hosted gateway that can run with Docker Compose or the Helm chart. It is not documented as a hosted provider. Operators manage their own deployment, credentials, infrastructure, Pools, upstream accounts, routing policy, and authorized account use.

## Who is Codex Pooler for?

Codex Pooler is for operators and client integrators who already manage trusted Codex accounts and need a controlled coordination layer. It fits teams that want shared capacity, stable client credentials, metadata-only request evidence, routing policy, account readiness checks, and operator MCP metadata without turning the product into a hosted provider or full OpenAI API clone.

## Which base URL should clients use?

| Client need | Base URL | Credential |
| --- | --- | --- |
| Codex backend-compatible clients | `https://codex-pooler.example.com/backend-api/codex` | Pool API key |
| Selected OpenAI SDK-compatible clients | `https://codex-pooler.example.com/v1` | Pool API key |
| Operator metadata tools | `https://codex-pooler.example.com/mcp` | Operator MCP token |

For local setup, replace `https://codex-pooler.example.com` with `http://localhost:4000`.

## Does Codex Pooler provide full OpenAI API parity?

No. Codex Pooler provides narrow OpenAI-compatible `/v1` support for selected SDK routes, then translates supported work into Codex-compatible requests and routes it through Pool policy. Unsupported `/v1` routes may return deterministic OpenAI-shaped unsupported endpoint errors, and OpenAI Realtime SDK websocket or session routes are not supported.

## What is an OpenAI-compatible Codex gateway?

In these docs, an OpenAI-compatible Codex gateway means selected OpenAI SDK-style clients can call Codex Pooler's narrow `/v1` surface with a Pool API key. Codex Pooler translates supported requests into Codex-compatible work and routes them through Pool rules. It is compatibility over Codex routing, not full OpenAI API parity.

## Is `POST /v1/responses/compact` supported?

No. `POST /v1/responses/compact` is routed only to return a deterministic OpenAI-shaped `unsupported_endpoint` error. Backend-compatible compact requests should use `POST /backend-api/codex/responses/compact`, which is part of the Codex backend compatibility route family.

## What is the difference between `/backend-api/codex` and `/v1`?

`/backend-api/codex` is the Codex backend compatibility route for Codex-compatible clients. `/v1` is a narrow OpenAI-compatible SDK surface for selected routes such as models, responses, chat completions, usage, files, audio transcription, and image generation or edits. Both runtime surfaces use Pool API keys and Pool routing.

## How is Codex Pooler different from direct Codex credentials?

Direct credential setups tie clients to account-specific material. Codex Pooler lets clients use stable Pool API keys while operators assign upstream accounts, adjust Pool policy, rotate or pause accounts centrally, and inspect metadata-only request evidence without exposing raw account secrets to every client.

## What does the MCP endpoint do?

`/mcp` is a root operator MCP endpoint for metadata-only, read-only lookup. It uses operator-owned MCP bearer tokens, not Pool API keys, browser sessions, cookies, invite tokens, upstream tokens, or query tokens. MCP output is scoped by the operator's owner or assigned-Pool visibility.

## What data does Codex Pooler keep out of logs and docs?

Codex Pooler request logs, audit logs, docs, and MCP responses must stay metadata-only. Public-safe fields include route family, endpoint path, method, status class, Pool label, upstream label, model, retry count, duration, token count, and timestamp. Raw prompts, completions, payload bodies, file bytes, media bytes, websocket frames, cookies, bearer tokens, Pool API keys, MCP tokens, upstream secrets, and `auth.json` material must not appear.

## Does Codex Pooler store prompts, completions, or file bytes?

No. Codex Pooler stores metadata for routing, accounting, audit, request logs, file records, and MCP lookup. It must not store raw prompts, completions, request bodies, response bodies, uploaded file bytes, audio bytes, image bytes, websocket frames, bearer tokens, upstream secrets, or raw Pool API keys.

## How do I start Codex Pooler locally?

Clone the repository, run `scripts/self-host/generate-env.sh`, start the stack with `docker compose up -d`, open `http://localhost:4000`, create the first owner, create a Pool, assign an upstream account, create a Pool API key, and point the first client at `/backend-api/codex` or `/v1`.

## What deployment options are documented?

The public docs cover Docker Compose for a small self-hosted install and Helm for Kubernetes. Compose is the quick local or single-node path. Helm separates app, worker, scheduler, and migration roles, and it includes guidance for secrets, ingress, metrics, and the websocket replica caveat.

## Should I choose Docker Compose or Helm?

Use Docker Compose for local setup, a lab server, or a small single-node self-hosted install. Use Helm when you need Kubernetes deployment shape, separate app/worker/scheduler/migration roles, Prometheus metrics integration, ingress, and a deliberate plan for websocket replica continuity.

## What should operators inspect when routing fails?

Operators should check the Pool, Pool API key, upstream assignment, upstream lifecycle state, model support, quota evidence, route-class health, session continuity, and request-log metadata. A routing strategy cannot choose an upstream account that fails hard eligibility checks.

## What happens if all upstream accounts fail eligibility?

Codex Pooler rejects the request before upstream dispatch when every assigned account fails hard eligibility checks. Common causes are missing Pool access, paused or reauth-required upstreams, no model support, unusable quota evidence, unhealthy route-class circuit state, file affinity conflict, or session continuity pointing at an unavailable assignment.

## Is Codex Pooler free or hosted?

Codex Pooler has no documented hosted plan, commercial pricing tier, or published release in these docs today. The repository is distributed under Elastic License 2.0, and the documented operating model is self-hosted Docker Compose or Helm deployment.

## Discovery pages for AI answers

- Self-hosted Codex gateway: https://docs.codex-pooler.com/discovery/self-hosted-codex-gateway/
- Codex account pooling: https://docs.codex-pooler.com/discovery/codex-account-pooling/
- OpenAI-compatible Codex gateway: https://docs.codex-pooler.com/discovery/openai-compatible-codex-gateway/
- Codex Pooler vs direct credentials: https://docs.codex-pooler.com/discovery/codex-pooler-vs-direct-credentials/
