<h1 align="center">Codex Pooler</h1>

<p align="center">
  <strong>The full featured self-hosted Codex gateway, for teams, agents and you. Works with:</strong><br>
  <br>
  <a href="https://docs.codex-pooler.com/clients/codex-cli-desktop/" title="Codex CLI and Codex Desktop"><img src=".github/assets/codex-cli-favicon.png" alt="Codex CLI and Codex Desktop" width="24" height="24"></a>
  <a href="#opencode-setup" title="OpenCode"><img src=".github/assets/opencode-v2-favicon.png" alt="OpenCode" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openclaw/" title="OpenClaw"><img src=".github/assets/openclaw-favicon.png" alt="OpenClaw" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/hermes/" title="Hermes Agent"><img src=".github/assets/hermes-favicon.png" alt="Hermes Agent" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/pi/" title="Pi"><img src=".github/assets/pi-favicon.png" alt="Pi" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/omp/" title="OMP"><img src=".github/assets/omp-favicon.png" alt="OMP" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/cursor/" title="Cursor"><img src=".github/assets/cursor-favicon.png" alt="Cursor" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/kilo-code/" title="Kilo Code"><img src=".github/assets/kilo-favicon.png" alt="Kilo Code" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/trae/" title="Trae"><img src=".github/assets/trae-favicon.png" alt="Trae" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/aider/" title="Aider"><img src=".github/assets/aider-favicon.png" alt="Aider" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/continue/" title="Continue"><img src=".github/assets/continue-favicon.png" alt="Continue" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/cline/" title="Cline"><img src=".github/assets/cline-favicon.png" alt="Cline" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/goose/" title="Goose"><img src=".github/assets/goose-favicon.png" alt="Goose" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/deepseek-harness/" title="DeepSeek Harness"><img src=".github/assets/deepseek-harness-favicon.png" alt="DeepSeek Harness" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/windmill/" title="Windmill AI"><img src=".github/assets/windmill-favicon.png" alt="Windmill AI" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openhands/" title="OpenHands"><img src=".github/assets/openhands-favicon.png" alt="OpenHands" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="OpenAI-compatible SDKs"><img src=".github/assets/python-favicon.png" alt="OpenAI-compatible SDKs" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="OpenAI-compatible SDKs"><img src=".github/assets/nodejs-favicon.png" alt="OpenAI-compatible SDKs" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="Vercel AI SDK"><img src=".github/assets/vercel-favicon.png" alt="Vercel AI SDK" width="24" height="24"></a>
</p>

<p align="center">
  <strong>English</strong>
  ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#quick-start-with-docker-compose">Quick start</a>
  ·
  <a href="#harness-configuration">Harness</a>
  ·
  <a href="#configuration">Configuration</a>
  ·
  <a href="#deployment">Deployment</a>
  ·
  <a href="https://x.com/icoretech_inc">X</a>
  ·
  <a href="https://reddit.com/r/CodexPooler">Reddit</a>
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

Codex Pooler is a self-hosted gateway for running Codex-compatible agents,
tools, and automation through stable Pool API keys. It works with one upstream
Codex account for credential isolation, client normalization, metadata-only
operations, and saved reset visibility; add more accounts when you want shared
capacity and routing across eligible accounts.

Clients send familiar Codex backend or OpenAI-compatible requests; Codex Pooler
selects an eligible account based on model support, quota evidence, limits,
session continuity, routing policy, and health. The Pool key stays stable while
upstream assignments, lifecycle state, reset policy, and capacity change behind
it.

Operators get one place to manage Pools, accounts, API keys, saved resets,
routing, request accounting, audit logs, and health without storing prompts,
files, audio, images, bearer tokens, or raw Codex secrets. Instance owners keep
the global administration surface, while instance admins work only with their
assigned Pools.

## Highlights

- 🧩 **Use the tools you already know:** connect Codex, OpenCode and other
  supported coding agents, plus apps built with OpenAI-compatible SDKs
- 🔑 **One key for your apps:** connect tools with a Pool API key that stays the
  same when you add or replace Codex accounts, without sharing account credentials
- ⚡ **High cache reuse across protocols:** over 95% cached input observed on
  HTTP/SSE and WebSockets, backed by cache-aware routing and connection reuse
- 🎯 **Automatic account selection:** send requests to accounts that can serve
  the chosen model, with available quota and account health taken into account
- 📏 **Control how much each key can use:** set request limits and daily or
  weekly AI usage allowances
- 🚀 **Give agents more room to work:** let them use several tools at once in
  Full mode, with Lite compatibility when needed
- 🖼️ **Images and voice, too:** generate and edit images or transcribe audio
  through supported apps, using the same Pool API key
- 🛡️ **Keep conversation content private:** track usage and troubleshoot requests
  without saving prompts, replies, uploaded files, images or audio
- 🔁 **Keep conversations together:** keep supported sessions linked to the
  right account when a client reconnects
- 🔭 **Let users track their own usage:** enable a personal Observatory dashboard
  for each key, showing activity, response times and estimated costs
- 🏦 **Put saved resets to use:** see available reset credits and use them to
  restore account quota, manually or automatically when enabled
- 🖥️ **Manage everything in one place:** add accounts, manage keys and invites,
  check usage and change settings from a browser
- 👥 **Organize teams and projects:** group accounts into Pools with their own
  access rules and model choices
- 🤝 **Connect accounts by invitation:** let account owners join a Pool through
  a guided browser flow, without sending you credential files
- 🚨 **Know when attention is needed:** receive alerts about low capacity,
  account problems and reset events in the dashboard, by email or through webhooks
- 🗜️ **Send smaller requests:** optionally shrink supported tool outputs before
  sending them to the AI provider, and see how much was saved
- 🧷 **Fill in missing continuity:** derive stable session identities from cache
  keys or conversation IDs when a harness does not send them directly
- 🧱 **Choose who can connect:** optionally allow requests only from approved
  networks
- 🐳 **Run it on your own infrastructure:** start with Docker Compose or deploy
  on Kubernetes as your needs grow

## Harness Configuration

Start with a running Codex Pooler instance, a Pool API key, and an installed
client. The examples include `gpt-6-luna`, `gpt-6-sol` and `gpt-6-astra`, with
Sol selected by default. Keep the models available to your Pool.
Replace `<pool-api-key>` with your key and run the command for your terminal
before starting the client.

**macOS / Linux / Windows WSL (bash or zsh)**

```bash
export CODEX_POOLER_API_KEY="<pool-api-key>"
```

**Windows PowerShell**

```powershell
$env:CODEX_POOLER_API_KEY = "<pool-api-key>"
```

These commands set the key for the current terminal. For desktop apps, follow
the linked guide to save the key for the app.

The paths below are defaults. On macOS/Linux, `~` is your home folder.
On Windows, paste paths starting with `%USERPROFILE%`, `%APPDATA%` or
`%LOCALAPPDATA%` into File Explorer's address bar. If you installed a client
inside WSL, use its Linux paths and commands inside WSL. Custom configuration
folders or profiles take precedence over these defaults.

For a local instance:

| Client | Base URL |
| --- | --- |
| Codex CLI / Desktop | `http://localhost:4000/backend-api/codex` |
| Other harnesses and SDKs | `http://localhost:4000/v1` |

For a deployed instance, replace `http://localhost:4000` with your instance's
host, such as `https://codex-pooler.example.com`. Merge snippets into existing
configurations. The examples use the large **828,400-token context** for GPT-6.
Codex CLI and Desktop read the available context size automatically from your Pool.

Each entry covers the basic connection. Its **full setup & extras** link covers
installation, advanced options and troubleshooting. Operator MCP is optional
and uses a separate token; see [Operator MCP Service](#operator-mcp-service).

<details>
<summary><img src=".github/assets/codex-cli-favicon.png" alt="Codex logo" width="16" height="16"> Codex CLI and Codex Desktop <code>config.toml</code></summary>

![Codex Pooler integration for Codex CLI and Codex Desktop](.github/assets/codex-pooler-codex.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.codex/config.toml` |
| Windows | `%USERPROFILE%\.codex\config.toml` |

Open `config.toml` at the path for your system and add the following. If you
set `CODEX_HOME`, use the file in that folder instead. If the file already has
a `[features]` section, add the setting to that section.

```toml
model = "gpt-6-sol"
model_provider = "codex-pooler-ws"

[model_providers.codex-pooler-ws]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
model_catalog_url = "http://localhost:4000/backend-api/codex/models"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true

[features]
api_key_model_discovery = true
```

Restart Codex and choose a model available to your Pool.
If you use Codex Desktop,
follow the full guide to make your API key available to the app.

**[Full setup & extras](https://docs.codex-pooler.com/clients/codex-cli-desktop/)** — desktop setup, account settings and existing conversations.

</details>

<a id="opencode-setup"></a>

<details>
<summary><img src=".github/assets/opencode-v2-favicon.png" alt="OpenCode logo" width="16" height="16"> OpenCode <code>opencode.jsonc</code></summary>

![Codex Pooler OpenCode integration](.github/assets/codex-pooler-opencode.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.config/opencode/opencode.jsonc` |
| Windows | `%USERPROFILE%\.config\opencode\opencode.jsonc` |

Open `opencode.jsonc` at the path for your system and add the configuration
for your OpenCode version below.

**OpenCode v2**

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "codex-pooler/gpt-6-sol",
  "agents": {
    "title": {
      "model": "codex-pooler/gpt-6-luna"
    }
  },
  "providers": {
    "codex-pooler": {
      "package": "@opencode/ai/providers/openai/responses",
      "settings": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "{env:CODEX_POOLER_API_KEY}",
        "transport": "http",
        "compaction": {
          "type": "summary"
        }
      },
      "models": {
        "gpt-6-luna": {
          "modelID": "gpt-6-luna",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 32000 },
          "settings": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto"
          }
        },
        "gpt-6-sol": {
          "modelID": "gpt-6-sol",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 32000 },
          "settings": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto"
          }
        },
        "gpt-6-astra": {
          "modelID": "gpt-6-astra",
          "capabilities": {
            "tools": true,
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 32000 },
          "settings": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto"
          }
        }
      }
    }
  }
}
```

**[OpenCode v2 full setup & extras](https://docs.codex-pooler.com/clients/opencode-v2/)** — installation and advanced options.

**OpenCode v1**

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "openai/gpt-6-sol",
  "small_model": "openai/gpt-6-luna",
  "provider": {
    "openai": {
      "npm": "@ai-sdk/openai",
      "name": "Codex Pooler",
      "options": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "{env:CODEX_POOLER_API_KEY}"
      },
      "models": {
        "gpt-6-luna": {
          "id": "gpt-6-luna",
          "name": "GPT-6 Luna",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "include": ["reasoning.encrypted_content"]
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        },
        "gpt-6-sol": {
          "id": "gpt-6-sol",
          "name": "GPT-6 Sol",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "include": ["reasoning.encrypted_content"]
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        },
        "gpt-6-astra": {
          "id": "gpt-6-astra",
          "name": "GPT-6 Astra",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "include": ["reasoning.encrypted_content"]
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        }
      }
    }
  }
}
```

**[OpenCode v1 full setup & extras](https://docs.codex-pooler.com/clients/opencode/)** — installation and OMO setup.

</details>

<details>
<summary><img src=".github/assets/openclaw-favicon.png" alt="OpenClaw logo" width="16" height="16"> OpenClaw <code>openclaw.json</code></summary>

![Codex Pooler OpenClaw integration](.github/assets/codex-pooler-openclaw.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.openclaw/openclaw.json` |
| Windows | `%USERPROFILE%\.openclaw\openclaw.json` |

Open `openclaw.json` at the path for your system and add this configuration:

```json5
{
  agents: {
    defaults: {
      model: {
        primary: "openai/gpt-6-sol",
        list: [{ id: "background", model: "openai/gpt-6-luna" }],
      },
      compaction: { reserveTokens: 128000 },
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
            id: "gpt-6-luna",
            name: "GPT-6 Luna via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 828400,
            contextTokens: 828400,
            maxTokens: 128000,
          },
          {
            id: "gpt-6-sol",
            name: "GPT-6 Sol via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 828400,
            contextTokens: 828400,
            maxTokens: 128000,
          },
          {
            id: "gpt-6-astra",
            name: "GPT-6 Astra via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 828400,
            contextTokens: 828400,
            maxTokens: 128000,
          },
        ],
      },
    },
  },
}
```

Restart OpenClaw and start a new conversation.

**[Full setup & extras](https://docs.codex-pooler.com/clients/openclaw/)** — background tasks, more models and advanced options.

</details>

<details>
<summary><img src=".github/assets/hermes-favicon.png" alt="Hermes Agent logo" width="16" height="16"> Hermes Agent <code>config.yaml</code></summary>

![Codex Pooler Hermes Agent integration](.github/assets/codex-pooler-hermes.png)

| System | Folder for `.env` and `config.yaml` |
| --- | --- |
| macOS / Linux | `~/.hermes/` |
| Windows | `%LOCALAPPDATA%\hermes\` |

Open `.env` in the folder for your system and add your Pool API key and
Codex Pooler address. If you set `HERMES_HOME`, use that folder instead:

```dotenv
OPENAI_API_KEY=<pool-api-key>
OPENAI_BASE_URL=http://localhost:4000/v1
STT_OPENAI_BASE_URL=http://localhost:4000/v1
```

Add this to `config.yaml` in the same folder, then restart Hermes:

```yaml
model:
  default: gpt-6-sol
  provider: openai-api
  base_url: http://localhost:4000/v1
  api_mode: codex_responses
  context_length: 828400
  supports_vision: true

agent:
  image_input_mode: native
  api_max_retries: 2
  auto_recovery_cycles: 1

image_gen:
  provider: openai
  model: gpt-image-2.5-flare-medium

stt:
  enabled: true
  provider: openai
  openai:
    model: gpt-4o-transcribe

compression:
  threshold: 0.95

auxiliary:
  compression:
    timeout: 900
```

This setup includes image generation and voice-to-text. To switch the chat
model, set `model.default` to a model available to your Pool.
Keep all three addresses pointed at your Codex Pooler instance. Your Pool must
also offer the image and transcription models to use those features.

**[Full setup & extras](https://docs.codex-pooler.com/clients/hermes/)** — images, speech-to-text, priority processing and troubleshooting.

</details>

<details>
<summary><img src=".github/assets/pi-favicon.png" alt="Pi logo" width="16" height="16"> Pi <code>models.json</code></summary>

![Codex Pooler Pi integration](.github/assets/codex-pooler-pi.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.pi/agent/models.json` |
| Windows | `%USERPROFILE%\.pi\agent\models.json` |

Open `models.json` at the path for your system and add this configuration:

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
          "id": "gpt-6-luna",
          "name": "GPT-6 Luna via Codex Pooler",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 828400,
          "maxTokens": 128000,
          "thinkingLevelMap": { "xhigh": "xhigh" }
        },
        {
          "id": "gpt-6-sol",
          "name": "GPT-6 Sol via Codex Pooler",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 828400,
          "maxTokens": 128000,
          "thinkingLevelMap": { "xhigh": "xhigh" }
        },
        {
          "id": "gpt-6-astra",
          "name": "GPT-6 Astra via Codex Pooler",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 828400,
          "maxTokens": 128000,
          "thinkingLevelMap": { "xhigh": "xhigh" }
        }
      ]
    }
  }
}
```

Add these defaults to `settings.json` in the same folder:

```json
{
  "defaultProvider": "codex-pooler",
  "defaultModel": "gpt-6-sol",
  "enabledModels": [
    "codex-pooler/gpt-6-luna",
    "codex-pooler/gpt-6-sol",
    "codex-pooler/gpt-6-astra"
  ],
  "compaction": { "reserveTokens": 128000 }
}
```

Then start Pi:

```bash
pi
```

**[Full setup & extras](https://docs.codex-pooler.com/clients/pi/)** — installation, default models and extra options.

</details>

<details>
<summary><img src=".github/assets/omp-favicon.png" alt="OMP logo" width="16" height="16"> OMP <code>models.yml</code></summary>

![Codex Pooler OMP integration](.github/assets/codex-pooler-omp.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.omp/agent/models.yml` |
| Windows | `%USERPROFILE%\.omp\agent\models.yml` |

Open `models.yml` at the path for your system and add this configuration:

```yaml
providers:
  codex-pooler:
    baseUrl: http://localhost:4000/v1
    api: openai-responses
    apiKey: CODEX_POOLER_API_KEY
    authHeader: true
    remoteCompaction:
      enabled: true
      api: openai-codex-responses
      endpoint: http://localhost:4000/backend-api/codex/responses/compact
      v2StreamingEnabled: true
      v2Endpoint: http://localhost:4000/backend-api/codex/responses
    models:
      - id: gpt-6-luna
        name: GPT-6 Luna via Codex Pooler
        reasoning: true
        input: [text, image]
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 828400
        maxTokens: 128000
      - id: gpt-6-sol
        name: GPT-6 Sol via Codex Pooler
        reasoning: true
        input: [text, image]
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 828400
        maxTokens: 128000
      - id: gpt-6-astra
        name: GPT-6 Astra via Codex Pooler
        reasoning: true
        input: [text, image]
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 828400
        maxTokens: 128000
```

Add these defaults to `config.yml` in the same folder:

```yaml
startup:
  setupWizard: false
enabledModels:
  - codex-pooler/gpt-6-luna
  - codex-pooler/gpt-6-sol
  - codex-pooler/gpt-6-astra
modelProviderOrder:
  - codex-pooler
modelRoles:
  default: codex-pooler/gpt-6-sol:high
  smol: codex-pooler/gpt-6-luna:low
  tiny: codex-pooler/gpt-6-luna:minimal
  slow: codex-pooler/gpt-6-astra:xhigh
  plan: codex-pooler/gpt-6-astra:xhigh
  task: codex-pooler/gpt-6-sol:high
  vision: codex-pooler/gpt-6-sol:high
  advisor: codex-pooler/gpt-6-sol:medium
  commit: codex-pooler/gpt-6-luna:minimal
  designer: codex-pooler/gpt-6-astra:high
compaction:
  enabled: true
  thresholdPercent: 95
  reserveTokens: 128000
  remoteStreamingV2Enabled: true
  midTurnEnabled: true
  handoffSaveToDisk: true
```

Then start OMP:

```bash
omp
```

**[Full setup & extras](https://docs.codex-pooler.com/clients/omp/)** — installation, model choices and long conversations.

</details>

<details>
<summary><img src=".github/assets/cursor-favicon.png" alt="Cursor logo" width="16" height="16"> Cursor <code>Settings → Models → API Keys</code></summary>

![Codex Pooler Cursor integration](.github/assets/codex-pooler-cursor.png)

In **Settings → Models → API Keys**, enable **OpenAI API Key** and
**Override OpenAI Base URL**. Enter your Pool API key and a public HTTPS URL
such as `https://codex-pooler.example.com/v1`, then select a model available
to your Pool.

Cursor BYOK requires **Pro or higher**. Requests pass through Cursor's
servers, so localhost and private LAN URLs do not work. Use an explicit model
instead of Auto mode.

**[Full setup & extras](https://docs.codex-pooler.com/clients/cursor/)** — prerequisites, model selection and connection checks.

</details>

<details>
<summary><img src=".github/assets/kilo-favicon.png" alt="Kilo Code logo" width="16" height="16"> Kilo Code <code>kilo.jsonc</code></summary>

![Codex Pooler Kilo Code integration](.github/assets/codex-pooler-kilo.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.config/kilo/kilo.jsonc` |
| Windows | `%USERPROFILE%\.config\kilo\kilo.jsonc` |

Open `kilo.jsonc` at the path for your system and add this configuration:

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",
  "model": "codex-pooler/gpt-6-sol",
  "enabled_providers": ["codex-pooler"],
  "provider": {
    "codex-pooler": {
      "options": {
        "apiKey": "{env:CODEX_POOLER_API_KEY}",
        "baseURL": "http://localhost:4000/v1"
      },
      "models": {
        "gpt-6-luna": {
          "name": "GPT-6 Luna via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        },
        "gpt-6-sol": {
          "name": "GPT-6 Sol via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        },
        "gpt-6-astra": {
          "name": "GPT-6 Astra via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": { "context": 828400, "input": 828400, "output": 64000 }
        }
      }
    }
  }
}
```

Restart Kilo and select the Codex Pooler model.

**[Full setup & extras](https://docs.codex-pooler.com/clients/kilo-code/)** — installation, model choices and extra options.

</details>

<details>
<summary><img src=".github/assets/trae-favicon.png" alt="Trae logo" width="16" height="16"> Trae <code>Settings -> Models</code></summary>

Sign in to Trae, open **Settings → Models**, and add a custom model:

| Field | Value |
| --- | --- |
| API format | OpenAI Chat Completions |
| Custom Request URL | `http://localhost:4000/v1` |
| Full URL | Off |
| Model ID | `gpt-6-sol` |
| API key | Your Pool API key |
| Model Series | Default |

Repeat this setup with another Model ID to add more models available to your Pool.

Do not add a trailing slash to the URL. Save the model, turn **Auto Mode**
off in the agent model picker, and select it under **Custom Models**.

**[Full setup & extras](https://docs.codex-pooler.com/clients/trae/)** — Trae CN, extra settings and connection checks.

</details>

<details>
<summary><img src=".github/assets/aider-favicon.png" alt="Aider logo" width="16" height="16"> Aider <code>.aider.conf.yml</code></summary>

![Codex Pooler Aider integration](.github/assets/codex-pooler-aider.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.aider.conf.yml` |
| Windows | `%USERPROFILE%\.aider.conf.yml` |

Open `.aider.conf.yml` at the path for your system and add these settings:

```yaml
model: openai/gpt-6-sol
openai-api-base: http://localhost:4000/v1
```

Keep the Pool API key in the environment, then start Aider from your repository:

**macOS / Linux / WSL**

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
aider
```

**Windows PowerShell**

```powershell
$env:OPENAI_API_KEY = $env:CODEX_POOLER_API_KEY
aider
```

If Aider does not recognize the model, follow the additional setup in the
full guide.

To switch models, set `model` to a model available to your Pool, keeping the
`openai/` prefix.

**[Full setup & extras](https://docs.codex-pooler.com/clients/aider/)** — additional model setup and editing files.

</details>

<details>
<summary><img src=".github/assets/continue-favicon.png" alt="Continue logo" width="16" height="16"> Continue <code>config.yaml</code></summary>

![Codex Pooler Continue integration](.github/assets/codex-pooler-continue.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.continue/config.yaml` |
| Windows | `%USERPROFILE%\.continue\config.yaml` |

Save your Pool API key in Continue as `CODEX_POOLER_API_KEY` using the
[secret setup instructions](https://docs.codex-pooler.com/clients/continue/).
Then open `config.yaml` at the path for your system and add this configuration:

```yaml
name: Codex Pooler
version: 1.0.0
schema: v1

models:
  - name: GPT-6 Luna via Codex Pooler
    provider: openai
    model: gpt-6-luna
    apiBase: http://localhost:4000/v1
    apiKey: "${{ secrets.CODEX_POOLER_API_KEY }}"
    contextLength: 828400
    defaultCompletionOptions:
      maxTokens: 128000
    roles: [chat, edit, apply, summarize]
    capabilities: [tool_use, image_input]
  - name: GPT-6 Sol via Codex Pooler
    provider: openai
    model: gpt-6-sol
    apiBase: http://localhost:4000/v1
    apiKey: "${{ secrets.CODEX_POOLER_API_KEY }}"
    contextLength: 828400
    defaultCompletionOptions:
      maxTokens: 128000
    roles: [chat, edit, apply, summarize]
    capabilities: [tool_use, image_input]
  - name: GPT-6 Astra via Codex Pooler
    provider: openai
    model: gpt-6-astra
    apiBase: http://localhost:4000/v1
    apiKey: "${{ secrets.CODEX_POOLER_API_KEY }}"
    contextLength: 828400
    defaultCompletionOptions:
      maxTokens: 128000
    roles: [chat, edit, apply, summarize]
    capabilities: [tool_use, image_input]
```

Select this configuration and the Codex Pooler model in Continue.

**[Full setup & extras](https://docs.codex-pooler.com/clients/continue/)** — saving your API key, extra settings and CLI usage.

</details>

<details>
<summary><img src=".github/assets/cline-favicon.png" alt="Cline logo" width="16" height="16"> Cline</summary>

![Codex Pooler Cline integration](.github/assets/codex-pooler-cline.png)

For Cline CLI, save the connection settings with:

**macOS / Linux / WSL**

```bash
cline auth \
  --provider openai \
  --apikey "$CODEX_POOLER_API_KEY" \
  --baseurl http://localhost:4000/v1 \
  --modelid gpt-6-sol
```

**Windows PowerShell**

```powershell
cline auth --provider openai --apikey "$env:CODEX_POOLER_API_KEY" --baseurl http://localhost:4000/v1 --modelid gpt-6-sol
```

Start Cline and use the saved model. In the IDE extension, choose
**OpenAI Compatible** and enter the same address, API key and model.

Set `--modelid` to a model available to your Pool.

**[Full setup & extras](https://docs.codex-pooler.com/clients/cline/)** — IDE setup, extra settings and connection checks.

</details>

<details>
<summary><img src=".github/assets/goose-favicon.png" alt="Goose logo" width="16" height="16"> Goose <code>config.yaml</code></summary>

![Codex Pooler Goose integration](.github/assets/codex-pooler-goose.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.config/goose/config.yaml` |
| Windows | `%APPDATA%\Block\goose\config\config.yaml` |

Open `config.yaml` at the path for your system and add this configuration:

```yaml
GOOSE_PROVIDER: openai
GOOSE_MODEL: gpt-6-sol
OPENAI_HOST: http://localhost:4000
OPENAI_BASE_PATH: v1/chat/completions
GOOSE_CONTEXT_LIMIT: 828400
GOOSE_MAX_TOKENS: 128000
```

Run this in your terminal before starting Goose:

**macOS / Linux / WSL**

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
```

**Windows PowerShell**

```powershell
$env:OPENAI_API_KEY = $env:CODEX_POOLER_API_KEY
```

To switch models, set `GOOSE_MODEL` to a model available to your Pool.

**[Full setup & extras](https://docs.codex-pooler.com/clients/goose/)** — tools, extra settings and Windows setup.

</details>

<details>
<summary><img src=".github/assets/deepseek-harness-favicon.png" alt="DeepSeek Harness logo" width="16" height="16"> DeepSeek Harness (<code>dsh</code>) <code>cordis.patch.yml</code></summary>

![Codex Pooler DeepSeek Harness integration](.github/assets/codex-pooler-deepseek.png)

| System | Configuration file |
| --- | --- |
| macOS / Linux | `~/.dsh/profiles/headless/cordis.patch.yml` |
| Windows | `%USERPROFILE%\.dsh\profiles\headless\cordis.patch.yml` |

Run `dsh --profile headless --dump-default-config` once to create the
configuration, then open `cordis.patch.yml` at the path for your system and
add the following. If you set `DSH_HOME`, use its `profiles/headless` folder:

```yaml
- id: llm-pi-ai
  config:
    providers:
      codex-pooler:
        apiKeyEnv: CODEX_POOLER_API_KEY
        api: openai-responses
        compat:
          supportsStrictMode: true
        baseURL: http://localhost:4000/v1
        models:
          - id: gpt-6-luna
            contextWindow: 828400
          - id: gpt-6-sol
            contextWindow: 828400
          - id: gpt-6-astra
            contextWindow: 828400
- id: agent-default-model
  config:
    provider: codex-pooler
    model: gpt-6-sol
```

Keep any existing settings in these entries when adding the configuration.
Start DeepSeek Harness with `dsh --profile headless`.

**[Full setup & extras](https://docs.codex-pooler.com/clients/deepseek-harness/)** — installation, tools and extra settings.

</details>

<details>
<summary><img src=".github/assets/windmill-favicon.png" alt="Windmill logo" width="16" height="16"> Windmill AI <code>customai</code> workspace provider</summary>

![Codex Pooler Windmill AI integration](.github/assets/codex-pooler-windmill.png)

Store a dedicated Pool API key as a Windmill secret variable, then create a
`customai` resource that references it:

```yaml
description: Codex Pooler API credentials for Windmill AI
value:
  api_key: '$var:u/<owner>/codex_pooler'
  base_url: http://localhost:4000/v1
  headers: {}
resource_type: customai
```

In workspace AI settings, use the resource you just created and add all three
models. The matching configuration is:

```yaml
providers:
  customai:
    resource_path: u/<owner>/codex_pooler
    models:
      - gpt-6-luna
      - gpt-6-sol
      - gpt-6-astra
default_model:
  provider: customai
  model: gpt-6-sol
metadata_model:
  provider: customai
  model: gpt-6-luna
```

Use a URL reachable from the Windmill server; private addresses require
`ALLOW_PRIVATE_AI_BASE_URLS=true` on that server.

**[Full setup & extras](https://docs.codex-pooler.com/clients/windmill/)** — resource creation, workspace configuration and supported features.

</details>

<details>
<summary><img src=".github/assets/openhands-favicon.png" alt="OpenHands logo" width="16" height="16"> OpenHands</summary>

![Codex Pooler OpenHands integration](.github/assets/codex-pooler-openhands.png)

Run these commands on macOS or Linux, or inside WSL on Windows:

```bash
export LLM_API_KEY="$CODEX_POOLER_API_KEY"
export LLM_BASE_URL=http://localhost:4000/v1
export LLM_MODEL=openai/gpt-6-sol

openhands --override-with-envs
```

These settings apply to this run. The full guide explains how to save them.

To switch models, set `LLM_MODEL` to a model available to your Pool, keeping the
`openai/` prefix.

**[Full setup & extras](https://docs.codex-pooler.com/clients/openhands/)** — installation, persistent settings and model options.

</details>

<details>
<summary><img src=".github/assets/python-favicon.png" alt="Python logo" width="16" height="16"> OpenAI Python SDK</summary>

With OpenAI Python SDK installed and `CODEX_POOLER_API_KEY` set, point the
client at Codex Pooler's `/v1` endpoint:

```python
import os

from openai import OpenAI

client = OpenAI(
    api_key=os.environ["CODEX_POOLER_API_KEY"],
    base_url="http://localhost:4000/v1",
)

response = client.responses.create(
    model="gpt-6-sol",
    input="Write a one-sentence status update.",
)

print(response.output_text)
```

Use a model available to your Pool.

**[Full setup & extras](https://docs.codex-pooler.com/clients/openai-compatible/)** — streaming, tools, media and API compatibility.

</details>

<details>
<summary><img src=".github/assets/nodejs-favicon.png" alt="Node.js logo" width="16" height="16"> OpenAI Node SDK</summary>

With OpenAI Node SDK installed and `CODEX_POOLER_API_KEY` set, point the
client at Codex Pooler's `/v1` endpoint:

```js
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const response = await client.responses.create({
  model: "gpt-6-sol",
  input: "Write a one-sentence status update.",
});

console.log(response.output_text);
```

Use a model available to your Pool.

**[Full setup & extras](https://docs.codex-pooler.com/clients/openai-compatible/)** — streaming, tools, media and API compatibility.

</details>

<details>
<summary><img src=".github/assets/vercel-favicon.png" alt="Vercel logo" width="16" height="16"> Vercel AI SDK</summary>

With Vercel AI SDK installed and `CODEX_POOLER_API_KEY` set, point the
client at Codex Pooler's `/v1` endpoint:

```ts
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";

const pooler = createOpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const { text } = await generateText({
  model: pooler.responses("gpt-6-sol"),
  prompt: "Write a one-sentence status update.",
});

console.log(text);
```

Use a model available to your Pool.

**[Full setup & extras](https://docs.codex-pooler.com/clients/openai-compatible/)** — streaming, tools, media and API compatibility.

</details>

<details>
<summary><img src=".github/assets/claude-code-favicon.png" alt="Claude Code logo" width="16" height="16"> Claude Code</summary>

![Claude Code on Codex Pooler](.github/assets/codex-pooler-claude.png)

</details>

## Quick Start With Docker Compose

This runs the published release image with a local Postgres database. It is the
fastest way to try Codex Pooler on a laptop or small server.
For normal use, run a versioned, tagged stable release from [GitHub Releases](https://github.com/icoretech/codex-pooler/releases). The `latest` image tag follows the most recently published release, but a version tag keeps the installation reproducible; run from source only in [Local Development](#local-development).

Prerequisites:

- Docker with Compose
- Git, if you are cloning the repository
- `openssl`

Start Codex Pooler:

```bash
git clone https://github.com/icoretech/codex-pooler.git
cd codex-pooler

# Run the latest tagged stable release. Find its version at
# https://github.com/icoretech/codex-pooler/releases, then substitute it here.
export CODEX_POOLER_IMAGE_TAG=<release-tag>

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

To upgrade an existing Compose install, set `CODEX_POOLER_IMAGE_TAG` in `.env`
to the target tagged stable release, then run:

```bash
docker compose pull
docker compose up -d
```

The Compose stack has a one-shot `migrate` service. It waits for Postgres, runs
release migrations, imports the bundled pricing snapshot, and exits before the
web app starts. Normal app boot does not migrate the database by itself. If a
failed migration needs to be rerun after fixing configuration or database
access, run:

```bash
docker compose up -d db
docker compose run --rm migrate
docker compose up -d app
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
2. Link, import, or invite one or more Codex accounts in `/admin/upstreams`
3. Create a Pool API key in `/admin/api-keys`
4. Point Codex or SDK clients at one of the runtime base URLs:

One upstream account is enough for a working setup. Additional upstreams expand
the same Pool into shared capacity without changing client credentials.

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

Use the client guides when wiring a specific tool. At a glance, clients pick one
of two public shapes:

- **Codex backend clients** use `/backend-api/codex` for Codex-native behavior
  such as sessions, compacting, files, audio, images, and backend websockets.
- **OpenAI-compatible clients** use `/v1` for supported SDK-style Responses,
  chat, files, audio, image, and model-list calls.

Both paths authenticate with Pool API keys and route through the same Pool
policy, account health, model support, quota evidence, session continuity, and
metadata-only accounting. Codex Pooler is intentionally not a wildcard OpenAI
proxy; unsupported API areas fail predictably. For exact route details, use the
[Runtime Routes](https://docs.codex-pooler.com/reference/runtime-routes/)
reference and the
[OpenAI-compatible client guide](https://docs.codex-pooler.com/clients/openai-compatible/).

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
through PubSub invalidation; existing leases, in-flight requests, and open streams
keep the values they started with. The exception is an already-open Responses
websocket: after a locally applied runtime-firewall settings snapshot, it
re-evaluates the client IP captured during its handshake.

Secret Instance Settings stay write-only in the UI. The metrics bearer token is
stored only as a keyed HMAC digest, fingerprint, and key version. The SMTP
password is stored encrypted with key version metadata and is recovered only for
mail send or credential-test paths.

## Deployment

Choose the deployment path that matches how you want to operate Codex Pooler:

| Path | Use it for | Start here |
| --- | --- | --- |
| Docker Compose | A quick self-hosted install on a laptop, lab server, or small single node | [Docker Compose deployment guide](https://docs.codex-pooler.com/deployment/docker-compose/) |
| Kubernetes | Production installs, managed ingress, external Postgres, metrics, and separate runtime roles | [Helm deployment guide](https://docs.codex-pooler.com/deployment/helm/) |

The Kubernetes path uses the
[`icoretech/codex-pooler` chart](https://github.com/icoretech/helm/tree/main/charts/codex-pooler)
from the iCoreTech Helm repository. The chart runs one release image as separate
web, worker, scheduler, and migration roles. For a real install, pin the chart
`--version`; the chart defaults `image.tag` to the matching `appVersion`.

## Need more Codex?

👉 [codex-action](https://github.com/icoretech/codex-action) runs OpenAI Codex
CLI non-interactively in GitHub Actions workflows

👉 [codex-docker](https://github.com/icoretech/codex-docker) provides a
multi-arch OpenAI Codex CLI Docker image built from official upstream releases

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
