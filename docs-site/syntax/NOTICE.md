# PromQL syntax grammar

The PromQL TextMate grammar is adapted from [prometheus-community/vscode-promql](https://github.com/prometheus-community/vscode-promql), revision `0c64ce11e2325406cda5f5a6965c855ff203bf65`.

- [Original grammar](https://github.com/prometheus-community/vscode-promql/blob/0c64ce11e2325406cda5f5a6965c855ff203bf65/syntaxes/promql.tmlanguage.yml)
- License: Apache-2.0, reproduced in [LICENSE.promql](LICENSE.promql)
- Local changes: converted YAML to JSON; added Shiki language metadata; corrected an aggregator scope typo; added word boundaries to aggregation and selector keywords; gave comments, strings and duration ranges precedence over generic tokens; added the missing comparison operators

The grammar is vendored so documentation builds need no network fetch or additional runtime package. When refreshing it, retain the upstream revision and license and run `npm run check:promql` from `docs-site`. This is syntax highlighting, not a PromQL parser or query validator.
