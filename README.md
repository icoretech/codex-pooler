<h1 align="center">Codex Pooler</h1>

<p align="center">
  <strong>One gateway for many Codex accounts.</strong><br>
  Pool capacity, preserve sessions, route requests, and expose stable API keys
  for agents and tools.
</p>

<p align="center">
  <a href="#quick-start-with-docker-compose">Quick start</a>
  ·
  <a href="#harness-configuration">Harness</a>
  ·
  <a href="#configuration">Configuration</a>
  ·
  <a href="#deployment">Deployment</a>
</p>

<p align="center">
  <img src=".github/assets/codex-pooler-readme-banner.png" alt="Codex Pooler gateway overview">
</p>

<table>
  <tr>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen1.png">
        <img src=".github/assets/screen1.png" alt="Codex Pooler upstream account readiness" width="100%">
      </a><br>
      <sub>Upstreams</sub>
    </td>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen2.png">
        <img src=".github/assets/screen2.png" alt="Codex Pooler Pool dashboard" width="100%">
      </a><br>
      <sub>Pools</sub>
    </td>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen3.png">
        <img src=".github/assets/screen3.png" alt="Codex Pooler request logs" width="100%">
      </a><br>
      <sub>Request logs</sub>
    </td>
  </tr>
</table>

Codex Pooler is a self-hosted gateway for sharing Codex account capacity across
agents, tools, and teams.

Instead of binding each client to one Codex account, you add accounts to Pools
and issue stable Pool API keys. Clients send familiar Codex backend or
OpenAI-compatible requests; Codex Pooler selects the right account based on
model support, limits, session continuity, routing policy, and health.

Operators get one place to manage accounts, keys, routing, request accounting,
audit logs, and health without storing prompts, files, audio, images, bearer
tokens, or raw Codex secrets. Instance owners keep the global administration
surface, while instance admins work only with their assigned Pools.

## Highlights

- **One key for many accounts:** group Codex accounts into Pools and give
  clients stable Pool API keys instead of binding each tool to one account
- **Smarter capacity sharing:** route each request to an eligible account with
  available limits, matching model support, health, session state, and Pool
  policy
- **Codex backend compatibility:** point Codex-compatible clients at Codex
  Pooler and keep responses, compacting, usage, files, audio, images, and
  backend websocket flows working through pooled accounts
- **OpenAI-compatible SDK surface:** let `/v1`-only apps and agent tools use
  multiple Codex subscriptions behind one gateway, with supported requests
  translated and routed through Codex capacity to help contain API spend
- **Session-aware websockets:** keep resumable Codex sessions and websocket
  reconnects attached to the right upstream account without translating backend
  websocket traffic through an HTTP compatibility layer
- **Prompt-cache locality:** use a transient `prompt_cache_key` to prefer the
  same eligible upstream account for repeat stateless requests, improving
  provider-side cache locality without storing prompts or responses locally
- **Per-Pool request compression:** optionally compress upstream-bound
  Responses tool outputs before dispatch on supported request routes. The
  option is disabled by default, request-side only, and records safe aggregate
  savings without storing raw outputs.
- **Operator dashboard:** manage Pool-scoped accounts, API keys, invites,
  usage, request logs, audit logs, MCP access, and the owner-only jobs,
  operators, and system settings surfaces
- **Privacy-minded observability:** store request, routing, and audit metadata
  without storing prompts, file bodies, audio, images, bearer tokens, cookies,
  raw Codex account tokens, or raw API keys
- **Configurable without code changes:** tune Pool policy, gateway defaults,
  diagnostics, model support, limits, and operational settings from the admin UI
- **Built for self-hosting:** run on Elixir/Erlang's fault-tolerant runtime,
  start locally with Docker Compose, or deploy the Helm chart with separate web,
  worker, scheduler, and migration roles for Kubernetes-friendly, multinode
  growth

## Harness Configuration

Keep Pool API keys in environment variables when the harness supports secret
expansion. The `/mcp` endpoint is an optional operator-only add-on for metadata
inspection; Codex Pooler runtime clients do not need it. If a desktop harness
persists remote MCP headers in its own private settings, use a dedicated
operator-scoped MCP token. For a local instance, the URLs are:

```text
Codex backend base URL:      http://localhost:4000/backend-api/codex
OpenAI SDK base URL:         http://localhost:4000/v1
Optional operator MCP URL:   http://localhost:4000/mcp
```

For a deployed instance, replace `http://localhost:4000` with your deployed host,
for example `https://codex-pooler.example.com`.

<details>
<summary><img src=".github/assets/opencode-favicon.png" alt="opencode logo" width="16" height="16"> OpenCode <code>~/.config/opencode/opencode.jsonc</code></summary>

![Codex Pooler OpenCode integration](.github/assets/codex-pooler-opencode.png)

OpenCode talks to Codex Pooler through the OpenAI-compatible `/v1` surface. Keep
the provider id as `openai` for this setup so OpenCode continues to use its
OpenAI provider-family behavior. The provider uses the Pool API key, and the
optional remote MCP entry uses an operator-owned MCP token. MCP is not required
for OpenCode to use Codex Pooler; it only gives an operator MCP host read-only
metadata tools. Its websocket
support is the narrow Responses websocket route at `GET /v1/responses`, not
OpenAI Realtime SDK compatibility.

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
  // Optional operator-only MCP metadata add-on. Omit for normal model/runtime use.
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
change `baseURL` to `https://codex-pooler.example.com/v1`; if you keep the optional
operator MCP entry, change its `url` to `https://codex-pooler.example.com/mcp`.

</details>

<details>
<summary><img src=".github/assets/codex-cli-favicon.png" alt="Codex logo" width="16" height="16"> Codex CLI and Codex Desktop <code>CODEX_HOME/config.toml</code></summary>

![Codex Pooler integration for Codex CLI and Codex Desktop](.github/assets/codex-pooler-codex.png)

Codex CLI and Codex Desktop should use the backend compatibility route, not the
`/v1` SDK route. They share the same Codex configuration layers and user-level
`CODEX_HOME/config.toml`, so one Codex Pooler provider block can serve the
terminal and desktop/IDE experience. Keep the provider id as `codex-pooler-ws`,
but keep the provider `name` exactly `OpenAI`. In current Codex sources, `name`
is not just
a display label: exact `OpenAI` matching enables OpenAI-family behavior such as
remote compaction, web search/image availability, and Codex backend request
compression.

Put provider and auth settings in the user-level config file. Codex resolves
`CODEX_HOME` first. If `CODEX_HOME` is unset, current Codex sources default it
to `$HOME/.codex` on every OS, so the user config file is
`CODEX_HOME/config.toml`.

| OS | Default config file |
| --- | --- |
| macOS | `$HOME/.codex/config.toml` |
| Linux | `$HOME/.codex/config.toml` |
| Windows | `$HOME\.codex\config.toml`, normally `%USERPROFILE%\.codex\config.toml` |

Codex's project-local `.codex/config.toml` layers are trust-gated and do not
override machine-local provider keys such as `model_provider` or
`model_providers`.

Use the websocket provider for normal Codex CLI and Codex Desktop backend
behavior:

```toml
model_provider = "codex-pooler-ws"

[model_providers.codex-pooler-ws]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true
```

Keep an HTTP/SSE provider when you need to force non-websocket behavior for a
client check or when a Codex runtime cannot open backend websocket streams:

```toml
model_provider = "codex-pooler-http"

[model_providers.codex-pooler-http]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

For deployed instances, change `base_url` to
`https://codex-pooler.example.com/backend-api/codex`.

Optional operator-only MCP metadata add-on. Omit for normal Codex runtime use:

```toml
[mcp_servers.codex_pooler]
url = "http://localhost:4000/mcp"
bearer_token_env_var = "CODEX_POOLER_MCP_KEY"
```

For deployed instances, change the optional MCP `url` to
`https://codex-pooler.example.com/mcp`.

Codex filters resumable conversations by `model_provider`. If you already have
Codex CLI or Codex Desktop sessions created with the built-in `openai` provider
and want them to appear under `codex-pooler-ws`, re-tag both the JSONL
transcripts and the newer SQLite state database. Close Codex first; these
commands edit local Codex state in place. If you made the HTTP provider your
default, replace only the destination value `codex-pooler-ws` with
`codex-pooler-http` before copying.

#### macOS (zsh)

Run these two zsh one-liners:

```zsh
if [ -d "$HOME/.codex/sessions" ]; then find "$HOME/.codex/sessions" -type f -name '*.jsonl' -exec perl -0pi -e 's/("model_provider"\s*:\s*)"openai"/$1"codex-pooler-ws"/g' {} +; fi
```

```zsh
for db in "$HOME"/.codex/state_*.sqlite(N); do sqlite3 "$db" "UPDATE threads SET model_provider = 'codex-pooler-ws' WHERE model_provider = 'openai';"; done
```

#### Linux (bash)

Run these two bash one-liners:

```bash
if [ -d "$HOME/.codex/sessions" ]; then find "$HOME/.codex/sessions" -type f -name '*.jsonl' -exec perl -0pi -e 's/("model_provider"\s*:\s*)"openai"/$1"codex-pooler-ws"/g' {} +; fi
```

```bash
for db in "$HOME"/.codex/state_*.sqlite; do [ -e "$db" ] || continue; sqlite3 "$db" "UPDATE threads SET model_provider = 'codex-pooler-ws' WHERE model_provider = 'openai';"; done
```

#### Windows (PowerShell)

Run the same migration from PowerShell. This expects `sqlite3` to be available
on `PATH`.

```powershell
$ErrorActionPreference = "Stop"

$FromProvider = "openai"
$ToProvider = "codex-pooler-ws"
$CodexHome = Join-Path $HOME ".codex"

$FromJson = '"model_provider":"' + $FromProvider + '"'
$ToJson = '"model_provider":"' + $ToProvider + '"'

Get-ChildItem -Path (Join-Path $CodexHome "sessions") -Recurse -Filter "*.jsonl" |
  ForEach-Object {
    $Path = $_.FullName
    $TempPath = "$Path.tmp"
    $Reader = [System.IO.StreamReader]::new($Path)
    $Writer = [System.IO.StreamWriter]::new(
      $TempPath,
      $false,
      [System.Text.UTF8Encoding]::new($false)
    )

    try {
      while (($Line = $Reader.ReadLine()) -ne $null) {
        $Writer.WriteLine($Line.Replace($FromJson, $ToJson))
      }
    } finally {
      $Reader.Dispose()
      $Writer.Dispose()
    }

    Move-Item -Force $TempPath $Path
  }

Get-ChildItem -Path $CodexHome -Filter "state_*.sqlite" |
  ForEach-Object {
    sqlite3 $_.FullName `
      "UPDATE threads SET model_provider = '$ToProvider' WHERE model_provider = '$FromProvider';"
  }
```

</details>

<details>
<summary><img src=".github/assets/openclaw-favicon.png" alt="OpenClaw logo" width="16" height="16"> OpenClaw <code>~/.openclaw/openclaw.json</code></summary>

![Codex Pooler OpenClaw integration](.github/assets/codex-pooler-openclaw.png)

OpenClaw uses `openai/*` as the canonical OpenAI route. To keep that model name
while sending agent turns to Codex Pooler's OpenAI-compatible `/v1` surface,
point the OpenAI provider at Codex Pooler and use the current OpenClaw runtime id.

```json5
{
  agents: {
    defaults: {
      model: { primary: "openai/gpt-5.5" },
    },
  },
  models: {
    mode: "merge",
    providers: {
      openai: {
        baseUrl: "http://localhost:4000/v1",
        apiKey: "${CODEX_POOLER_API_KEY}",
        api: "openai-responses",
        agentRuntime: { id: "openclaw" },
        timeoutSeconds: 300,
        models: [
          {
            id: "gpt-5.5",
            name: "GPT-5.5 via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 400000,
            contextTokens: 256000,
            maxTokens: 128000,
          },
        ],
      },
    },
  },
  // Optional operator-only MCP metadata add-on. Omit for normal model/runtime use.
  mcp: {
    servers: {
      codex_pooler: {
        url: "http://localhost:4000/mcp",
        transport: "streamable-http",
        headers: {
          Authorization: "Bearer ${CODEX_POOLER_MCP_KEY}",
        },
      },
    },
  },
}
```

Define only models that your assigned Pool can serve. For deployed instances,
change `baseUrl` to `https://codex-pooler.example.com/v1`; if you keep the optional
operator MCP add-on, change its `url` to `https://codex-pooler.example.com/mcp`.
If you prefer to keep Codex Pooler separate from OpenClaw's built-in OpenAI
provider behavior, use a custom provider id such as `codex-pooler/gpt-5.5`
instead. That follows OpenClaw's generic custom-provider shape, but tools that
look specifically for `openai/gpt-*` model refs will not see it as canonical
OpenAI.

</details>

<details>
<summary><img src=".github/assets/hermes-favicon.png" alt="Hermes Agent logo" width="16" height="16"> Hermes Agent <code>~/.hermes/config.yaml</code> + <code>auth.json</code></summary>

![Codex Pooler Hermes Agent integration](.github/assets/codex-pooler-hermes.png)

Hermes works best through its `openai-api` provider with the Responses transport
forced explicitly. This is the recommended Codex Pooler setup. Keep the Pool API
key in `~/.hermes/.env` and point the provider config at Codex Pooler's `/v1`
surface. Include Hermes' `image_gen` block when you want image generation or
edits through the same OpenAI-compatible path. The `mcp_servers` block is an
optional operator-only add-on for read-only metadata tools; Codex Pooler works
without it.

```bash
OPENAI_API_KEY=<pool-api-key>
OPENAI_BASE_URL=http://localhost:4000/v1
# Optional operator-only MCP metadata add-on:
CODEX_POOLER_MCP_KEY=<operator-mcp-token>
```

```yaml
model:
  default: gpt-5.5
  provider: openai-api
  base_url: http://localhost:4000/v1
  api_mode: codex_responses
  context_length: 400000
  supports_vision: true

agent:
  image_input_mode: native

image_gen:
  provider: openai
  model: gpt-image-2-medium

# Optional operator-only MCP metadata add-on. Omit for model/runtime use.
mcp_servers:
  codex_pooler:
    url: http://localhost:4000/mcp
    headers:
      Authorization: "Bearer ${CODEX_POOLER_MCP_KEY}"
    enabled: true
    timeout: 120
    connect_timeout: 15
```

Remote HTTP MCP servers require Hermes' `mcp` extra. If
`hermes mcp test codex_pooler` reports `mcp.client.streamable_http is not
available`, install MCP support into the Hermes environment, following the
[Hermes MCP Integration docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp),
and rerun the test.

Check the one-shot model path:

```bash
hermes -z 'Reply with exactly: hermes openai api ok' --ignore-rules
```

Hermes can also be made to use its `openai-codex` provider against Codex
Pooler, but this alternate path is less direct because Hermes treats `openai-codex` as an
OAuth provider by default; add a Pool API key credential ahead of any existing
device-code credential and keep the entry's `base_url` on `/v1`. Use this only
when you specifically need Hermes' `openai-codex` credential-pool behavior; the
`openai-api` configuration above is the preferred setup. This variant stores the
key in `auth.json` because Hermes credential pools live there.

```bash
HERMES_CODEX_BASE_URL=http://localhost:4000/v1
# Optional operator-only MCP metadata add-on:
CODEX_POOLER_MCP_KEY=<operator-mcp-token>
```

```yaml
model:
  default: gpt-5.5
  provider: openai-codex
  base_url: http://localhost:4000/v1
  context_length: 400000
  supports_vision: true

agent:
  image_input_mode: native

# Optional operator-only MCP metadata add-on. Omit for model/runtime use.
mcp_servers:
  codex_pooler:
    url: http://localhost:4000/mcp
    headers:
      Authorization: "Bearer ${CODEX_POOLER_MCP_KEY}"
    enabled: true
    timeout: 120
    connect_timeout: 15
```

```json
{
  "active_provider": "openai-codex",
  "credential_pool": {
    "openai-codex": [
      {
        "label": "codex-pooler",
        "auth_type": "api_key",
        "priority": -10,
        "source": "manual",
        "access_token": "<pool-api-key>",
        "base_url": "http://localhost:4000/v1"
      }
    ]
  }
}
```

For deployed instances, change the model URLs to
`https://codex-pooler.example.com/v1`; if you keep the optional operator MCP add-on,
change the MCP `url` to `https://codex-pooler.example.com/mcp`.

</details>

<details>
<summary><img src=".github/assets/pi-favicon.png" alt="Pi logo" width="16" height="16"> Pi <code>~/.pi/agent/models.json</code> and <code>settings.json</code></summary>

Pi works best through a custom provider that uses Codex Pooler's narrow
OpenAI-compatible `/v1` Responses surface. Put custom providers and models in
`~/.pi/agent/models.json`; put global defaults in `~/.pi/agent/settings.json`;
use `.pi/settings.json` for project overrides; and keep saved trust decisions in
`~/.pi/agent/trust.json`. On Windows, use the same home-relative paths under the
user profile, for example `%USERPROFILE%\.pi\agent\models.json`.

Install Pi from npm so you get the latest published CLI:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

Then add a provider to `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "codex-pooler": {
      "name": "Codex Pooler",
      "baseUrl": "http://localhost:4000/v1",
      "api": "openai-responses",
      "apiKey": "$CODEX_POOLER_API_KEY",
      "authHeader": true,
      "models": [
        {
          "id": "gpt-5.5",
          "name": "GPT-5.5 via Codex Pooler",
          "reasoning": true,
          "thinkingLevelMap": {
            "xhigh": "xhigh"
          },
          "input": ["text", "image"],
          "contextWindow": 400000,
          "maxTokens": 128000
        }
      ]
    }
  }
}
```

`authHeader: true` makes Pi send the Pool API key as
`Authorization: Bearer ...`. Define only model ids your assigned Pool can serve.
For deployed instances, change `baseUrl` to
`https://codex-pooler.example.com/v1`.

The explicit `thinkingLevelMap` entry is required for Pi to expose `xhigh` in
the model picker and footer. Without it, Pi treats `xhigh` as unsupported for a
custom model and clamps `--thinking xhigh` or `defaultThinkingLevel: "xhigh"` to
`high`.

Optionally set Codex Pooler as the default Pi model in
`~/.pi/agent/settings.json`:

```json
{
  "defaultProvider": "codex-pooler",
  "defaultModel": "gpt-5.5",
  "defaultThinkingLevel": "xhigh",
  "enabledModels": ["codex-pooler/gpt-5.5"]
}
```

Check the non-interactive path from a repository:

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
pi --provider codex-pooler \
  --model gpt-5.5 \
  --no-session \
  --no-context-files \
  --tools bash \
  -p 'Reply with exactly: pi ok'
```

Pi does not ship built-in MCP support. Codex Pooler model use does not require
MCP; if you need operator metadata, use a separate MCP-capable host with an
operator MCP token.

</details>

<details>
<summary><img src=".github/assets/omp-favicon.png" alt="OMP logo" width="16" height="16"> OMP <code>~/.omp/agent/models.yml</code> and <code>config.yml</code></summary>

Oh My Pi (OMP) is a Pi fork, but it should be treated as a separate Codex
Pooler harness: it has its own package, `omp` binary, YAML config, and model
role defaults. Install the current CLI through Bun:

```bash
bun install -g @oh-my-pi/pi-coding-agent
```

Then add a provider to `~/.omp/agent/models.yml`:

```yaml
providers:
  codex-pooler:
    baseUrl: http://localhost:4000/v1
    api: openai-responses
    apiKey: CODEX_POOLER_API_KEY
    authHeader: true
    models:
      - id: gpt-5.5
        name: GPT-5.5 via Codex Pooler
        reasoning: true
        thinking:
          mode: effort
          efforts:
            - xhigh
          defaultLevel: xhigh
          effortMap:
            xhigh: xhigh
        input:
          - text
          - image
        contextWindow: 400000
        maxTokens: 128000
```

`apiKey: CODEX_POOLER_API_KEY` makes OMP resolve that environment variable at
runtime. `authHeader: true` makes OMP send the Pool API key as
`Authorization: Bearer ...`. Define only model ids your assigned Pool can
serve. For deployed instances, change `baseUrl` to
`https://codex-pooler.example.com/v1`.

Optionally set Codex Pooler as the default OMP model roles in
`~/.omp/agent/config.yml`:

```yaml
startup:
  setupWizard: false
defaultThinkingLevel: xhigh
enabledModels:
  - codex-pooler/gpt-5.5
modelProviderOrder:
  - codex-pooler
modelRoles:
  default: codex-pooler/gpt-5.5:xhigh
  smol: codex-pooler/gpt-5.5:xhigh
  slow: codex-pooler/gpt-5.5:xhigh
  plan: codex-pooler/gpt-5.5:xhigh
  task: codex-pooler/gpt-5.5:xhigh
  vision: codex-pooler/gpt-5.5:xhigh
```

Check the non-interactive path from a repository:

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
omp --model codex-pooler/gpt-5.5:xhigh \
  --no-session \
  --tools bash \
  -p 'Reply with exactly: omp ok'
```

OMP ships MCP-capable tooling, but Codex Pooler model use does not require MCP.
If you use Codex Pooler's optional operator MCP endpoint, keep the `/mcp`
operator token separate from the Pool API key used for `/v1`.

</details>

<details>
<summary><img src=".github/assets/kilo-favicon.png" alt="Kilo logo" width="16" height="16"> Kilo <code>~/.config/kilo/kilo.jsonc</code></summary>

Kilo Code should use a named OpenAI-compatible provider whose base URL ends at
Codex Pooler's `/v1` surface. Kilo appends `/chat/completions` itself, so do
not put `/v1/chat/completions` in `baseURL`. Install the current CLI from npm:

```bash
npm install -g @kilocode/cli@latest
```

Then configure the provider in `~/.config/kilo/kilo.jsonc`:

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",
  "model": "codex-pooler/gpt-5.5",
  "enabled_providers": ["codex-pooler"],
  "provider": {
    "codex-pooler": {
      "options": {
        "apiKey": "{env:CODEX_POOLER_API_KEY}",
        "baseURL": "http://localhost:4000/v1"
      },
      "models": {
        "gpt-5.5": {
          "name": "GPT-5.5 via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
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
  }
}
```

Define only model ids your assigned Pool can serve. For deployed instances,
change `baseURL` to `https://codex-pooler.example.com/v1`. If you add Kilo
permissions, use Kilo's object form such as `"permission": {"bash": "allow"}`;
do not set `"permission": "ask"`, which is not a valid config shape.

Check the headless tool path from an isolated directory:

```bash
mkdir -p /tmp/codex-pooler-kilo-check
cd /tmp/codex-pooler-kilo-check

export CODEX_POOLER_API_KEY=<pool-api-key>
kilo run \
  --model codex-pooler/gpt-5.5 \
  --pure \
  --auto \
  --format json \
  --dir "$PWD" \
  'Use your tools to create kilo-ok.txt containing exactly: kilo ok. After the file exists, reply with exactly: kilo ok'
```

`--pure` keeps external plugins out of the check. `--auto` is only for trusted,
isolated automation where Kilo may run approved tools without prompting. Codex
Pooler model use does not require MCP. If you need operator metadata, use a
separate MCP-capable host with an operator MCP token.

</details>

<details>
<summary><img src=".github/assets/aider-favicon.png" alt="Aider logo" width="16" height="16"> Aider <code>~/.aider.conf.yml</code></summary>

Aider uses the OpenAI-compatible route with the `openai/` model prefix. Put the
stable route settings in `.aider.conf.yml`; Aider loads this file from your home
directory, then the git repo root, then the current directory, with later files
taking priority.

```yaml
# ~/.aider.conf.yml or <repo>/.aider.conf.yml
model: openai/gpt-5.5
openai-api-base: http://localhost:4000/v1
```

Keep the Pool API key out of the YAML file. Export it in the shell, or put it in
a gitignored `.env` file that Aider can load:

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
```

Check Aider from a repository with a real file edit. The command should only need
the one-off prompt when the config file is present:

```bash
aider \
  --message 'Create a file named aider-ok.txt containing exactly: aider ok. After the file exists, reply with exactly: aider ok' \
  --yes-always \
  --no-auto-commits \
  --no-git \
  --no-browser \
  --no-gui \
  --no-analytics
```

The check is only useful if the file exists with the expected content; a text
reply alone does not prove Aider can edit through the configured model path.

For deployed instances, change `openai-api-base` to
`https://codex-pooler.example.com/v1`.

</details>

<details>
<summary><img src=".github/assets/continue-favicon.png" alt="Continue logo" width="16" height="16"> Continue <code>~/.continue/config.yaml</code></summary>

Continue can use Codex Pooler as an OpenAI-compatible provider by setting
`provider: openai`, `apiBase` to `/v1`, and the Pool API key as a Continue
secret. For `gpt-5*` models, Continue uses the Responses API by default.

For local Continue configs, put the assistant in `~/.continue/config.yaml` on
macOS/Linux or `%USERPROFILE%\.continue\config.yaml` on Windows. In the IDE
extension, open the Continue chat sidebar, use the config selector above the chat
input, then click the gear icon beside **Local Config**. Continue CLI resolves
`--config` first, then its saved last-used config, then the default assistant or
`~/.continue/config.yaml` when not logged in.


```yaml
name: Codex Pooler
version: 1.0.0
schema: v1

models:
  - name: GPT-5.5 via Codex Pooler
    provider: openai
    model: gpt-5.5
    apiBase: http://localhost:4000/v1
    apiKey: "${{ secrets.CODEX_POOLER_API_KEY }}"
    roles:
      - chat
      - edit
      - apply
      - summarize
    capabilities:
      - tool_use
      - image_input

# Optional operator-only MCP metadata add-on. Omit for model/runtime use.
mcpServers:
  - name: codex_pooler
    type: streamable-http
    url: http://localhost:4000/mcp
    requestOptions:
      timeout: 30000
      headers:
        Authorization: "Bearer ${{ secrets.CODEX_POOLER_MCP_KEY }}"
```

For deployed instances, change `apiBase` to `https://codex-pooler.example.com/v1`;
if you keep the optional operator MCP add-on, change the MCP `url` to
`https://codex-pooler.example.com/mcp`.

Check the headless CLI path after saving the config:

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
npx -y @continuedev/cli@latest -p \
  --config ~/.continue/config.yaml \
  --silent \
  'Reply with exactly: continue ok'
```

The Pool API key authenticates model requests. The MCP token authenticates only
the operator metadata endpoint.

</details>

<details>
<summary><img src=".github/assets/cline-favicon.png" alt="Cline logo" width="16" height="16"> Cline <code>~/.cline</code> + <code>~/.cline/mcp.json</code></summary>

Cline CLI accepts `openai` as shorthand for its OpenAI-compatible provider and
stores it as `openai-compatible`. Configure it with the Pool API key, the Codex
Pooler `/v1` base URL, and the model id that your assigned Pool can serve.

```bash
cline auth \
  --provider openai \
  --apikey "$CODEX_POOLER_API_KEY" \
  --baseurl http://localhost:4000/v1 \
  --modelid gpt-5.5
```

Check the headless CLI path after saving auth:

```bash
cline --provider openai \
  --model gpt-5.5 \
  --json \
  --auto-approve false \
  'Reply with exactly: cline ok'
```

For optional operator MCP in Cline CLI, add the remote server to
`~/.cline/mcp.json`. Codex Pooler does not require this for model use. The VS
Code extension opens its own MCP settings JSON from the Cline MCP Servers panel;
use the same `mcpServers` shape there.

```json
{
  "mcpServers": {
    "codex_pooler": {
      "url": "http://localhost:4000/mcp",
      "headers": {
        "Authorization": "Bearer <operator-mcp-token>"
      },
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

For deployed instances, change `--baseurl` to `https://codex-pooler.example.com/v1`
and, if you keep the optional operator MCP add-on, change the MCP `url` to
`https://codex-pooler.example.com/mcp`.

Use a Pool API key for `/v1` model requests and an operator MCP token for
`/mcp`. Do not reuse the Pool API key for MCP.

</details>

<details>
<summary><img src=".github/assets/goose-favicon.png" alt="Goose logo" width="16" height="16"> Goose <code>~/.config/goose/config.yaml</code></summary>

Configure Goose's OpenAI provider for Codex Pooler's OpenAI-compatible
chat-completions path. Keep the Pool API key in `OPENAI_API_KEY` or Goose's
secret storage.

Put persistent Goose provider and extension settings in
`~/.config/goose/config.yaml` on macOS/Linux or
`%APPDATA%\Block\goose\config\config.yaml` on Windows. Goose also keeps
related files in that config area: `permission.yaml` for tool permission levels,
`secrets.yaml` when file-based secret storage is used,
`permissions/tool_permissions.json` for runtime permission decisions, and
`prompts/` for prompt templates. Environment variables have higher precedence
than the config file, so `OPENAI_API_KEY` can stay outside YAML.


```yaml
GOOSE_PROVIDER: openai
GOOSE_MODEL: gpt-5.5
OPENAI_HOST: http://localhost:4000
OPENAI_BASE_PATH: v1/chat/completions
```

Check the headless CLI path with tool access enabled:

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
goose run \
  --no-session \
  --provider openai \
  --model gpt-5.5 \
  --with-builtin developer \
  --text 'Use your developer tool to create goose-ok.txt containing exactly: goose ok. Then reply with exactly: goose ok'
```

For optional operator MCP metadata access, add a remote Streamable HTTP
extension. Codex Pooler model use does not require this. Goose stores remote
extension headers in its config, so use a dedicated MCP token.

```yaml
# Optional operator-only MCP metadata add-on. Omit for model/runtime use.
extensions:
  codex_pooler:
    enabled: true
    type: streamable_http
    name: codex_pooler
    uri: http://localhost:4000/mcp
    headers:
      Authorization: "Bearer <operator-mcp-token>"
    timeout: 300
    bundled: null
    available_tools: []
```

For deployed instances, change `OPENAI_HOST` to `https://codex-pooler.example.com`;
if you keep the optional operator MCP add-on, change the extension `uri` to
`https://codex-pooler.example.com/mcp`.

Use a Pool API key for OpenAI-compatible model requests and an operator MCP token
for `/mcp`. Do not reuse the Pool API key for MCP.

</details>

<details>
<summary><img src=".github/assets/windmill-favicon.png" alt="Windmill logo" width="16" height="16"> Windmill AI <code>customai</code> workspace provider</summary>

Windmill AI can use Codex Pooler through Windmill's `customai` provider. Point
the resource at Codex Pooler's OpenAI-compatible `/v1` surface, store the Pool
API key as a Windmill secret variable, and make the workspace AI settings use
that resource for chat and metadata generation.

Use a dedicated Pool API key for Windmill:

```bash
wmill variable add '<pool-api-key>' \
  u/<owner>/codex_pooler_windmill_codegen \
  --workspace <workspace>
```

Create a matching `customai` resource:

```yaml
description: Codex Pooler API credentials for Windmill AI
value:
  api_key: '$var:u/<owner>/codex_pooler_windmill_codegen'
  base_url: http://localhost:4000/v1
  headers: {}
resource_type: customai
```

Then set the Windmill workspace AI config to use the resource:

```yaml
providers:
  customai:
    resource_path: u/<owner>/codex_pooler_windmill_codegen
    models:
      - gpt-5.5
default_model:
  provider: customai
  model: gpt-5.5
metadata_model:
  provider: customai
  model: gpt-5.5
```

For deployed Codex Pooler instances, change `base_url` to
`https://codex-pooler.example.com/v1`. If Windmill is self-hosted and that URL
resolves to a private or internal address from the Windmill app pod or server,
set `ALLOW_PRIVATE_AI_BASE_URLS=true` on the Windmill app/server environment.

Leave Windmill's code completion model unset unless you have separately
configured a provider with fill-in-the-middle autocomplete support. Codex
Pooler's `customai` setup is for Windmill chat, script/flow/app generation,
fixes, summaries, metadata generation, and form-filling features that use chat
completion style requests.

</details>

<details>
<summary><img src=".github/assets/openhands-favicon.png" alt="OpenHands logo" width="16" height="16"> OpenHands <code>~/.openhands/</code></summary>

OpenHands CLI can use Codex Pooler through the narrow OpenAI-compatible `/v1`
surface. Keep the Pool API key in the environment, set the OpenHands base URL to
`/v1`, and use the OpenAI model prefix that OpenHands expects. The command below
uses `--override-with-envs`, so it does not persist Pool settings to OpenHands'
local state.

OpenHands CLI stores local state under `~/.openhands/`, created on first run.
Current OpenHands CLI docs list `agent_settings.json` for LLM configuration and
agent settings, `cli_config.json` for CLI preferences, `mcp.json` for MCP server
configuration, and `conversations/` for conversation history. On Windows,
OpenHands CLI runs through WSL in the upstream install docs, so those paths live
in the WSL user's home directory.

```bash
export LLM_API_KEY=<pool-api-key>
export LLM_BASE_URL=http://localhost:4000/v1
export LLM_MODEL=openai/gpt-5.5

uvx --python 3.12 --from openhands openhands \
  --headless \
  --override-with-envs \
  -t 'Check the repository and summarize what you can do.'
```

For deployed instances, change `LLM_BASE_URL` to
`https://codex-pooler.example.com/v1`. The model name should stay
`openai/gpt-5.5` so OpenHands selects its OpenAI-compatible provider path while
Codex Pooler routes the request through the assigned Pool.

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

For deployed instances, change `base_url` to `https://codex-pooler.example.com/v1`.

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

For deployed instances, change `baseURL` to `https://codex-pooler.example.com/v1`.

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

For deployed instances, change `baseURL` to `https://codex-pooler.example.com/v1`.

</details>

<details>
<summary><img src=".github/assets/claude-code-favicon.png" alt="Claude Code logo" width="16" height="16"> Claude Code</summary>

![Claude Code on Codex Pooler](.github/assets/codex-pooler-claude.png)

</details>

## Quick Start With Docker Compose

This runs the published release image with a local Postgres database. It is the
fastest way to try Codex Pooler on a laptop or small server.

Prerequisites:

- Docker with Compose
- Git, if you are cloning the repository
- `openssl`

Start Codex Pooler:

```bash
git clone https://github.com/icoretech/codex-pooler.git
cd codex-pooler

# Optional: pin a release tag before generating .env.
# Omit this for a quick trial that follows the latest tag.
# export CODEX_POOLER_IMAGE_TAG=<release-tag>

scripts/self-host/generate-env.sh
docker compose pull
docker compose up -d
```

The first run pulls the app and Postgres images, waits for Postgres health, runs
the migration container, then starts the web app.

Open `http://localhost:4000`. On the first visit, create the owner account at
`/bootstrap`, then sign in and start with `/admin/pools`.

To verify the first-run redirect before opening a browser:

```bash
curl -sS -D - -o /dev/null http://localhost:4000/ | grep -i '^location: /bootstrap'
curl -fsS http://localhost:4000/bootstrap/status
```

The status endpoint should return `{"status":"ok","bootstrap":"pending"}` on a
fresh database.

Useful commands:

```bash
docker compose ps
docker compose logs -f app
docker compose down
```

Use `http://localhost:4000` for the default Compose stack even if the Phoenix
startup banner prints an endpoint URL such as `https://localhost`; the Compose
port mapping is the local URL to open. The release image includes the OS
timezone database used for operator timezone display.

To remove the local database too:

```bash
docker compose down -v
```

## First Runtime Setup

After bootstrap:

1. Create a Pool in `/admin/pools`
2. Link, import, or invite Codex accounts in `/admin/upstreams`
3. Create a Pool API key in `/admin/api-keys`
4. Point Codex or SDK clients at one of the runtime base URLs:

Prefer `OAuth` in `/admin/upstreams` for new operator-managed upstream
accounts when browser authorization is practical. The admin dialog links the
account, stores resulting credential material through encrypted upstream secret
storage, and stays metadata-only after completion. Use `Import` only when an
existing Codex `auth.json` is the right source of credentials.

Treat an imported Codex `auth.json` as owned by Codex Pooler after import. Do
not keep using the same `auth.json` from another Codex install, machine, or
automation unless you accept that provider refresh-token rotation can invalidate
one copy and move the account to `reauth_required`.

Hosted invite onboarding and the OAuth device-code fallback use OpenAI's Codex
device-code authorization. This setup is only needed for hosted invites and the
OAuth device-code fallback; browser OAuth linking does not depend on it. For a
personal ChatGPT account, open `chatgpt.com`, go to Settings > Security, and enable
`Enable device code authorization for Codex`. For workspace-managed accounts,
ask a workspace admin to enable device-code login for Codex in the workspace
permissions. OpenAI's [Codex authentication docs](https://developers.openai.com/codex/auth)
describe device-code login. The invite or fallback flow can fail at the OpenAI
approval step when device-code authorization is off.

```text
Codex backend base URL: http://localhost:4000/backend-api/codex
OpenAI SDK base URL:    http://localhost:4000/v1
```

Use the generated Pool API key as the bearer token. That key represents the
Pool, not a single Codex account, so Codex Pooler can pick the best eligible
account for each request. Raw API keys are shown only once when created or
rotated.

## Operator Roles

The first bootstrap account is an `instance_owner`. Owners have instance-wide
administration access: they create Pools, assign operators to Pools, manage
operators, inspect global jobs, and change system settings.

Additional operators can be owners or `instance_admin`s. Instance admins are
Pool-scoped: they can work only with active Pools assigned to them and metadata
derived from those Pools. If no Pools are assigned, the admin UI shows empty
Pool-scoped states instead of exposing global data. Archiving or deleting a Pool
removes future instance-admin visibility for that Pool; historical request and
audit rows for archived or deleted Pools remain owner-only.

## Runtime Compatibility

Codex Pooler supports two client-facing shapes:

- **Codex backend clients:** `/backend-api/codex/*`, `/backend-api/files`,
  `/backend-api/transcribe`, usage routes, and backend websocket response
  streams
- **OpenAI-style SDK clients:** `/v1/models`, `/v1/responses`,
  `/v1/chat/completions`, `/v1/files`, `/v1/audio/transcriptions`, selected
  image endpoints, and narrow Responses websocket compatibility on
  `GET /v1/responses`

The `/v1` surface is compatibility, not a second engine. Supported requests are
translated into Codex-compatible calls, then routed through the same Pool rules,
limit checks, accounting, and account selection path. `/v1/realtime` and OpenAI
Realtime SDK websocket or session routes are not supported.

Public `/v1` responses preserve client-facing OpenAI shapes where possible:

- `/v1/chat/completions` returns content-filter stops as
  `finish_reason: "content_filter"`; max-output fallbacks still use the
  `finish_reason: "length"` shape.
- Server-class upstream, gateway, or provider failures redact provider and
  internal text. Clients receive safe generic server errors such as
  `upstream request failed`, while explicit local validation failures remain
  `invalid_request_error` responses with safe details.
- `/v1/files` direct uploads accept only public HTTPS upstream `upload_url`
  values. Loopback, private, reserved, NAT64, userinfo, non-HTTPS, and raw
  control or whitespace URLs are rejected before the direct PUT.

Continuity headers are local routing inputs. Codex Pooler chooses them in this
order: `x-codex-window-id` > `x-codex-session-id` > `session-id` >
`x-session-id` > `x-session-affinity` > `session_id` >
`x-codex-conversation-id`. `session-id`, `x-session-id`, and
`x-session-affinity` are not forwarded upstream. The raw `x-codex-window-id`
value is hashed before it becomes a local persisted session key. Local timing
regressions showed `/v1/responses` HTTP streaming and Responses websocket paths
stay inside the observed client budgets with the existing stream timeout
settings, so no new route-specific timeout defaults are required.

Backend regular HTTP Responses and compact routes forward request-scoped
`x-codex-turn-state` plus the approved lineage metadata headers upstream:
`x-codex-turn-metadata`, `x-codex-window-id`,
`x-codex-parent-thread-id`, `x-codex-installation-id`, and
`x-openai-subagent`. They also relay upstream `x-codex-turn-state` response
headers downstream. Public `/v1/responses` and websocket request headers do not
use that backend-only forwarding lane; backend websocket request-scoped turn
state travels in `response.create.client_metadata["x-codex-turn-state"]`, and
raw metadata values are not persisted.

Request compression is a per-Pool admin option stored as
`request_compression_enabled`. It is disabled by default. When enabled, Codex
Pooler can rewrite request-side Responses tool-output payloads before upstream
dispatch for these routes only: `POST /backend-api/codex/responses`,
`POST /backend-api/codex/v1/responses`,
`POST /backend-api/codex/v1/chat/completions`, `POST /v1/responses`,
`POST /v1/chat/completions`, `POST /backend-api/codex/responses/compact`,
`POST /backend-api/codex/v1/responses/compact`, and backend or narrow public
Responses websocket `response.create` work. Multipart, file, audio, image,
admin, MCP, usage, and control-plane requests are not eligible; public
`/v1/responses/compact` remains unsupported because it has no upstream compact
dispatch.

Request compression is request-side only. Codex Pooler does not store raw tool
outputs or raw response bodies.

## Operator MCP Service

Codex Pooler includes an optional metadata-only MCP endpoint at `/mcp` for
trusted operators who want an MCP host to inspect Pools, upstream accounts, Pool
API key metadata, operators, invites, request logs, audit logs, and MCP service
status. This operator add-on is not required for Codex Pooler runtime clients.
The service is read-only and has no mutation tools. It uses the same owner vs
assigned-Pool visibility model as the admin UI, but connected MCP hosts can read
the metadata visible to that operator, so only connect hosts you trust with that
view.

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
- `PHX_HOST`, `PORT`, and `PHX_SERVER`, HTTP endpoint boot settings
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

## Deployment

Docker Compose is the easiest way to try the software. For Kubernetes, use the
`icoretech/codex-pooler` Helm chart from the
[iCoreTech Helm repository](https://github.com/icoretech/helm). The chart
deploys the same release image with separate app, worker, scheduler, and
migration roles. It expects an explicit immutable image tag for real
deployments. Official release images include the OS IANA timezone database used
for operator timezone display. Custom runtime images or hosts must provide
zoneinfo files at `/usr/share/zoneinfo` or set `TZDIR`. The chart defaults the
web app to one replica because backend
websocket continuity owns a live upstream websocket in an app pod. Owner-alive
cross-node forwarding is wired, but scaling web replicas still requires
clustering, owner-forwarding, and the explicit unsafe topology acknowledgement
until Kubernetes deployment validation relaxes that guard.

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
are written to the local development server log.

Development seeds are optional and only run through the explicit seed task. To
create a compact idempotent operator baseline with one owner plus four example
operators, run:

```bash
mix dev.seed compact
```

All seeded operators use `dev-password-123`.

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
```

Helm chart validation lives with the published chart in the iCoreTech Helm
repository when Kubernetes deployment behavior or values change.

`mix test` and `mix precommit` serialize database-backed test runs with a
PostgreSQL advisory lock keyed by the configured test database, so concurrent
local runs wait instead of deadlocking the shared sandbox database.

## Star History

<a href="https://www.star-history.com/?repos=icoretech%2Fcodex-pooler&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&legend=top-left" />
 </picture>
</a>
