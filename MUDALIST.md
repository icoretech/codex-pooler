# MUDALIST

## 2026-07-07 | Operator Workspace Slot Override

- Debt: Pooler now supports operator-created workspace slots when OpenAI OAuth omits workspace identity for multiple business seats under one account.
- Interest: Medium. Future upstream auth changes may make the override unnecessary, and operators must preserve the local patch until an official release includes it.
- Mitigation: Regression test covers targeted relink into an operator slot with missing OAuth workspace claims. ADR: `docs/adr/001_operator_workspace_slots.md`.
