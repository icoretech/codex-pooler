<h1 align="center">Codex Pooler</h1>

<p align="center">
  <a href="README.md">English</a>
  ·
  <strong>简体中文</strong>
</p>

Codex Pooler 是一个自托管的池化 AI 网关。客户端只看到一个虚拟模型：
`gemma3`。真实目标、推理策略、账号选择、重试、会话连续性、配额和计费都由
服务器管理，不会通过客户端协议暴露 provider、账号或 assignment 信息。

## 主要特点

- 客户端统一使用稳定的 Pool API key，而不是上游账号凭据
- 仅公开和发现 `gemma3`，客户端无法切换真实目标或降低固定推理策略
- 支持 Ollama、OpenAI 兼容、Anthropic Messages 和 Codex backend 四种协议
- 在输出可见前可安全重试；输出可见后不会重放请求
- cache/session 标识按 Pool 和 API key 隔离，不保存完整响应作为缓存
- 操作员可以查看真实但经过净化的路由、重试、配额和计费元数据
- 请求日志不保存原始 prompt、completion、工具 payload、媒体内容或凭据

## 客户端地址

本地默认地址：

```text
模型：                       gemma3
Ollama base URL：            http://localhost:4000
Claude/Anthropic base URL：  http://localhost:4000
OpenAI SDK base URL：        http://localhost:4000/v1
Codex backend base URL：     http://localhost:4000/backend-api/codex
```

生产环境把 `http://localhost:4000` 替换为部署域名。所有运行时路由都使用 Pool
API key；不要把上游账号 token 配置到客户端。

### Ollama

```bash
curl -sS http://localhost:4000/api/tags \
  -H 'Authorization: Bearer <pool-api-key>'

curl -sS http://localhost:4000/api/chat \
  -H 'Authorization: Bearer <pool-api-key>' \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma3","messages":[{"role":"user","content":"hello"}],"stream":false}'
```

`/api/chat` 和 `/api/generate` 支持 Ollama JSON/NDJSON。`/api/tags`、
`/api/show` 和 `/api/ps` 最多只返回 `gemma3`。`/api/pull` 对 `gemma3`
是经过认证的 no-op；create/copy/push/delete/blob 和 embedding 操作不受支持。

### Claude Code

```bash
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_AUTH_TOKEN="<pool-api-key>"
export ANTHROPIC_API_KEY="<pool-api-key>"
export ANTHROPIC_MODEL="gemma3"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="gemma3"
export ANTHROPIC_DEFAULT_SONNET_MODEL="gemma3"
export ANTHROPIC_DEFAULT_OPUS_MODEL="gemma3"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

claude --model gemma3 --effort max
```

网关支持 `POST /v1/messages` 和 `POST /v1/messages/count_tokens`。
Claude Code 仍然负责本地 agent、工具、文件编辑和会话状态；网关负责模型流量和
池化路由。

### Codex CLI

在 `CODEX_HOME/config.toml` 中配置：

```toml
model = "gemma3"
model_provider = "codex-pooler"
model_reasoning_effort = "max"

[model_providers.codex-pooler]
name = "OpenAI"
base_url = "http://localhost:4000/backend-api/codex"
env_key = "CODEX_POOLER_API_KEY"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = false
```

```bash
export CODEX_POOLER_API_KEY="<pool-api-key>"
codex -m gemma3
```

### OpenAI SDK

```python
import os
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["CODEX_POOLER_API_KEY"],
    base_url="http://localhost:4000/v1",
)

response = client.responses.create(model="gemma3", input="hello")
print(response.output_text)
```

支持的核心路由包括 `/v1/models`、`/v1/responses`、
`/v1/chat/completions` 和 `/v1/completions`。这是一组有明确边界的兼容路由，
不是完整 OpenAI API，也不支持 `/v1/realtime`。

## Docker Compose 快速启动

```bash
git clone https://github.com/icoretech/codex-pooler.git
cd codex-pooler

export CODEX_POOLER_IMAGE_TAG=<release-tag>
scripts/self-host/generate-env.sh
docker compose pull
docker compose up -d
```

打开 `http://localhost:4000`，创建第一个 owner，然后：

1. 在 `/admin/pools` 创建 Pool
2. 在 `/admin/upstreams` 连接或导入有权限使用的 Codex 账号
3. 创建 Pool API key
4. 用上面的地址和 `gemma3` 配置客户端

Pool API key 只在创建或轮换时显示原文。上游凭据保存在网关的加密 secret
存储中，不应复制给客户端。

## 缓存、错误和隐私边界

Codex Pooler 不缓存完整响应。受支持的 prompt-cache 和 session 输入会被转换为按
Pool/API key 隔离的单向标识，用于提高上游 cache locality；这不是 cache hit
保证。

错误使用当前协议的安全格式。客户端响应和 header 不包含真实目标、provider、
账号、assignment、上游 request ID 或原始上游错误信息。身份净化只处理协议字段，
不会盲目改写用户文本、模型正文、文件名或工具参数。

`/mcp` 是独立的只读操作员元数据接口，必须使用 operator MCP token。Pool API
key 不能访问它。

## 验证

部署后可运行完整协议、SDK、Codex CLI 和 Claude Code 验证：

```bash
FACADE_BASE_URL=http://127.0.0.1:4000 \
FACADE_POOL_API_KEY='<pool-api-key>' \
bash scripts/verification/facade/run-live-clients.sh
```

详细英文文档见：

- https://docs.codex-pooler.com/clients/ollama/
- https://docs.codex-pooler.com/clients/claude-code/
- https://docs.codex-pooler.com/clients/openai-compatible/
- https://docs.codex-pooler.com/clients/codex-cli/
- https://docs.codex-pooler.com/reference/runtime-routes/
