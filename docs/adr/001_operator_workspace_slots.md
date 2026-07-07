# 2026-07-07 | DECISION | Preserve Operator Workspace Slots During Targeted Relink

## Decision

Codex Pooler supports operator-created workspace slots for ChatGPT business seats that share the same `chatgpt_account_id` when OpenAI OAuth omits a workspace identifier. During a targeted relink, Pooler may accept a missing incoming `workspace_id` only when the selected upstream identity already has a concrete `workspace_id` and its metadata marks it as an operator override:

```json
{"workspace_slot_source": "operator_override"}
```

When that condition is met, Pooler preserves the stored `workspace_id`, `workspace_label`, and `seat_type` while replacing the account tokens.

## Alternatives Considered

- Treat all missing workspace claims as legacy account links. This preserves strict OAuth identity matching, but collapses multiple business seats under the same business account.
- Manually duplicate upstream rows in the database without code support. This creates brittle state and risks later relinks erasing the synthetic slot.
- Require OpenAI to return a stable workspace claim. This is preferable long-term, but not available for the observed OAuth responses.

## Rationale

The bug is an identity-slot collision: two valid business seats can share a `chatgpt_account_id`, while OpenAI may omit the workspace claim Pooler needs to distinguish them. A targeted relink is already an operator-directed action against a selected upstream. Preserving a pre-created operator slot lets Pooler route each seat independently without weakening normal unassigned link behavior.

## Technical Debt Incurred

This is an operator-managed identity override. It should be replaced if OpenAI exposes a stable workspace or seat identifier in OAuth token claims or an account metadata endpoint.
