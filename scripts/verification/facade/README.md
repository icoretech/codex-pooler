# Facade client verification

This harness verifies the authenticated `gemma3` facade without exposing the Pool API key or printing raw model responses.

## Contract gate

`run-contract.sh` needs only Bash, curl, and Python 3. It exercises eight requests: Ollama chat/generate, OpenAI Responses, and Anthropic Messages, each in collected JSON and streaming mode. The gate checks tools, terminal framing, response-header cloaking, and every advertised model field.

```bash
FACADE_BASE_URL=http://127.0.0.1:4000 \
FACADE_POOL_API_KEY='pool-key' \
bash scripts/verification/facade/run-contract.sh
```

The automated ExUnit contract starts an isolated public endpoint and fake upstream, then invokes this script with a temporary Pool key:

```bash
mix test test/codex_pooler/facade/client_contract_test.exs
```

## Official SDK gate

The lockfile pins these official clients:

- `ollama` 0.6.3
- `openai` 7.4.0
- `@anthropic-ai/sdk` 0.116.0

Install exactly the locked dependency graph and run text, tool, and streaming calls:

```bash
npm ci --prefix scripts/verification/facade --ignore-scripts
FACADE_BASE_URL=http://127.0.0.1:4000 \
FACADE_POOL_API_KEY='pool-key' \
node scripts/verification/facade/clients.mjs
```

## Full live-client gate

`run-live-clients.sh` runs the protocol contract, all three official SDKs, Codex CLI, and Claude Code. It creates temporary Git repositories and isolated client homes, verifies repo reads, shell tools, edits, tests, interruption/continuation, and repeated long-session requests, then deletes the temporary workspace.

```bash
FACADE_BASE_URL=http://127.0.0.1:4000 \
FACADE_POOL_API_KEY='pool-key' \
bash scripts/verification/facade/run-live-clients.sh
```

Required live binaries are `node`, `npm`, `codex`, and `claude`, plus the contract-gate tools. Codex receives an empty task-specific `CODEX_HOME` and command-line provider overrides. Claude Code runs with an isolated `HOME`, bare mode, and all model aliases fixed to `gemma3`. Neither client reads the operator's normal project configuration.

The scripts never echo the Pool API key. Failures report the failing client/stage without dumping SDK objects, provider responses, prompts, or credentials.
