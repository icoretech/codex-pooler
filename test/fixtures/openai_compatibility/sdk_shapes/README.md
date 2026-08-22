# OpenAI SDK Shape Corpus

This directory stores metadata-only request-shape fixtures for OpenAI-compatible SDK behavior. The corpus is a foundation for later compatibility decisions and tests; it is not a store of raw transport captures.

## Required Fields

Every fixture entry must include:

- `schema_version`
- `scenario_id`
- `sdk_name`
- `sdk_package`
- `sdk_version`
- `version_provenance`
- `endpoint`
- `http_method`
- `scenario`
- `top_level_keys`
- `input_item_types`
- `content_part_types`
- `tool_shape_keys`
- `expected_decision`
- `owner_placeholder`
- `synthetic_data_policy`
- `structural_summary`
- `redaction_status`

`scenario_id` values are stable and become the join key for the compatibility matrix. Do not rename a scenario id after the compatibility matrix starts unless the matrix row changes in the same review.

## Redaction Rules

Fixtures must stay structural. They may record field names, item type names, content part type names, endpoint paths, package names, package versions, status classes, counts, and neutral placeholder ids.

Fixtures must not include credential header values, session header values, full real request payloads, real prompt text, customer or operator data, transport traces, upload locations, file bytes, audio bytes, image bytes, websocket frames, or raw external service responses.

Use neutral synthetic placeholders when a value is useful for shape clarity:

- `sample-user-message`
- `sample-tool-call`
- `sample-file-id`
- `sample-response-id`
- `https://example.com/sample.png`

## SDK Version Pinning And Provenance

Each fixture must pin the SDK package version that the shape is based on. Use the package registry version or the exact version from a sanitized local smoke run. Record the source in `version_provenance` without pasting transport bodies.

When a fixture is seeded from a blocked smoke path, keep the version pinned to the registry version queried for this corpus and note the blocker in the notepad rather than inventing raw capture evidence.

## Neutral Synthetic Data Policy

Examples must use generic placeholders only. Do not use real organization names, hostnames, repository names, personal names, tenant names, account ids, file names from real users, or live external locations when a synthetic placeholder works.

## Expected Decision Placeholder Policy

fixture capture does not decide compatibility behavior. Set `expected_decision.status` to `pending_compatibility_matrix` for every fixture. compatibility matrix owns `MATRIX.md` and will replace placeholders with one of `accept`, `translate`, `reject`, or `passthrough` plus row ownership.
