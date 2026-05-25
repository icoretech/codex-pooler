# Codex Pooler

![Codex Pooler gateway overview](.github/assets/codex-pooler-readme-banner.png)

Codex Pooler lets you create managed pools of Codex accounts.

Add your Codex accounts, group them into Pools, and give each client a Pool API
key. The client sends one request; Codex Pooler chooses which account should
handle it based on model support, available limits, session continuity, routing
strategy, and recent health.

That makes Codex limits easier to share. A client key can draw from the
accounts assigned to its Pool, while operators still get request accounting,
audit logs, account health, routing controls, and a browser UI for managing
pools.

Codex Pooler also exposes selected OpenAI `/v1` endpoints for agents and tools
that only know how to talk to an OpenAI-compatible API key. Those calls can keep
their familiar SDK shape while Codex Pooler routes them through pooled Codex
accounts, where subscription limits and raw API costs follow a different model.
Supported `/v1/responses`, `/v1/chat/completions`, files, audio, and image
requests use the same Pool rules and account selection logic.

## Highlights

- **Account pools:** group several Codex accounts and expose them through one
  or more Pool API keys
- **Shared quota usage:** send work to accounts with available limits, so
  clients do not need to know which account still has capacity
- **Routing strategies:** choose how eligible accounts are ordered, including
  bridge-ring routing, deterministic rotation, least-recent-success preference,
  and quota-first ordering
- **Session continuity:** keep Codex response sessions and websocket reconnects
  attached to the right Codex account when the client provides stable session
  state
- **Codex backend compatibility:** serve the Codex backend route family under
  `/backend-api/*`, including responses, compact, usage, files, transcription,
  backend image proxy routes at `/backend-api/codex/images/generations` and
  `/backend-api/codex/images/edits`, selected account-management routes,
  explicit `/backend-api/codex/v1/models`, `/backend-api/codex/v1/responses`,
  `/backend-api/codex/v1/responses/compact`, and
  `/backend-api/codex/v1/chat/completions` aliases, plus canonical and v1
  websocket response streams
- **OpenAI SDK compatibility:** serve selected `/v1/*` endpoints and translate
  supported requests into Codex-compatible calls
- **Operator UI:** manage pools, Codex accounts, API keys, request logs, audit
  logs, jobs, stats, operators, and settings from authenticated `/admin/*`
  pages
- **Metadata-only MCP service:** expose read-only administrative metadata to
  operator-owned MCP clients through `/mcp` without mutation tools
- **Metadata-only observability:** record request and routing metadata without
  storing prompts, file bodies, audio, images, bearer tokens, cookies, raw
  Codex account tokens, or raw API keys

## Quick Start With Docker Compose

This runs the published release image with a local Postgres database. It is the
fastest way to try Codex Pooler on a laptop or small server.

Prerequisites:

- Docker with Compose
- `openssl`

Start Codex Pooler:

```bash
git clone https://github.com/icoretech/codex-pooler.git
cd codex-pooler

scripts/self-host/generate-env.sh
docker compose pull
docker compose up -d
```

Open `http://localhost:4000`. On the first visit, create the owner account at
`/bootstrap`, then sign in and start with `/admin/pools`.

Useful commands:

```bash
docker compose ps
docker compose logs -f app
docker compose down
```

To remove the local database too:

```bash
docker compose down -v
```

## First Runtime Setup

After bootstrap:

1. Create a Pool in `/admin/pools`
2. Import or connect Codex accounts in `/admin/upstreams`
3. Create a Pool API key in `/admin/api-keys`
4. Point Codex or SDK clients at one of the runtime base URLs:

Treat an imported Codex `auth.json` as owned by Codex Pooler after import. Do
not keep using the same `auth.json` from another Codex install, machine, or
automation unless you accept that provider refresh-token rotation can invalidate
one copy and move the account to `reauth_required`.

```text
Codex backend base URL: http://localhost:4000/backend-api/codex
OpenAI SDK base URL:    http://localhost:4000/v1
```

Use the generated Pool API key as the bearer token. That key represents the
Pool, not a single Codex account, so Codex Pooler can pick the best eligible
account for each request. Raw API keys are shown only once when created or
rotated.

## Harness Configuration

Keep Pool API keys and MCP tokens in environment variables, not in harness
config files. For a local instance, the runtime URLs are:

```text
Codex backend base URL: http://localhost:4000/backend-api/codex
OpenAI SDK base URL:    http://localhost:4000/v1
MCP URL:                http://localhost:4000/mcp
```

For a deployed instance, replace `http://localhost:4000` with your HTTPS host,
for example `https://pooler.example.com`.

<details>
<summary><img src=".github/assets/opencode-favicon.png" alt="opencode logo" width="16" height="16"> opencode <code>~/.config/opencode/opencode.jsonc</code></summary>

opencode talks to Codex Pooler through the OpenAI-compatible `/v1` surface. The
provider uses the Pool API key, and the optional remote MCP entry uses an
operator-owned MCP token.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "openai": {
      "npm": "@ai-sdk/openai",
      "name": "Codex Pooler",
      "options": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "{env:CODEX_POOLER_API_KEY}",
        "reasoningEffort": "high",
        "reasoningSummary": "auto",
        "textVerbosity": "medium",
        "include": ["reasoning.encrypted_content"],
        "store": false
      },
      "models": {
        "gpt-5.5": {
          "id": "gpt-5.5",
          "name": "GPT-5.5",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 400000,
            "input": 256000,
            "output": 128000
          }
        }
      }
    }
  },
  "mcp": {
    "codex_pooler": {
      "type": "remote",
      "url": "http://localhost:4000/mcp",
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:CODEX_POOLER_MCP_KEY}"
      },
      "enabled": true,
      "timeout": 30000
    }
  }
}
```

Define only models that your assigned Pool can serve. For deployed instances,
change `baseURL` to `https://pooler.example.com/v1` and the MCP `url` to
`https://pooler.example.com/mcp`.

</details>

<details>
<summary><img src=".github/assets/codex-cli-favicon.png" alt="OpenAI logo" width="16" height="16"> Codex CLI <code>~/.codex/config.toml</code></summary>

Codex CLI should use the backend compatibility route, not the `/v1` SDK route.
Keep the provider `name` as `OpenAI`; Codex uses that value for provider-family
behavior even when the request is routed through Codex Pooler.

```toml
model = "gpt-5.5"
model_provider = "codex-pooler-ws"

[model_providers.codex-pooler-ws]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true

[model_providers.codex-pooler-http]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true

[mcp_servers.codex_pooler]
url = "http://localhost:4000/mcp"
bearer_token_env_var = "CODEX_POOLER_MCP_KEY"
```

Use the websocket provider for normal Codex backend behavior, and keep the HTTP
provider when you need to force SSE-only coverage. For deployed instances,
change both `base_url` values to `https://pooler.example.com/backend-api/codex`
and the MCP `url` to `https://pooler.example.com/mcp`.

</details>

<details>
<summary><img src=".github/assets/python-favicon.png" alt="Python logo" width="16" height="16"> OpenAI Python SDK</summary>

OpenAI Python SDK clients can use the OpenAI-compatible `/v1` surface by setting
`base_url` to the Codex Pooler `/v1` URL and using the Pool API key as the API
key.

```python
import os

from openai import OpenAI

client = OpenAI(
    api_key=os.environ["CODEX_POOLER_API_KEY"],
    base_url="http://localhost:4000/v1",
)

response = client.responses.create(
    model="gpt-5.5",
    input="Write a one-sentence status update.",
)

print(response.output_text)
```

For deployed instances, change `base_url` to `https://pooler.example.com/v1`.

</details>

<details>
<summary><img src=".github/assets/nodejs-favicon.png" alt="Node.js logo" width="16" height="16"> OpenAI Node SDK</summary>

OpenAI Node SDK clients use the same OpenAI-compatible `/v1` surface. Configure
`baseURL` with the Codex Pooler `/v1` URL and pass the Pool API key as the API
key.

```js
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const response = await client.responses.create({
  model: "gpt-5.5",
  input: "Write a one-sentence status update.",
});

console.log(response.output_text);
```

For deployed instances, change `baseURL` to `https://pooler.example.com/v1`.

</details>

<details>
<summary><img src=".github/assets/vercel-favicon.png" alt="Vercel logo" width="16" height="16"> Vercel AI SDK</summary>

Vercel AI SDK can point its OpenAI provider at Codex Pooler by creating a custom
provider with `createOpenAI`. The provider calls the OpenAI-compatible `/v1`
surface with the Pool API key.

```ts
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";

const pooler = createOpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const { text } = await generateText({
  model: pooler.responses("gpt-5.5"),
  prompt: "Write a one-sentence status update.",
});

console.log(text);
```

For deployed instances, change `baseURL` to `https://pooler.example.com/v1`.

</details>

## Runtime Compatibility

Codex Pooler supports two client-facing shapes:

- **Codex backend clients:** `/backend-api/codex/*`, `/backend-api/files`,
  `/backend-api/transcribe`, usage routes, and websocket response streams
- **OpenAI-style SDK clients:** `/v1/models`, `/v1/responses`,
  `/v1/chat/completions`, `/v1/files`, `/v1/audio/transcriptions`, and
  selected image endpoints

The `/v1` surface is compatibility, not a second engine. Supported requests are
translated into Codex-compatible calls, then routed through the same Pool rules,
limit checks, accounting, and account selection path.

## Operator MCP Service

Codex Pooler includes a metadata-only MCP endpoint at `/mcp` for trusted
operators who want an MCP host to inspect Pools, upstream accounts, Pool API key
metadata, operators, invites, request logs, audit logs, and MCP service status.
The service is read-only and has no mutation tools, but connected MCP hosts can
read administrative metadata, so only connect hosts you trust with that view.

MCP access uses operator-owned bearer MCP tokens, not Pool API keys, browser
sessions, cookies, query tokens, invite tokens, upstream tokens, or custom
headers. Operators manage their own MCP account gate and tokens from
`/admin/settings?tab=account`; the instance-wide service gate is managed from
`/admin/system`. Both gates must be enabled before a token works. Raw MCP tokens
are shown only once when created, and per-key usage tracking, counters, last IP,
and user-agent history are intentionally not stored.

The `/mcp` route inherits the runtime ingress IP allowlist and trusted-proxy
settings. If the allowlist is empty, the firewall is off; if it is configured,
the resolved client IP must match before MCP authentication or tool dispatch.

## Configuration

`scripts/self-host/generate-env.sh` writes a local `.env` with generated
secrets and local defaults. Keep that file private and don't reuse generated
values between public installs.

Environment variables are only for values the release needs before it can read
the database:

- `CODEX_POOLER_IMAGE` and `CODEX_POOLER_IMAGE_TAG`, the release image to run
- `CODEX_POOLER_HTTP_PORT`, the local host port, default `4000`
- `DATABASE_URL`, the Postgres connection used by the app
- `SECRET_KEY_BASE`, Phoenix signing and encryption secret
- `PHX_HOST`, `PORT`, and `PHX_SERVER`, Phoenix endpoint boot settings
- `OBAN_MODE` and `OBAN_JOBS_QUEUE_LIMIT`, release role and queue topology
- `DNS_CLUSTER_QUERY`, plus release distribution variables when clustering is on
- `CODEX_POOLER_TOTP_ENCRYPTION_KEY` and `CODEX_POOLER_TOTP_KEY_VERSION`, TOTP
  encryption root and version
- `CODEX_POOLER_UPSTREAM_SECRET_KEY` and
  `CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION`, upstream secret encryption root
  and version; the key must be 32 raw bytes or base64-encoded 32 bytes

Operational controls such as file limits, ingress trust, gateway diagnostics,
route-class admission, circuit thresholds, metrics auth, operator email, model
metadata, upstream timeouts, the OpenAI pricing catalog URL, and SMTP delivery
live in DB-managed Instance Settings under `/admin/system`. Live settings apply
to new runtime work through the settings cache. Cached settings reload after save
through PubSub invalidation; existing leases, in-flight requests, and already-open
streams keep the values they started with.

Secret Instance Settings stay write-only in the UI. The metrics bearer token is
stored only as a keyed HMAC digest, fingerprint, and key version. The SMTP
password is stored encrypted with key version metadata and is recovered only for
mail send or credential-test paths.

## Deployment Options

Docker Compose is the easiest way to try the software. For Kubernetes, this
repository also ships a Helm chart in `charts/codex-pooler` with separate app,
worker, scheduler, and migration roles. The chart expects an explicit immutable
image tag for real deployments. The chart defaults the web app to one replica
because backend websocket continuity owns a live upstream websocket in an app
pod. Owner-alive cross-node forwarding is wired, but scaling web replicas still
requires clustering, owner-forwarding, and the explicit unsafe topology
acknowledgement until Kubernetes smoke evidence relaxes that guard.

The Helm migration hook runs database migrations and imports the vendored OpenAI
pricing feed so request-log cost reporting has pricing snapshots after install
or upgrade. The scheduler also refreshes pricing hourly from the OpenAI pricing
catalog URL in Instance Settings, which defaults to
`https://icoretech.github.io/openai-json-pricing/pricing.json`.

## Local Development

Local development runs Phoenix on the host and Postgres through the dev compose
file:

```bash
make dev
```

`make dev` starts Postgres, prepares the database, imports the vendored OpenAI
pricing feed, and starts the Phoenix server on `http://localhost:4000`. Logs
are written to `tmp/dev-server.log`.

`mix ecto.setup` also loads a compact idempotent development operator baseline:
one owner on an empty database plus four example operators. All seeded operators
use `dev-password-123`.

To recreate a fuller fake dataset for exercising admin UI states without real
accounts or real request data, run:

```bash
mix dev.seed full
```

The full seed is idempotent and replaces only deterministic `dev-*` fake rows
owned by the development seed namespace. It includes active/disabled pools,
active/paused/revoked API keys, upstream accounts in active/refresh/reauth/paused
states, quota windows, request logs, invites, audit events, and job rows.

Common checks:

```bash
mix precommit
mix quality
docker compose -f docker-compose.dev.yml config
docker build .
helm template codex-pooler ./charts/codex-pooler
```
