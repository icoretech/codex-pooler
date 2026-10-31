# English and Simplified Chinese glossary

This is the canonical terminology for the browser interface and human-readable email content. English remains the source language. Catalog locale `zh_CN` corresponds to the stored and HTML language tag `zh-CN`.

| English | Simplified Chinese | Rule |
| --- | --- | --- |
| Codex Pooler | Codex Pooler | Brand; never translate |
| Codex / OpenAI / ChatGPT | Codex / OpenAI / ChatGPT | Product names |
| Pool | Pool | Product object; keep Latin |
| Upstream / upstream account | 上游 / 上游账号 | |
| Operator | 运营者 | |
| Instance owner | 实例所有者 | |
| Instance admin | 实例管理员 | |
| API key | API 密钥 | |
| Quota | 配额 | Token and window quotas |
| Quota window | 配额窗口 | |
| Provider credits | 服务商额度 | |
| Saved reset | 已保存的重置 | |
| Banked reset | 储备重置 | |
| Assignment | 分配 | |
| Routing | 路由 | |
| Serving mode (Full/Lite) | 服务模式（Full/Lite） | Keep Full/Lite unchanged |
| Plan | 套餐 | |
| Session / turn | 会话 / 轮次 | |
| Circuit breaker | 熔断 | |
| Rate limit | 速率限制 | |
| Request log | 请求日志 | |
| Audit log | 审计日志 | |
| Alert rule / channel / incident | 告警规则 / 告警渠道 / 告警事件 | |
| Lens | Lens | Feature name |
| Observatory | 观测台 | |
| Cache hit rate | 缓存命中率 | |
| Token burn | Token 消耗 | |
| Archive / archived | 归档 / 已归档 | |
| Soft delete | 软删除 | |

## Chinese style

- Use full-width Chinese punctuation（，。：；！？）and half-width numbers and Latin text.
- Put one space between Chinese and Latin text or numbers: `API 密钥`, `3 个请求`; do not add spaces inside full-width parentheses: `服务模式（Full/Lite）`.
- Buttons, labels, menu items and headings have no trailing period. Descriptive sentences use Chinese punctuation.
- Prefer concise action labels: 保存、删除、取消、重试.
- Preserve `%{name}` placeholders exactly; their order may change.
- Keep compact dashboard durations (`2h 15m`, `<1m`) and units (`$`, `%`, `ms`, `k/M/B`) unchanged.
- Do not translate user-entered values, model/provider identifiers, URLs, status codes or stored metadata.
- Keep `MCP`, `API`, `OAuth`, `TOTP`, `SMTP`, `UTC`, `Full` and `Lite` unchanged.
- Email subjects keep rule-kind and severity identifiers unchanged so existing mail filters remain reliable.

## Review

Chinese drafts require a human terminology and contextual review before release approval. Automated catalog checks establish structural correctness, not linguistic approval.
