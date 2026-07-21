<h1 align="center">Codex Pooler</h1>

<p align="center">
  <strong>面向团队、Agent 和个人的完整自托管 Codex 网关。支持：</strong><br>
  <br>
  <a href="https://docs.codex-pooler.com/clients/opencode/" title="OpenCode"><img src=".github/assets/opencode-favicon.png" alt="OpenCode" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/codex-cli/" title="Codex CLI and Codex Desktop"><img src=".github/assets/codex-cli-favicon.png" alt="Codex CLI and Codex Desktop" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openclaw/" title="OpenClaw"><img src=".github/assets/openclaw-favicon.png" alt="OpenClaw" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/hermes/" title="Hermes Agent"><img src=".github/assets/hermes-favicon.png" alt="Hermes Agent" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/pi/" title="Pi"><img src=".github/assets/pi-favicon.png" alt="Pi" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/omp/" title="OMP"><img src=".github/assets/omp-favicon.png" alt="OMP" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/kilo/" title="Kilo"><img src=".github/assets/kilo-favicon.png" alt="Kilo" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/trae/" title="Trae"><img src=".github/assets/trae-favicon.png" alt="Trae" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/aider/" title="Aider"><img src=".github/assets/aider-favicon.png" alt="Aider" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/continue/" title="Continue"><img src=".github/assets/continue-favicon.png" alt="Continue" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/cline/" title="Cline"><img src=".github/assets/cline-favicon.png" alt="Cline" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/goose/" title="Goose"><img src=".github/assets/goose-favicon.png" alt="Goose" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/windmill/" title="Windmill AI"><img src=".github/assets/windmill-favicon.png" alt="Windmill AI" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openhands/" title="OpenHands"><img src=".github/assets/openhands-favicon.png" alt="OpenHands" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="OpenAI-compatible SDKs"><img src=".github/assets/python-favicon.png" alt="OpenAI-compatible SDKs" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="OpenAI-compatible SDKs"><img src=".github/assets/nodejs-favicon.png" alt="OpenAI-compatible SDKs" width="24" height="24"></a>
  <a href="https://docs.codex-pooler.com/clients/openai-compatible/" title="Vercel AI SDK"><img src=".github/assets/vercel-favicon.png" alt="Vercel AI SDK" width="24" height="24"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <strong>简体中文</strong>
</p>

<p align="center">
  <a href="#quick-start-with-docker-compose">快速开始</a>
  ·
  <a href="#harness-configuration">客户端配置</a>
  ·
  <a href="#configuration">配置</a>
  ·
  <a href="#deployment">部署</a>
</p>

<p align="center">
  <img src=".github/assets/codex-pooler-readme-banner.png" alt="Codex Pooler 网关概览">
</p>

<table>
  <tr>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen1.png">
        <img src=".github/assets/screen1.png" alt="Codex Pooler 上游账号就绪状态" width="100%">
      </a><br>
      <sub>上游账号</sub>
    </td>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen2.png">
        <img src=".github/assets/screen2.png" alt="Codex Pooler Pool 仪表盘" width="100%">
      </a><br>
      <sub>Pools</sub>
    </td>
    <td align="center" valign="top" width="33%">
      <a href=".github/assets/screen3.png">
        <img src=".github/assets/screen3.png" alt="Codex Pooler 请求日志" width="100%">
      </a><br>
      <sub>请求日志</sub>
    </td>
  </tr>
</table>

Codex Pooler 是一个自托管网关，用稳定的 Pool API 密钥运行兼容 Codex
的 Agent、工具和自动化。它可以只连接一个上游 Codex 账号，用于凭据隔离、
客户端规范化、仅保存元数据的操作，以及已保存 reset 的可见性；当你需要在多个
合格账号之间共享容量和路由时，可以继续添加更多账号。

客户端发送熟悉的 Codex 后端请求或 OpenAI 兼容请求；Codex Pooler
会根据模型支持、额度证据、限制、会话连续性、路由策略和健康状态选择合格
账号。Pool 密钥保持稳定，而它背后的上游分配、生命周期状态、reset 策略和
容量可以变化。

运营者可以在一个地方管理 Pools、账号、API 密钥、已保存的 resets、路由、
请求计费、审计日志和健康状态，同时不存储提示词、文件、音频、图片、
Bearer 令牌或原始 Codex 密钥。实例所有者保留全局管理界面，实例
管理员只处理分配给自己的 Pools。

## 亮点

- 🔑 **稳定的 Pool API 密钥：** 给客户端一个 Pool 凭据；无论这个 Pool 当前
  只有一个上游账号还是多个账号，都不需要分发原始 Codex 账号材料
- 🎯 **感知资格的路由：** 将每个请求路由到拥有兼容模型支持、可用额度证据、
  匹配健康状态、会话状态和 Pool 策略的账号
- 🧩 **Codex 后端兼容性：** 让兼容 Codex 的客户端指向 Codex Pooler，
  并通过分配的账号保持响应、压缩、用量、文件、音频、图片和后端 websocket
  流正常工作
- 🔌 **OpenAI 兼容 SDK 接口：** 让只支持 `/v1` 的应用和 Agent 工具
  通过同一个 Pool 边界使用 Codex 容量，翻译、路由受支持的请求以帮助控制
  API 支出
- 🔁 **感知会话的 websockets：** 保持可恢复 Codex 会话和 websocket 重连绑定到
  正确的上游账号，而不是通过 HTTP 兼容层翻译后端 websocket 流量
- ⚡ **Prompt-cache locality：** 使用临时 `prompt_cache_key` 优先为重复的无
  状态请求选择同一个合格上游账号，在本地不存储提示词或响应的前提下改善
  provider 侧缓存命中
- 🗜️ **按 Pool 的请求压缩：** 可选地在受支持请求路由上派发前压缩发往上游
  的 Responses 工具输出。该选项默认关闭，只作用于请求侧，并记录安全的
  聚合节省数据，不存储原始输出
- 🏦 **已保存 reset 管理：** 展示上游账号报告的 saved reset 容量，在可用时
  显示信息性过期时间，并允许运营者排队账号级恢复或选择受保护的自动兑换策略
- 🚨 **运营告警：** 为容量、上游健康、saved reset 事件和投递失败定义感知
  Pool 的规则，并通过管理界面的告警事件、邮件或 webhook 通知运营者，同时不暴露
  原始请求内容
- 🖥️ **运营者仪表盘：** 管理 Pool 范围内的账号、API 密钥、邀请、已保存 resets、
  用量、请求日志、审计日志和 MCP 访问，以及仅 owner 可见的任务、运营者和系统设置
- 🔭 **按密钥的 Observatory：** 为任意 Pool API 密钥开启只读 Observatory 访问，
  其持有者即可获得仅针对该密钥的实时自助仪表盘——用量、模型、延迟、缓存与花费，
  适合放在副屏上常驻，且看不到任何运营者控制或其他密钥
- 🛡️ **重视隐私的可观测性：** 存储请求、路由和审计元数据，而不存储提示词、
  文件内容、音频、图片、Bearer 令牌、cookies、原始 Codex 账号令牌或原始 API 密钥
- ⚙️ **无需改代码即可配置：** 从管理界面调整 Pool 策略、网关默认值、诊断设置、
  模型支持、限制和运营设置
- 🐳 **为自托管而构建：** 运行在 Elixir/Erlang 的容错运行时上，可用 Docker
  Compose 本地启动，也可用 Helm chart 部署 web、worker、scheduler 和 migration
  等独立角色，适合 Kubernetes 友好的多节点增长

<a id="harness-configuration"></a>

## 客户端配置

当客户端支持密钥展开时，把 Pool API 密钥放在环境变量中。`/mcp`
端点是可选的、仅运营者使用的元数据检查附加能力；Codex Pooler 运行时
客户端不需要它。如果桌面客户端会在自己的私有设置中保存远程 MCP 请求头，
请使用专用的运营者范围 MCP 令牌。对于本地实例，URL 是：

```text
Codex backend base URL:      http://localhost:4000/backend-api/codex
OpenAI SDK base URL:         http://localhost:4000/v1
Optional operator MCP URL:   http://localhost:4000/mcp
```

对于已部署实例，把 `http://localhost:4000` 替换为你的部署主机，例如
`https://codex-pooler.example.com`。

<details>
<summary><img src=".github/assets/opencode-favicon.png" alt="opencode logo" width="16" height="16"> OpenCode <code>~/.config/opencode/opencode.jsonc</code></summary>

![Codex Pooler OpenCode integration](.github/assets/codex-pooler-opencode.png)

OpenCode 通过 OpenAI 兼容的 `/v1` 接口与 Codex Pooler 通信。在这个设置中保留
provider id 为 `openai`，这样 OpenCode 会继续使用 OpenAI provider family 的
行为。provider 使用 Pool API 密钥，可选的远程 MCP 条目使用运营者拥有的 MCP
令牌。OpenCode 使用 Codex Pooler 不需要 MCP；MCP 只给运营者的 MCP host 提供
只读元数据工具。它的 websocket 支持是 `GET /v1/responses` 这个窄 Responses
websocket 路由，不是 OpenAI Realtime SDK 兼容性。

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "small_model": "openai/gpt-5.6-luna",
  "compaction": {
    "auto": true,
    "reserved": 20000
  },
  "provider": {
    "openai": {
      "npm": "@ai-sdk/openai",
      "name": "Codex Pooler",
      "options": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "{env:CODEX_POOLER_API_KEY}"
      },
      "models": {
        "gpt-5.6-luna": {
          "id": "gpt-5.6-luna",
          "name": "GPT-5.6 Luna",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "textVerbosity": "medium",
            "include": ["reasoning.encrypted_content"],
            // 可选：priority processing 的费用可能高于默认层级。
            // "serviceTier": "priority"
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 252560,
            "output": 64000
          }
        },
        "gpt-5.6-terra": {
          "id": "gpt-5.6-terra",
          "name": "GPT-5.6 Terra",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "textVerbosity": "medium",
            "include": ["reasoning.encrypted_content"],
            // 可选：priority processing 的费用可能高于默认层级。
            // "serviceTier": "priority"
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 252560,
            "output": 64000
          }
        },
        "gpt-5.6-sol": {
          "id": "gpt-5.6-sol",
          "name": "GPT-5.6 Sol",
          "family": "gpt",
          "attachment": true,
          "reasoning": true,
          "tool_call": true,
          "temperature": false,
          "options": {
            "reasoningEffort": "high",
            "reasoningSummary": "auto",
            "textVerbosity": "medium",
            "include": ["reasoning.encrypted_content"],
            // 可选：priority processing 的费用可能高于默认层级。
            // "serviceTier": "priority"
          },
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 252560,
            "output": 64000
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

只定义你分配到的 Pool 能服务的模型。对于已部署实例，把 `baseURL` 改为
`https://codex-pooler.example.com/v1`；如果保留可选的运营者 MCP 条目，把它的
`url` 改为 `https://codex-pooler.example.com/mcp`。

OpenCode 会把 `small_model` 用于自动生成会话标题等后台辅助任务。如果没有显式
覆盖，它可能会推断出 Codex Pool 不提供的 nano 模型。请把 `small_model` 指向实际
分配给你的 Pool 的轻量模型；加载 OMO 后，这个设置仍然有效。

请求级 OpenAI 选项应放在每个模型的 `options` 配置块中。provider 级 `options`
只保留 `baseURL` 和 `apiKey` 等连接设置。注释中的 `serviceTier` 展示了如何选择
priority processing。仅当 Pool 和上游都支持该能力，并且你愿意承担可能更高的费用时
才启用它；保持注释则使用默认层级。
无需添加 `store`：Codex Pooler 会在上游流式请求中设置 `store: false`。

OpenCode 会先从 `limit.input` 减去自己的压缩预留，再判断对话是否已满。
这些示例将 `limit.input` 设为 `252560`、压缩预留设为 `20000`，因此 OpenCode 会在
`232560` tokens 时开始压缩：这与 Codex 为 GPT-5.6 公布的自动压缩边界一致。
`limit.input` 是本地预压缩边界，不是输入和输出同时可用的总预算。OpenCode 的请求层
默认把输出限制在 32k；只有当你希望 OpenCode 请求完整 64k 上限时，才设置
`OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=64000`。

#### Oh My OpenAgent (OMO)

如果你使用 Oh My OpenAgent，请保留上面的原生 `openai` provider 配置，并在
`~/.config/opencode/oh-my-openagent.jsonc` 中添加 agent/category 覆盖。推荐的
三层路由如下：

| 主模型层级 | Agent 和 category | Fallback |
|---|---|---|
| `gpt-5.6-luna` | `librarian`、`explore`、`quick`、`unspecified-low` | 使用相同 reasoning variant 的 `gpt-5.6-terra` |
| `gpt-5.6-terra` | `sisyphus`、`multimodal-looker`、`atlas`、`sisyphus-junior`、`visual-engineering`、`unspecified-high`、`writing` | 使用相同 reasoning variant 的 `gpt-5.6-sol` |
| `gpt-5.6-sol` | `hephaestus`、`oracle`、`prometheus`、`metis`、`momus`、`ultrabrain`、`deep`、`artistry` | 使用相同 reasoning variant 的 `gpt-5.6-terra` |

显式设置 `fallback_models` 可以让 OMO 重试始终使用分配给 Pool 的模型 id，
而不是退回较旧的内置模型链。[OpenCode 客户端指南](https://docs.codex-pooler.com/clients/opencode/#oh-my-openagent-omo-routing)
提供了可直接复制的完整 OMO 配置和验证命令。

</details>

<details>
<summary><img src=".github/assets/codex-cli-favicon.png" alt="Codex logo" width="16" height="16"> Codex CLI and Codex Desktop <code>CODEX_HOME/config.toml</code></summary>

![Codex Pooler integration for Codex CLI and Codex Desktop](.github/assets/codex-pooler-codex.png)

Codex CLI 和 Codex Desktop 应使用后端兼容路由，而不是 `/v1` SDK 路由。它们共享
相同的 Codex 配置层和用户级 `CODEX_HOME/config.toml`，因此一个 Codex Pooler
provider 配置块可以同时服务终端和桌面/IDE 体验。保留 provider id 为
`codex-pooler-ws`，但 provider `name` 必须精确保持为 `OpenAI`。
在当前 Codex 源码中，`name` 不只是显示标签：精确匹配 `OpenAI` 会启用 OpenAI
family 行为，例如远程压缩、网页搜索/图片可用性，以及 Codex 后端请求体压缩。

把 provider 和认证设置放在用户级配置文件中。Codex 会先解析 `CODEX_HOME`。
如果未设置 `CODEX_HOME`，当前 Codex 源码在所有 OS 上都默认使用 `$HOME/.codex`，
所以用户配置文件是 `CODEX_HOME/config.toml`。

| OS | 默认配置文件 |
| --- | --- |
| macOS | `$HOME/.codex/config.toml` |
| Linux | `$HOME/.codex/config.toml` |
| Windows | `$HOME\.codex\config.toml`，通常是 `%USERPROFILE%\.codex\config.toml` |

Codex 的项目本地 `.codex/config.toml` 配置层受信任 gate 控制，不会覆盖机器本地
provider key，例如 `model_provider` 或 `model_providers`。

普通 Codex CLI 和 Codex Desktop 后端行为使用 websocket provider：

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

当你需要为客户端检查强制非 websocket 行为，或某个 Codex 运行时无法打开后端
websocket 流时，保留 HTTP/SSE provider：

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

对于已部署实例，把 `base_url` 改为
`https://codex-pooler.example.com/backend-api/codex`。

当 Codex Pooler 提供当前模型元数据时，Codex 不需要显式客户端侧上下文覆盖。
如果你必须在 Codex 刷新后端元数据前固定 `gpt-5.6-terra`，使用 Codex 自己的原始
窗口字段：`model_context_window = 272000` 和
`model_auto_compact_token_limit = 232560`。Codex 会为 turn 预算计算一个有效 95%
窗口，所以客户端可见预算是 258400 tokens，并且不会在普通 `/responses` turn 中发送
OpenAI SDK 风格的输出上限。

可选的仅运营者 MCP 元数据附加能力。普通 Codex 运行时使用时请省略：

```toml
[mcp_servers.codex_pooler]
url = "http://localhost:4000/mcp"
bearer_token_env_var = "CODEX_POOLER_MCP_KEY"
```

对于已部署实例，把可选 MCP `url` 改为
`https://codex-pooler.example.com/mcp`。

Codex 会按 `model_provider` 过滤可恢复对话。如果你已有使用内置 `openai`
provider 创建的 Codex CLI 或 Codex Desktop 会话，并希望它们出现在
`codex-pooler-ws` 下，需要同时重新标记 JSONL transcripts 和较新的 SQLite
状态数据库。先关闭 Codex；这些命令会原地编辑本地 Codex 状态。如果你把
HTTP provider 设为默认值，复制前只需要把目标值 `codex-pooler-ws` 替换为
`codex-pooler-http`。

#### macOS (zsh)

运行这两个 zsh one-liners：

```zsh
if [ -d "$HOME/.codex/sessions" ]; then find "$HOME/.codex/sessions" -type f -name '*.jsonl' -exec perl -0pi -e 's/("model_provider"\s*:\s*)"openai"/$1"codex-pooler-ws"/g' {} +; fi
```

```zsh
for db in "$HOME"/.codex/state_*.sqlite(N); do sqlite3 "$db" "UPDATE threads SET model_provider = 'codex-pooler-ws' WHERE model_provider = 'openai';"; done
```

#### Linux (bash)

运行这两个 bash one-liners：

```bash
if [ -d "$HOME/.codex/sessions" ]; then find "$HOME/.codex/sessions" -type f -name '*.jsonl' -exec perl -0pi -e 's/("model_provider"\s*:\s*)"openai"/$1"codex-pooler-ws"/g' {} +; fi
```

```bash
for db in "$HOME"/.codex/state_*.sqlite; do [ -e "$db" ] || continue; sqlite3 "$db" "UPDATE threads SET model_provider = 'codex-pooler-ws' WHERE model_provider = 'openai';"; done
```

#### Windows (PowerShell)

从 PowerShell 运行相同迁移。这里要求 `sqlite3` 已在 `PATH` 中。

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

OpenClaw 使用 `openai/*` 作为规范 OpenAI 路由。为了保留该模型名，同时把 agent
turn 发送到 Codex Pooler 的 OpenAI 兼容 `/v1` 接口，请把 OpenAI provider 指向
Codex Pooler，并使用当前 OpenClaw 运行时 id。

```json5
{
  agents: {
    defaults: {
      model: {
        primary: "openai/gpt-5.6-terra",
        list: [
          {
            id: "background",
            model: "openai/gpt-5.6-luna",
          },
        ],
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
            id: "gpt-5.6-luna",
            name: "GPT-5.6 Luna via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 272000,
            contextTokens: 258400,
            maxTokens: 128000,
          },
          {
            id: "gpt-5.6-terra",
            name: "GPT-5.6 Terra via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 272000,
            contextTokens: 258400,
            maxTokens: 128000,
          },
          {
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol via Codex Pooler",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 272000,
            contextTokens: 258400,
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

只定义你分配到的 Pool 能服务的模型。对于已部署实例，把 `baseUrl` 改为
`https://codex-pooler.example.com/v1`；如果保留可选的运营者 MCP 附加项，把它的
`url` 改为 `https://codex-pooler.example.com/mcp`。

OpenClaw 把 `contextWindow` 作为 provider/native 窗口，把 `contextTokens`
作为有效运行时预算。由 Codex 提供的 GPT-5.6 示例使用 Codex 原始 272k 窗口、258400
有效预算和 128k 输出预算；显式压缩预留会在长 completion 之前把本地历史控制在剩余
130400-token 提示词预算内。用 `gpt-5.6-luna` 跑后台路由，`gpt-5.6-terra` 作为主模型，
只在重推理会话中切到 `gpt-5.6-sol`。

如果你更希望把 Codex Pooler 与 OpenClaw 内置 OpenAI provider 行为分开，可以
改用自定义 provider id，例如 `codex-pooler/gpt-5.6-terra`。这会遵循 OpenClaw 的
通用自定义 provider 结构，但专门查找 `openai/gpt-*` model refs 的工具不会
把它识别为规范 OpenAI。

</details>

<details>
<summary><img src=".github/assets/hermes-favicon.png" alt="Hermes Agent logo" width="16" height="16"> Hermes Agent <code>~/.hermes/config.yaml</code> + <code>auth.json</code></summary>

![Codex Pooler Hermes Agent integration](.github/assets/codex-pooler-hermes.png)

Hermes 通过 `openai-api` provider 并显式强制 Responses 传输时效果最好。这是
推荐的 Codex Pooler 设置。把 Pool API 密钥放在 `~/.hermes/.env` 中，并把
provider 配置指向 Codex Pooler 的 `/v1` 接口。当你希望通过同一个 OpenAI 兼容
路径进行图片生成或编辑时，包含 Hermes 的 `image_gen` 配置块。`mcp_servers`
配置块是可选的、仅运营者使用的只读元数据工具附加能力；没有它 Codex Pooler
也能工作。

```bash
OPENAI_API_KEY=<pool-api-key>
OPENAI_BASE_URL=http://localhost:4000/v1
# Optional operator-only MCP metadata add-on:
CODEX_POOLER_MCP_KEY=<operator-mcp-token>
```

```yaml
model:
  default: gpt-5.6-terra
  provider: openai-api
  base_url: http://localhost:4000/v1
  api_mode: codex_responses
  context_length: 258400
  supports_vision: true

agent:
  image_input_mode: native

image_gen:
  provider: openai
  model: gpt-image-2-medium

auxiliary:
  compression:
    timeout: 900

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

当前 Codex Pooler release 也会在 `/v1/models` 上暴露 SDK 可读取的
`context_length`，该值来自有效 Codex `context_window` 元数据，所以 Hermes 的
自动探测可以解析 Pooler 窗口。这里的 GPT-5.6 示例使用 Codex 原始 272000 窗口和
258400 有效公布值。当 Hermes 无法先读取 `/v1/models` 时，把
`context_length: 258400` 保留在配置中作为显式覆盖。

Hermes 上下文压缩使用自己的辅助请求超时。保持
`auxiliary.compression.timeout: 900`，这样较大的保留上下文可以完成，而不会
反复触发旧的 120 秒压缩预算。这与可选 MCP server `timeout`
无关。

远程 HTTP MCP servers 需要 Hermes 的 `mcp` extra。如果
`hermes mcp test codex_pooler` 报告 `mcp.client.streamable_http is not available`，
请按照 [Hermes MCP Integration docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp)
在 Hermes 环境中安装 MCP 支持，然后重新运行测试。

检查一次性模型路径：

```bash
hermes -z 'Reply with exactly: hermes openai api ok' --ignore-rules
```

Hermes 也可以用它的 `openai-codex` provider 连接 Codex Pooler，但这条替代路径
不够直接，因为 Hermes 默认把 `openai-codex` 当作 OAuth provider；需要在任何
现有 device-code 凭据之前添加 Pool API 密钥凭据，并把该条目的 `base_url`
保持在 `/v1`。只有当你明确需要 Hermes 的 `openai-codex` 凭据池行为时才使用
这条路径；上面的 `openai-api` 配置是首选方案。这个变体把密钥存在 `auth.json`，
因为 Hermes 凭据池位于那里。

```bash
HERMES_CODEX_BASE_URL=http://localhost:4000/v1
# Optional operator-only MCP metadata add-on:
CODEX_POOLER_MCP_KEY=<operator-mcp-token>
```

```yaml
model:
  default: gpt-5.6-terra
  provider: openai-codex
  base_url: http://localhost:4000/v1
  context_length: 258400
  supports_vision: true

agent:
  image_input_mode: native

auxiliary:
  compression:
    timeout: 900

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

对于已部署实例，把模型 URL 改为 `https://codex-pooler.example.com/v1`；如果
保留可选的运营者 MCP 附加项，把 MCP `url` 改为
`https://codex-pooler.example.com/mcp`。

</details>

<details>
<summary><img src=".github/assets/pi-favicon.png" alt="Pi logo" width="16" height="16"> Pi <code>~/.pi/agent/models.json</code> and <code>settings.json</code></summary>

Pi 通过一个使用 Codex Pooler 窄 OpenAI 兼容 `/v1` Responses 接口的自定义
provider 工作得最好。把自定义 providers 和 models 放在
`~/.pi/agent/models.json`；把全局默认值放在 `~/.pi/agent/settings.json`；用
`.pi/settings.json` 做项目覆盖；把已保存的信任决策放在
`~/.pi/agent/trust.json`。在 Windows 上，在用户 profile 下使用同样的 home
相对路径，例如 `%USERPROFILE%\.pi\agent\models.json`。

从 npm 安装 Pi，以获得最新发布的 CLI：

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

然后在 `~/.pi/agent/models.json` 中添加 provider：

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
          "id": "gpt-5.6-luna",
          "name": "GPT-5.6 Luna via Codex Pooler",
          "reasoning": true,
          "thinkingLevelMap": {
            "xhigh": "xhigh"
          },
          "input": ["text", "image"],
          "contextWindow": 258400,
          "maxTokens": 128000
        },
        {
          "id": "gpt-5.6-terra",
          "name": "GPT-5.6 Terra via Codex Pooler",
          "reasoning": true,
          "thinkingLevelMap": {
            "xhigh": "xhigh"
          },
          "input": ["text", "image"],
          "contextWindow": 258400,
          "maxTokens": 128000
        },
        {
          "id": "gpt-5.6-sol",
          "name": "GPT-5.6 Sol via Codex Pooler",
          "reasoning": true,
          "thinkingLevelMap": {
            "xhigh": "xhigh"
          },
          "input": ["text", "image"],
          "contextWindow": 258400,
          "maxTokens": 128000
        }
      ]
    }
  }
}
```

`authHeader: true` 会让 Pi 以 `Authorization: Bearer ...` 发送 Pool API 密钥。
只定义你分配到的 Pool 能服务的模型 id。对于已部署实例，把 `baseUrl` 改为
`https://codex-pooler.example.com/v1`。

当前 Pi 源码仍然要求显式 `thinkingLevelMap` 条目，Pi 才会在模型选择器和页脚中
暴露 `xhigh`。没有它，Pi 会把 `xhigh` 视为自定义模型不支持的选项，并把
`--thinking xhigh` 或 `defaultThinkingLevel: "xhigh"` 降到 `high`。

Pi 接受自定义模型的 `contextWindow` 和 `maxTokens`；它没有 `contextTokens`
字段。为 GPT-5.6 自定义条目使用 258.4k 上下文窗口和 128k 输出预算，让
Pi 的本地上下文计算与 Codex Pooler 公布的模型 metadata 对齐。显式压缩预留会让
Pi 在提示词加长 completion 可能超过 258.4k 窗口之前进行压缩。

可选地在 `~/.pi/agent/settings.json` 中把 Codex Pooler 设为默认 Pi 模型：

```json
{
  "defaultProvider": "codex-pooler",
  "defaultModel": "gpt-5.6-terra",
  "defaultThinkingLevel": "xhigh",
  "enabledModels": [
    "codex-pooler/gpt-5.6-luna",
    "codex-pooler/gpt-5.6-terra",
    "codex-pooler/gpt-5.6-sol"
  ],
  "compaction": {
    "reserveTokens": 128000
  }
}
```

从一个仓库检查非交互路径：

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
pi --provider codex-pooler \
  --model gpt-5.6-terra \
  --no-session \
  --no-context-files \
  --tools bash \
  -p 'Reply with exactly: pi ok'
```

Pi 不带内置 MCP 支持。Codex Pooler 模型使用不需要 MCP；如果需要运营者元数据，
请用支持 MCP 的独立 host 和运营者 MCP 令牌。

</details>

<details>
<summary><img src=".github/assets/omp-favicon.png" alt="OMP logo" width="16" height="16"> OMP <code>~/.omp/agent/models.yml</code> and <code>config.yml</code></summary>

Oh My Pi (OMP) 是 Pi fork，但应作为独立的 Codex Pooler 客户端处理：它有自己
的 package、`omp` 二进制文件、YAML 配置和模型角色默认值。通过 Bun 安装
当前 CLI：

```bash
bun install -g @oh-my-pi/pi-coding-agent
```

然后在 `~/.omp/agent/models.yml` 中添加 provider：

```yaml
providers:
  codex-pooler:
    baseUrl: http://localhost:4000/v1
    api: openai-responses
    apiKey: CODEX_POOLER_API_KEY
    authHeader: true
    models:
      - id: gpt-5.6-terra
        name: GPT-5.6 Terra via Codex Pooler
        reasoning: true
        input:
          - text
          - image
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 258400
        maxTokens: 128000
      - id: gpt-5.6-luna
        name: GPT-5.6 Luna via Codex Pooler
        reasoning: true
        input:
          - text
          - image
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 258400
        maxTokens: 128000
      - id: gpt-5.6-sol
        name: GPT-5.6 Sol via Codex Pooler
        reasoning: true
        input:
          - text
          - image
        compat:
          streamIdleTimeoutMs: 300000
        contextWindow: 258400
        maxTokens: 128000
```

`apiKey: CODEX_POOLER_API_KEY` 会让 OMP 在运行时解析该环境变量。
`authHeader: true` 会让 OMP 以 `Authorization: Bearer ...` 发送 Pool API 密钥。
只定义你分配到的 Pool 能服务的模型 id。对于已部署实例，把 `baseUrl` 改为
`https://codex-pooler.example.com/v1`。

当前 OMP 源码会为设置了 `reasoning: true` 的自定义 `openai-responses` 模型推导
包含 `xhigh` 的 effort thinking 能力。只有在你要覆盖推导出的 effort 列表、wire
映射或每个模型的默认级别时，才需要显式 `thinking` 块。

OMP 在 `models.yml` 中接受 `contextWindow` 和 `maxTokens`；它不接受
`contextTokens`。这些示例让 GPT-5.6 分层模型都使用 258.4k 上下文窗口和 128k
输出预算：`gpt-5.6-luna` 负责轻量角色，`gpt-5.6-terra` 负责日常 agent 工作，
`gpt-5.6-sol` 留给 slow、plan 和 designer 升级路径。`compaction.reserveTokens:
128000` 要求 OMP 在提示词加长 completion 可能超过 258.4k 窗口之前压缩。

对于大量使用工具的长 OMP 会话，保持 mid-turn compaction 开启并把 handoff
材料持久化到磁盘。这些设置可以降低上下文溢出风险，但无法修复 OMP 客户端跳过
自身 mid-run compaction 检查的 bug。如果 OMP plan 在非常大的 turn 后看起来
重新开始工作，请在有新版 release 时升级 OMP，并在把它当成 Codex Pooler 路由
问题之前重启或恢复会话。

`compat.streamIdleTimeoutMs: 300000` 会防止长 OpenAI Responses 推理 turn
在 Codex Pooler 和上游账号仍在工作时被 OMP 的语义进度空闲 watchdog 中止。
已有 OMP 会话需要在该配置变更后重启或恢复。作为仅环境变量的覆盖，可在启动
`omp` 前设置 `PI_OPENAI_STREAM_IDLE_TIMEOUT_MS=300000`。

可选地在 `~/.omp/agent/config.yml` 中把 Codex Pooler 设为默认 OMP 模型角色：

```yaml
startup:
  setupWizard: false
defaultThinkingLevel: xhigh
enabledModels:
  - codex-pooler/gpt-5.6-luna
  - codex-pooler/gpt-5.6-terra
  - codex-pooler/gpt-5.6-sol
modelProviderOrder:
  - codex-pooler
modelRoles:
  default: codex-pooler/gpt-5.6-terra:xhigh
  smol: codex-pooler/gpt-5.6-luna:low
  tiny: codex-pooler/gpt-5.6-luna:minimal
  slow: codex-pooler/gpt-5.6-sol:xhigh
  plan: codex-pooler/gpt-5.6-sol:xhigh
  task: codex-pooler/gpt-5.6-terra:high
  vision: codex-pooler/gpt-5.6-terra:high
  advisor: codex-pooler/gpt-5.6-terra:medium
  commit: codex-pooler/gpt-5.6-luna:minimal
  designer: codex-pooler/gpt-5.6-sol:high
compaction:
  reserveTokens: 128000
  midTurnEnabled: true
  handoffSaveToDisk: true
```

从一个仓库检查非交互路径：

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
omp --model codex-pooler/gpt-5.6-terra:xhigh \
  --no-session \
  --tools bash \
  -p 'Reply with exactly: omp ok'
```

OMP 带有支持 MCP 的工具，但 Codex Pooler 模型使用不需要 MCP。如果使用 Codex
Pooler 可选的运营者 MCP 端点，请把 `/mcp` 运营者令牌与用于 `/v1` 的 Pool API
密钥分开。

</details>

<details>
<summary><img src=".github/assets/kilo-favicon.png" alt="Kilo logo" width="16" height="16"> Kilo <code>~/.config/kilo/kilo.jsonc</code></summary>

Kilo Code 应使用一个具名 OpenAI 兼容 provider，其 base URL 结束于 Codex Pooler
的 `/v1` 接口。Kilo 会自己追加 `/chat/completions`，所以不要在
`baseURL` 中写 `/v1/chat/completions`。从 npm 安装当前 CLI：

```bash
npm install -g @kilocode/cli@latest
```

然后在 `~/.config/kilo/kilo.jsonc` 中配置 provider：

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",
  "model": "codex-pooler/gpt-5.6-terra",
  "enabled_providers": ["codex-pooler"],
  "provider": {
    "codex-pooler": {
      "options": {
        "apiKey": "{env:CODEX_POOLER_API_KEY}",
        "baseURL": "http://localhost:4000/v1"
      },
      "models": {
        "gpt-5.6-luna": {
          "name": "GPT-5.6 Luna via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 194400,
            "output": 64000
          }
        },
        "gpt-5.6-terra": {
          "name": "GPT-5.6 Terra via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 194400,
            "output": 64000
          }
        },
        "gpt-5.6-sol": {
          "name": "GPT-5.6 Sol via Codex Pooler",
          "tool_call": true,
          "reasoning": true,
          "temperature": false,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          },
          "limit": {
            "context": 258400,
            "input": 194400,
            "output": 64000
          }
        }
      }
    }
  },
  "compaction": {
    "threshold_percent": 75
  }
}
```

Kilo 使用 OpenCode 风格的 `limit.{context,input,output}` 字段，但它会把推理
tokens 纳入溢出计算，并使用 `compaction.threshold_percent` 进行预检压缩。
`limit.input: 194400` 会在默认 20k 预留后留下 174.4k 可用输入 tokens；75% 阈值
要求 Kilo 更早压缩。对 GPT-5 OpenAI 兼容模型，Kilo 会抑制发出的 max-token
请求字段，以避免不兼容的 `max_tokens`，因此即使 `limit.output` 不会被转发，
它仍对本地上下文计算和 UI 很重要。

只定义你分配到的 Pool 能服务的模型 id。对于已部署实例，把 `baseURL` 改为
`https://codex-pooler.example.com/v1`。如果添加 Kilo 权限，请使用 Kilo 的对象
形式，例如 `"permission": {"bash": "allow"}`；不要设置 `"permission": "ask"`，
那不是有效配置结构。

从隔离目录检查无头工具路径：

```bash
mkdir -p /tmp/codex-pooler-kilo-check
cd /tmp/codex-pooler-kilo-check

export CODEX_POOLER_API_KEY=<pool-api-key>
kilo run \
  --model codex-pooler/gpt-5.6-terra \
  --pure \
  --auto \
  --format json \
  --dir "$PWD" \
  'Use your tools to create kilo-ok.txt containing exactly: kilo ok. After the file exists, reply with exactly: kilo ok'
```

`--pure` 会把外部插件排除在检查外。`--auto` 只用于可信、隔离的自动化场景，
其中 Kilo 可以不提示就运行已批准的工具。Codex Pooler 模型使用不需要 MCP。
如果需要运营者元数据，请用支持 MCP 的独立 host 和运营者 MCP 令牌。

</details>

<details>
<summary><img src=".github/assets/trae-favicon.png" alt="Trae logo" width="16" height="16"> Trae <code>Settings -> Models</code></summary>

Trae 和 Trae CN 在这个设置中属于同一客户端家族。通过配置为 OpenAI Chat
Completions 的自定义模型使用 Codex Pooler。这是 chat-completions 设置，不是
Codex 后端兼容，也不是完整 OpenAI API 等价实现。

Trae 需要先有 Trae 账号会话，Models 界面和 agent chat 界面才可用。
请先登录 Trae。

模型请求使用 Pool API 密钥。不要复用运营者 MCP 令牌、浏览器会话、上游账号令牌
或导入的账号材料。

```text
Custom Request URL:
https://codex-pooler.example.com/v1

Full URL:
off
```

Full URL 关闭时，Trae 会追加 `/chat/completions`。不要让自定义请求 URL 以
斜杠结尾。

在 Trae 中打开 Settings -> Models，添加自定义模型，并使用这些值：

| 字段 | 值 |
| --- | --- |
| API format | OpenAI Chat Completions |
| Custom Request URL | `https://codex-pooler.example.com/v1` |
| Full URL | Off |
| Model ID | `gpt-5.6-terra` 或分配到的 Pool 可服务的另一个模型 id |
| Multimodal | 当 Pool 模型支持图片输入时开启 |
| API key | Pool API 密钥 |
| Model Series | Default |
| Display Name | `GPT-5.6 Terra via Codex Pooler` |
| Context Window input | `184000` |
| Context Window output | `16000` |
| Tool Call Rounds | `200` |

在 Trae CN 中，同一流程显示为 Settings -> Models 和本地化 UI 中的自定义配置。
使用相同的 URL、模型 id、Pool API 密钥和上下文值。如果改为启用 Full URL，请使用
完整的 `https://codex-pooler.example.com/v1/chat/completions` 端点。

保存客户端模型前，用直接 chat-completions 请求检查 Pool API 密钥和模型：

```bash
curl -sS -X POST \
  -H "Authorization: Bearer $CODEX_POOLER_API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "model": "gpt-5.6-terra",
    "messages": [
      { "role": "user", "content": "Reply with exactly: trae ok" }
    ],
    "stream": false,
    "max_completion_tokens": 16
  }' \
  https://codex-pooler.example.com/v1/chat/completions
```

本地设置使用 `http://localhost:4000/v1`，并关闭 Full URL。只有当 Trae 的模型
添加/检查步骤成功，且真实 chat 能通过配置模型回答 `trae ok`，才应认为设置有效。

保存自定义模型后，打开 agent 模型选择器并关闭 Auto Mode。模型列表默认被 Auto
Mode 隐藏；在 Custom Models 下选择 Codex Pooler 模型。

不要把 Trae 指向 `/backend-api/codex`、`/v1/responses`、`/mcp` 或 Codex Pooler
管理 URL。Codex Pooler 模型使用不需要 MCP。

</details>

<details>
<summary><img src=".github/assets/aider-favicon.png" alt="Aider logo" width="16" height="16"> Aider <code>~/.aider.conf.yml</code></summary>

Aider 使用带 `openai/` 模型前缀的 OpenAI 兼容路由。把稳定路由设置放在
`.aider.conf.yml`；Aider 会从你的 home directory、git repo root、
当前目录依次加载该文件，后加载的文件优先。

```yaml
# ~/.aider.conf.yml or <repo>/.aider.conf.yml
model: openai/gpt-5.6-terra
openai-api-base: http://localhost:4000/v1
```

`.aider.conf.yml` 只保存 Aider 路由设置，不保存上下文或输出限制。如果当前
Aider 版本不识别 `gpt-5.6-terra`，请用 Aider 独立的模型 metadata JSON 文件定义
模型行为和限制，不要把不支持的上下文字段加到主配置中。

```jsonc
// .aider.model.metadata.json
{
  "openai/gpt-5.6-luna": {
    "max_tokens": 258400,
    "max_input_tokens": 130400,
    "max_output_tokens": 128000,
    "litellm_provider": "openai",
    "mode": "chat",
    "supports_function_calling": true,
    "supports_vision": true,
    "supports_reasoning": true
  },
  "openai/gpt-5.6-terra": {
    "max_tokens": 258400,
    "max_input_tokens": 130400,
    "max_output_tokens": 128000,
    "litellm_provider": "openai",
    "mode": "chat",
    "supports_function_calling": true,
    "supports_vision": true,
    "supports_reasoning": true
  },
  "openai/gpt-5.6-sol": {
    "max_tokens": 258400,
    "max_input_tokens": 130400,
    "max_output_tokens": 128000,
    "litellm_provider": "openai",
    "mode": "chat",
    "supports_function_calling": true,
    "supports_vision": true,
    "supports_reasoning": true
  }
}
```

不要把 Pool API 密钥放进 YAML 文件。请在 shell 中 export，或放进 Aider 可加载的
已被 git 忽略的 `.env` 文件：

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
```

从仓库中用真实文件编辑检查 Aider。配置文件存在时，命令应只需要一次性提示词：

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

只有当文件确实存在并且内容符合预期时，这个检查才有意义；单纯文本回复不能证明
Aider 能通过配置好的模型路径进行编辑。

对于已部署实例，把 `openai-api-base` 改为
`https://codex-pooler.example.com/v1`。

</details>

<details>
<summary><img src=".github/assets/continue-favicon.png" alt="Continue logo" width="16" height="16"> Continue <code>~/.continue/config.yaml</code></summary>

Continue 可以通过设置 `provider: openai`、把 `apiBase` 指向 `/v1`、并把 Pool
API 密钥作为 Continue secret，来把 Codex Pooler 用作 OpenAI 兼容 provider。
对于 `gpt-5*` 模型，Continue 默认使用 Responses API。

本地 Continue 配置放在 macOS/Linux 的 `~/.continue/config.yaml`，或 Windows
的 `%USERPROFILE%\.continue\config.yaml`。在 IDE extension 中，打开 Continue
chat 侧边栏，使用 chat 输入框上方的配置选择器，然后点击 **Local Config**
旁边的齿轮图标。Continue CLI 会先解析 `--config`，再解析保存的上次使用配置，
最后在未登录时使用默认 assistant 或 `~/.continue/config.yaml`。

```yaml
name: Codex Pooler
version: 1.0.0
schema: v1

models:
  - name: GPT-5.6 Terra via Codex Pooler
    provider: openai
    model: gpt-5.6-terra
    apiBase: http://localhost:4000/v1
    apiKey: "${{ secrets.CODEX_POOLER_API_KEY }}"
    contextLength: 258400
    defaultCompletionOptions:
      maxTokens: 128000
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

对于已部署实例，把 `apiBase` 改为 `https://codex-pooler.example.com/v1`；如果
保留可选的运营者 MCP 附加项，把 MCP `url` 改为
`https://codex-pooler.example.com/mcp`。

Continue 使用 `contextLength` 做请求裁剪，并使用
`defaultCompletionOptions.maxTokens` 作为 completion 预算。它会裁剪，而不是在本地
总结/压缩，因此应把上下文长度保持为 Codex Pooler 的 258.4k `gpt-5.6-terra` 窗口，而不是使用过期或通用 provider 元数据。

保存配置后检查无头 CLI 路径：

```bash
export CODEX_POOLER_API_KEY=<pool-api-key>
npx -y @continuedev/cli@latest -p \
  --config ~/.continue/config.yaml \
  --silent \
  'Reply with exactly: continue ok'
```

Pool API 密钥用于认证模型请求。MCP 令牌只认证运营者元数据端点。

</details>

<details>
<summary><img src=".github/assets/cline-favicon.png" alt="Cline logo" width="16" height="16"> Cline <code>~/.cline</code> + <code>~/.cline/mcp.json</code></summary>

Cline CLI 接受 `openai` 作为 OpenAI 兼容 provider 的简写，并把它保存为
`openai-compatible`。用 Pool API 密钥、Codex Pooler `/v1` base URL，以及你分配到
的 Pool 能服务的模型 id 配置它。

```bash
cline auth \
  --provider openai \
  --apikey "$CODEX_POOLER_API_KEY" \
  --baseurl http://localhost:4000/v1 \
  --modelid gpt-5.6-terra
```

Cline 的模型元数据名是 `contextWindow`、`maxInputTokens` 和 `maxTokens`。如果你
在 Cline 设置中手动添加 Codex Pooler 模型条目，请使用
`contextWindow: 258400`、`maxInputTokens: 130400` 和 `maxTokens: 128000`，这样
Cline 的压缩触发器会在 258.4k Pooler 窗口内为长 completion 留空间。

保存认证后检查无头 CLI 路径：

```bash
cline --provider openai \
  --model gpt-5.6-terra \
  --json \
  --auto-approve false \
  'Reply with exactly: cline ok'
```

对于 Cline CLI 中可选的运营者 MCP，把远程 server 加到
`~/.cline/mcp.json`。Codex Pooler 模型使用不需要它。VS Code extension 会从
Cline MCP Servers 面板打开自己的 MCP 设置 JSON；在那里使用同样的 `mcpServers`
结构。

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

对于已部署实例，把 `--baseurl` 改为 `https://codex-pooler.example.com/v1`；如果
保留可选的运营者 MCP 附加项，把 MCP `url` 改为
`https://codex-pooler.example.com/mcp`。

`/v1` 模型请求使用 Pool API 密钥，`/mcp` 使用运营者 MCP 令牌。不要把 Pool API
密钥复用给 MCP。

</details>

<details>
<summary><img src=".github/assets/goose-favicon.png" alt="Goose logo" width="16" height="16"> Goose <code>~/.config/goose/config.yaml</code></summary>

为 Codex Pooler 的 OpenAI 兼容 chat-completions 路径配置 Goose 的 OpenAI
provider。把 Pool API 密钥放在 `OPENAI_API_KEY` 或 Goose 的密钥存储中。

在 macOS/Linux 上，把持久 Goose provider 和扩展设置放在
`~/.config/goose/config.yaml`；在 Windows 上放在
`%APPDATA%\Block\goose\config\config.yaml`。Goose 还会在该配置区域保留相关
文件：`permission.yaml` 用于工具权限级别，`secrets.yaml` 用于基于文件的密钥
存储，`permissions/tool_permissions.json` 用于运行时权限决策，`prompts/`
用于提示词模板。环境变量优先级高于
配置文件，因此 `OPENAI_API_KEY` 可以留在 YAML 外部。

```yaml
GOOSE_PROVIDER: openai
GOOSE_MODEL: gpt-5.6-terra
OPENAI_HOST: http://localhost:4000
OPENAI_BASE_PATH: v1/chat/completions
GOOSE_CONTEXT_LIMIT: 258400
GOOSE_MAX_TOKENS: 128000
GOOSE_AUTO_COMPACT_THRESHOLD: 0.63
```

Goose 会把 `GOOSE_CONTEXT_LIMIT` 和 `GOOSE_MAX_TOKENS` 读入模型配置。它的自动
压缩阈值是上下文限制的比例，不是输出预留，因此 `0.63` 会在提示词历史挤占
Codex Pooler 258.4k `gpt-5.6-terra` 窗口中的 128k completion 空间之前压缩。

开启工具访问后检查无头 CLI 路径：

```bash
export OPENAI_API_KEY="$CODEX_POOLER_API_KEY"
goose run \
  --no-session \
  --provider openai \
  --model gpt-5.6-terra \
  --with-builtin developer \
  --text 'Use your developer tool to create goose-ok.txt containing exactly: goose ok. Then reply with exactly: goose ok'
```

对于可选的运营者 MCP 元数据访问，添加远程 Streamable HTTP 扩展。Codex Pooler
模型使用不需要它。Goose 会把远程扩展请求头存到自己的配置中，所以请使用专用
MCP 令牌。

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

对于已部署实例，把 `OPENAI_HOST` 改为 `https://codex-pooler.example.com`；如果
保留可选的运营者 MCP 附加项，把扩展 `uri` 改为
`https://codex-pooler.example.com/mcp`。

OpenAI 兼容模型请求使用 Pool API 密钥，`/mcp` 使用运营者 MCP 令牌。不要把 Pool
API 密钥复用给 MCP。

</details>

<details>
<summary><img src=".github/assets/windmill-favicon.png" alt="Windmill logo" width="16" height="16"> Windmill AI <code>customai</code> workspace provider</summary>

Windmill AI 可以通过 Windmill 的 `customai` provider 使用 Codex Pooler。把
resource 指向 Codex Pooler 的 OpenAI 兼容 `/v1` 接口，把 Pool API 密钥保存为
Windmill 密钥变量，并让工作区 AI 设置使用该 resource 进行 chat 和元数据生成。

为 Windmill 使用专用 Pool API 密钥：

```bash
wmill variable add '<pool-api-key>' \
  u/<owner>/codex_pooler_windmill_codegen \
  --workspace <workspace>
```

创建匹配的 `customai` resource：

```yaml
description: Codex Pooler API credentials for Windmill AI
value:
  api_key: '$var:u/<owner>/codex_pooler_windmill_codegen'
  base_url: http://localhost:4000/v1
  headers: {}
resource_type: customai
```

然后把 Windmill 工作区 AI 配置设为使用该 resource：

```yaml
providers:
  customai:
    resource_path: u/<owner>/codex_pooler_windmill_codegen
    models:
      - gpt-5.6-luna
      - gpt-5.6-terra
      - gpt-5.6-sol
default_model:
  provider: customai
  model: gpt-5.6-terra
metadata_model:
  provider: customai
  model: gpt-5.6-terra
```

Windmill 的 agent 请求字段是 `max_completion_tokens`；provider adapter 会按
需要把它映射到 OpenAI Responses `max_output_tokens` 或 chat
`max_completion_tokens`。不要对 GPT-5/O-series Windmill AI 请求使用
`max_tokens`。

对于已部署 Codex Pooler 实例，把 `base_url` 改为
`https://codex-pooler.example.com/v1`。如果 Windmill 是自托管的，并且该 URL 从
Windmill app pod 或 server 解析为私有或内部地址，请在 Windmill app/server
环境中设置 `ALLOW_PRIVATE_AI_BASE_URLS=true`。

除非你已经单独配置了支持 fill-in-the-middle 自动补全的 provider，否则让 Windmill
的代码补全模型保持未设置。Codex Pooler 的 `customai` 设置用于 Windmill chat、
script/flow/app 生成、修复、摘要、元数据生成，以及使用 chat completion 风格请求
的表单填充功能。

</details>

<details>
<summary><img src=".github/assets/openhands-favicon.png" alt="OpenHands logo" width="16" height="16"> OpenHands <code>~/.openhands/</code></summary>

OpenHands CLI 可以通过窄 OpenAI 兼容 `/v1` 接口使用 Codex Pooler。把 Pool API
密钥放在环境变量中，把 OpenHands base URL 设为 `/v1`，并使用 OpenHands 期望的
OpenAI 模型前缀。下面命令使用 `--override-with-envs`，因此
不会把 Pool 设置持久化到 OpenHands 本地状态。

OpenHands CLI 把本地状态存在 `~/.openhands/`，首次运行时创建。当前 OpenHands CLI
文档列出 `agent_settings.json` 用于 LLM 配置和 agent 设置，`cli_config.json`
用于 CLI 偏好，`mcp.json` 用于 MCP server 配置，`conversations/` 用于对话历史。
在 Windows 上，OpenHands CLI 按上游安装文档通过 WSL 运行，因此这些路径位于 WSL
用户的 home directory。

```bash
export LLM_API_KEY=<pool-api-key>
export LLM_BASE_URL=http://localhost:4000/v1
export LLM_MODEL=openai/gpt-5.6-terra

uvx --python 3.12 --from openhands openhands \
  --headless \
  --override-with-envs \
  -t 'Check the repository and summarize what you can do.'
```

对于已部署实例，把 `LLM_BASE_URL` 改为 `https://codex-pooler.example.com/v1`。
模型名应保持为 `openai/gpt-5.6-terra`，这样 OpenHands 会选择它的 OpenAI 兼容
provider 路径，而 Codex Pooler 会通过分配到的 Pool 路由请求。

</details>

<details>
<summary><img src=".github/assets/python-favicon.png" alt="Python logo" width="16" height="16"> OpenAI Python SDK</summary>

OpenAI Python SDK 客户端可以通过把 `base_url` 设为 Codex Pooler `/v1` URL，并
使用 Pool API 密钥作为 API key，来使用 OpenAI 兼容 `/v1` 接口。

```python
import os

from openai import OpenAI

client = OpenAI(
    api_key=os.environ["CODEX_POOLER_API_KEY"],
    base_url="http://localhost:4000/v1",
)

response = client.responses.create(
    model="gpt-5.6-terra",
    input="Write a one-sentence status update.",
)

print(response.output_text)
```

对于已部署实例，把 `base_url` 改为 `https://codex-pooler.example.com/v1`。

</details>

<details>
<summary><img src=".github/assets/nodejs-favicon.png" alt="Node.js logo" width="16" height="16"> OpenAI Node SDK</summary>

OpenAI Node SDK 客户端使用同一个 OpenAI 兼容 `/v1` 接口。用 Codex Pooler `/v1`
URL 配置 `baseURL`，并把 Pool API 密钥作为 API key 传入。

```js
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const response = await client.responses.create({
  model: "gpt-5.6-terra",
  input: "Write a one-sentence status update.",
});

console.log(response.output_text);
```

对于已部署实例，把 `baseURL` 改为 `https://codex-pooler.example.com/v1`。

</details>

<details>
<summary><img src=".github/assets/vercel-favicon.png" alt="Vercel logo" width="16" height="16"> Vercel AI SDK</summary>

Vercel AI SDK 可以通过使用 `createOpenAI` 创建自定义 provider，让它的 OpenAI
provider 指向 Codex Pooler。该 provider 使用 Pool API 密钥调用 OpenAI 兼容
`/v1` 接口。

```ts
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";

const pooler = createOpenAI({
  apiKey: process.env.CODEX_POOLER_API_KEY,
  baseURL: "http://localhost:4000/v1",
});

const { text } = await generateText({
  model: pooler.responses("gpt-5.6-terra"),
  prompt: "Write a one-sentence status update.",
});

console.log(text);
```

对于已部署实例，把 `baseURL` 改为 `https://codex-pooler.example.com/v1`。

`GET /v1/models` 在可用时会提供 `context_length`；对外公布的客户端上下文设置应以
这个有效值为准。官方 OpenAI SDK 请求 API 和 Vercel AI SDK 生成 API
不暴露 Codex 模型 catalog 的上下文控制。只有当应用需要时才使用它们的输出预算
字段：OpenAI Responses 中的 `max_output_tokens`，Chat Completions 中的
`max_completion_tokens`，以及 Vercel AI SDK 层的
`maxOutputTokens`。Codex Pooler 的 public `/v1/responses` 当前拒绝
`context_management`，public `/v1/responses/compact` 虽然有路由但不支持，因此不要
把 SDK 侧压缩记录为 Codex Pooler 功能。

</details>

<details>
<summary><img src=".github/assets/claude-code-favicon.png" alt="Claude Code logo" width="16" height="16"> Claude Code</summary>

![Claude Code on Codex Pooler](.github/assets/codex-pooler-claude.png)

</details>

<a id="quick-start-with-docker-compose"></a>

## 使用 Docker Compose 快速开始

这会使用本地 Postgres 数据库运行已发布的 release image。这是在笔记本或小型
服务器上试用 Codex Pooler 的最快方式。
正常使用时，请运行 [GitHub Releases](https://github.com/icoretech/codex-pooler/releases) 中带版本号的已标记稳定 release。`latest` image tag 会跟随最新发布的 release，但使用版本 tag 可保持安装可复现；仅在[本地开发](#本地开发)时从源码运行。

前置条件：

- Docker with Compose
- Git，如果你要 clone 仓库
- `openssl`

启动 Codex Pooler：

```bash
git clone https://github.com/icoretech/codex-pooler.git
cd codex-pooler

# 运行最新的已标记稳定 release。请在
# https://github.com/icoretech/codex-pooler/releases 查找版本并替换此处。
export CODEX_POOLER_IMAGE_TAG=<release-tag>

scripts/self-host/generate-env.sh
docker compose pull
docker compose up -d
```

首次运行会拉取应用和 Postgres 镜像，等待 Postgres 健康检查通过，运行迁移容器，
然后启动 web app。

打开 `http://localhost:4000`。首次访问时，在 `/bootstrap` 创建 owner 账号，
然后登录并从 `/admin/pools` 开始。

在打开浏览器前验证首次运行重定向：

```bash
curl -sS -D - -o /dev/null http://localhost:4000/ | grep -i '^location: /bootstrap'
curl -fsS http://localhost:4000/bootstrap/status
```

在全新数据库上，status 端点应返回
`{"status":"ok","bootstrap":"pending"}`。

常用命令：

```bash
docker compose ps
docker compose logs -f app
docker compose down
```

升级已有 Compose 安装时，将 `.env` 中的 `CODEX_POOLER_IMAGE_TAG` 设为目标已标记稳定
release，然后运行：

```bash
docker compose pull
docker compose up -d
```

Compose stack 有一个一次性的 `migrate` service。它会等待 Postgres，运行 release
迁移，导入打包的价格快照，并在 web app 启动前退出。普通 app 启动本身不会迁移
数据库。如果失败的迁移需要在修复配置或数据库访问后重新运行：

```bash
docker compose up -d db
docker compose run --rm migrate
docker compose up -d app
```

默认 Compose stack 使用 `http://localhost:4000`，即使 Phoenix 启动 banner
打印了类似 `https://localhost` 的端点 URL；Compose 端口映射才是本地要打开的
URL。release image 包含用于运营者时区显示的 OS 时区数据库。

如果也要删除本地数据库：

```bash
docker compose down -v
```

## 首次运行时设置

bootstrap 后：

1. 在 `/admin/pools` 创建 Pool
2. 在 `/admin/upstreams` 连接、导入或邀请一个或多个 Codex 账号
3. 在 `/admin/api-keys` 创建 Pool API 密钥
4. 把 Codex 或 SDK 客户端指向其中一个运行时 base URL：

一个上游账号足够让设置工作。额外上游账号会在不改变客户端凭据的情况下，把同一个
Pool 扩展为共享容量。

当浏览器授权可行时，新建由运营者管理的上游账号优先在 `/admin/upstreams` 中使用
`OAuth`。管理对话框会连接账号，通过加密的上游密钥存储保存产生的凭据材料，并在
完成后只保留元数据。只有当已有 Codex `auth.json` 是正确凭据来源时才使用
`Import`。

导入后，把导入的 Codex `auth.json` 视为由 Codex Pooler 拥有。不要继续在另一个
Codex 安装、机器或自动化中使用同一个 `auth.json`，除非你接受 provider
refresh-token 轮换可能使其中一份失效，并把账号移到
`reauth_required`。

托管邀请 onboarding 和 OAuth device-code fallback 使用 OpenAI 的 Codex
device-code authorization。该设置只用于托管邀请和 OAuth device-code fallback；
浏览器 OAuth 连接不依赖它。对于个人 ChatGPT 账号，打开
`chatgpt.com`，进入 Settings > Security，并启用
`Enable device code authorization for Codex`。对于工作区管理的账号，请让工作区
管理员在工作区权限中为 Codex 启用 device-code 登录。
OpenAI 的 [Codex authentication docs](https://developers.openai.com/codex/auth)
描述了 device-code 登录。当 device-code authorization 关闭时，邀请或 fallback
流程可能在 OpenAI approval 步骤失败。

```text
Codex backend base URL: http://localhost:4000/backend-api/codex
OpenAI SDK base URL:    http://localhost:4000/v1
```

使用生成的 Pool API 密钥作为 bearer token。该密钥代表 Pool，而不是单个 Codex
账号，因此 Codex Pooler 可以为每个请求选择最合适的合格账号。原始 API 密钥只在
创建或轮换时显示一次。

## 运营者角色

第一个 bootstrap 账号是 `instance_owner`。Owners 拥有实例级管理权限：创建 Pools、
把运营者分配到 Pools、管理运营者、检查全局任务，并修改系统设置。

额外运营者可以是 owners 或 `instance_admin`s。Instance admins 是 Pool 范围内的
角色：他们只能处理分配给自己的 active Pools 以及从这些 Pools 派生的元数据。如果
没有分配 Pools，管理界面会显示空的 Pool 范围状态，而不是暴露全局数据。归档或
删除一个 Pool 会移除未来的 instance-admin 可见性；archived 或 deleted Pools 的
历史请求和审计行仍只对 owner 可见。

## 运行时兼容性

接入具体工具时请使用客户端指南。概览上，客户端选择两种公开形态之一：

- **Codex 后端客户端** 使用 `/backend-api/codex` 以获得 Codex-native 行为，
  例如会话、压缩、文件、音频、图片和后端 websockets。原始 Responses 流保留
  上游 `response.done` 和旧式无类型成功 payload
- **OpenAI 兼容客户端** 使用 `/v1` 访问受支持的 SDK 风格 Responses、chat、文件、
  音频、图片和模型列表调用。公开 Responses 流会把这些成功终止 payload
  规范化为 `response.completed`

两个路径都使用 Pool API 密钥认证，并通过同一套 Pool 策略、账号健康状态、模型
支持、额度证据、会话连续性和仅元数据计费进行路由。Codex Pooler 有意不做通配的
OpenAI 代理；不支持的 API 区域会以可预测方式失败。精确路由细节请看
[Runtime Routes](https://docs.codex-pooler.com/reference/runtime-routes/)
参考和
[OpenAI-compatible client guide](https://docs.codex-pooler.com/clients/openai-compatible/)。

## 运营者 MCP 服务

Codex Pooler 包含一个可选的仅元数据 MCP 端点 `/mcp`，供受信任运营者让 MCP host
检查 Pools、上游账号、Pool API 密钥元数据、运营者、邀请、请求日志、审计日志和
MCP 服务状态。这个运营者附加能力不是 Codex Pooler 运行时客户端所必需的。该服务
是只读的，没有变更工具。它使用与管理界面相同的 owner vs assigned-Pool 可见性
模型，但已连接的 MCP hosts 可以读取该运营者可见的元数据，因此只连接你信任拥有该
视图的 hosts。

MCP 访问使用运营者拥有的 bearer MCP 令牌，不使用 Pool API 密钥、浏览器会话、
cookies、query tokens、邀请令牌、上游令牌或自定义请求头。运营者从
`/admin/settings?tab=account` 管理自己的 MCP account gate 和令牌；实例级服务
gate 从 `/admin/system` 管理。两个 gates 都必须启用后 token 才能工作。原始 MCP
令牌只在创建时显示一次，并且有意不存储 per-key 使用跟踪、计数器、last IP 和
user-agent 历史。

`/mcp` 路由继承运行时入口 IP allowlist 和 trusted-proxy 设置。如果 allowlist
为空，防火墙关闭；如果已配置，解析出的 client IP 必须先匹配，之后才会进行 MCP
认证或工具派发。

<a id="configuration"></a>

## 配置

`scripts/self-host/generate-env.sh` 会写入一个本地 `.env`，包含生成的密钥和本地
默认值。保持该文件私密，不要在公开安装之间复用生成值。

环境变量只用于 release 在读取数据库前所需的值：

- `CODEX_POOLER_IMAGE` 和 `CODEX_POOLER_IMAGE_TAG`，要运行的 release image
- `CODEX_POOLER_HTTP_PORT`，本地主机端口，默认 `4000`
- `DATABASE_URL`，app 使用的 Postgres 连接
- `SECRET_KEY_BASE`，Phoenix 签名和加密密钥
- `PHX_HOST`、`PORT` 和 `PHX_SERVER`，HTTP 端点启动设置
- `OBAN_MODE` 和 `OBAN_JOBS_QUEUE_LIMIT`，release 角色和队列拓扑
- `DNS_CLUSTER_QUERY`，以及 clustering 开启时的 release distribution 变量
- `CODEX_POOLER_TOTP_ENCRYPTION_KEY` 和 `CODEX_POOLER_TOTP_KEY_VERSION`，TOTP
  加密根和版本
- `CODEX_POOLER_UPSTREAM_SECRET_KEY` 和
  `CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION`，上游密钥加密根和版本；key 必须是
  32 raw bytes 或 base64-encoded 32 bytes

文件限制、入口信任、网关诊断、路由类别准入、熔断阈值、指标认证、运营者邮箱、
模型元数据、上游超时、OpenAI 价格 catalog URL 和 SMTP 投递等运营控制项位于
`/admin/system` 下由数据库管理的 Instance Settings 中。实时设置会通过设置缓存
应用到新的运行时工作。保存后，已缓存设置通过 PubSub invalidation 重新加载；已有
leases、进行中的请求和已经打开的 streams 会继续使用它们启动时的值。

Secret Instance Settings 在 UI 中保持 write-only。metrics bearer token 只以 keyed
HMAC digest、fingerprint 和 key version 存储。SMTP password 使用 key version
metadata 加密存储，并且只在邮件发送或凭据测试路径中恢复。

<a id="deployment"></a>

## 部署

选择与你希望如何运行 Codex Pooler 匹配的部署路径：

| 路径 | 适用场景 | 从这里开始 |
| --- | --- | --- |
| Docker Compose | 笔记本、实验服务器或小型单节点上的快速自托管安装 | [Docker Compose deployment guide](https://docs.codex-pooler.com/deployment/docker-compose/) |
| Kubernetes | 生产安装、托管 ingress、外部 Postgres、metrics，以及独立 runtime roles | [Helm deployment guide](https://docs.codex-pooler.com/deployment/helm/) |

Kubernetes 路径使用 iCoreTech Helm repository 中的
[`icoretech/codex-pooler` chart](https://github.com/icoretech/helm/tree/main/charts/codex-pooler)。
该 chart 使用一个 release image 运行独立 web、worker、scheduler 和 migration
roles。真实安装时请固定 chart `--version`；chart 默认把 `image.tag` 设为匹配的
`appVersion`。

## 需要更多 Codex?

👉 [codex-action](https://github.com/icoretech/codex-action) 在 GitHub Actions
workflows 中非交互式运行 OpenAI Codex CLI

👉 [codex-docker](https://github.com/icoretech/codex-docker) 提供从官方上游
releases 构建的 multi-arch OpenAI Codex CLI Docker image

## 本地开发

本地开发在 host 上运行 Phoenix，并通过 dev compose file 运行 Postgres：

```bash
make dev
```

`make dev` 会启动 Postgres、准备数据库、导入 vendored OpenAI pricing feed，并在
`http://localhost:4000` 启动 Phoenix server。日志写入本地 development server log。

开发 seeds 是可选的，并且只通过显式 seed task 运行。要创建一个紧凑、幂等的
运营者 baseline，包含一个 owner 加四个示例运营者，运行：

```bash
mix dev.seed compact
```

所有 seeded 运营者都使用 `dev-password-123`。

要重新创建一个更完整的假数据集，用于在没有真实账号或真实请求数据时测试管理界面
状态，运行：

```bash
mix dev.seed full
```

full seed 是幂等的，并且只替换由 development seed namespace 拥有的确定性
`dev-*` 假数据行。它包含 active/disabled pools、active/paused/revoked API 密钥、
处于 active/refresh/reauth/paused 状态的上游账号、quota windows、请求日志、邀请、
审计事件和 job rows。

常用检查：

```bash
mix precommit
mix quality
docker compose -f docker-compose.dev.yml config
docker build .
```

当 Kubernetes 部署行为或 values 变更时，Helm chart validation 位于 iCoreTech
Helm repository 中的 published chart 旁边。

`mix test` 和 `mix precommit` 使用由已配置测试数据库派生 key 的 PostgreSQL
advisory lock 串行化依赖数据库的测试运行，因此并发本地运行会等待，而不会让共享
sandbox 数据库死锁。

## Star 历史

<a href="https://www.star-history.com/?repos=icoretech%2Fcodex-pooler&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=icoretech/codex-pooler&type=date&legend=top-left" />
 </picture>
</a>
