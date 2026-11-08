# Contributing

## Tests

Use the Elixir and Erlang versions in `mise.toml` and an isolated PostgreSQL test database. Never point tests at a development or production database.

Run application tests with:

```sh
mix test.product
```

Run a focused file with `mix test path/to/file_test.exs`. On Unix, `make test-fast N=4` runs only the application suite in four isolated database partitions and reports each partition's duration and test count. Each partition's VM starts with `+hmbs 1000000` (a minimum binary virtual heap of a million words): without it the larger test files compile up to two and a half times slower, so a plain `mix test` is faster with `ERL_FLAGS='+hmbs 1000000'`. `mix test` remains the complete compatibility entry point, with Unix tests excluded unless explicitly included.

A run with `CODEX_POOLER_TEST_RUN_NAMESPACE` and `MIX_TEST_PARTITION` set uses a database of its own and drops it when it finishes, whether it passes or fails. A run that is killed or crashes leaves that database behind; `make test-db-prune` drops every such database that no session is connected to and no running test holds, and never touches the shared `codex_pooler_test` databases.

Batch-deadline tests must observe the intended database phase before asserting partial progress. Hold the later batch on an owned row lock, verify the exact blocked backend and the earlier committed rows from a separate connection, and keep failure-detection budgets independent from the scenario deadline. Two timed sleeps do not prove which batch the deadline interrupted under four-partition scheduling pressure.

Multi-node timer tests must observe the exact handler that performed the transition. A database timestamp change does not identify a particular renewal, a state call can race process termination, and a process monitor does not order a registry's own monitor delivery. Use bounded, process-scoped observation and barriers to force the intended interleaving; keep the provider held before output when proving that a lease check—not a later output frame—caused cancellation. Shared peer fixtures must stop background database writers before per-test snapshots, not only when the module eventually shuts down.

Development tools, Mix tasks and test-infrastructure contracts run separately from the application tests. This profile also includes every `unix_integration` test: Bash lifecycle scripts, Makefile behavior, process signals, resource cleanup, source manifests, POSIX file operations and Docker Compose configuration merging. CI runs both product and tooling profiles:

```sh
mix test.tooling
```

To partition the tooling profile with the same scheduler and database isolation as product tests, run `TEST_FAST_COMMAND="mix test.tooling --warnings-as-errors" make test-fast N=4`. CI runs the two four-partition profiles sequentially, so it never doubles the configured CPU budget. The static checks of `mix quality` run in CI too: the format check, xref, Sobelow and Credo before the suites in the quality step, and Dialyzer in a parallel `dialyzer` step held to four schedulers, one partition's share beside the suites.

Every run can record how long each test file took. With `CODEX_POOLER_TEST_FILE_DURATIONS` naming a file in an existing directory, ExUnit writes a header with its `max_cases` and one tab-separated line per test file (`path`, `sync_ms`, `async_ms`): the wall time of the file's modules, with `setup_all` and `on_exit` included, split by the module's `async` option. `make test-fast` gives each partition its own file and, with `TEST_FAST_PRINT_FILE_DURATIONS=1`, prints them after a passing run. The CI pipeline sets it, so each build's log carries the duration of every test file.

A partitioned run of `mix test.product` or `mix test.tooling` (`--partitions N`, `MIX_TEST_PARTITION` naming the partition) deals the profile's files by recorded duration instead of by position: every partition computes the same deal from the profile's files, their weights in `test/partition_weights.tsv` and N, so adding or removing a test file moves only that file and the files lighter than it, and a partition of a CI run is reproduced by running the same command with the same weights file. A file without a weight counts as the median one of its profile. `mix test.unix` and focused runs keep Mix's own handling. To refresh the weights, save the log of the quality step of a green CI build and run `mix test.partition_weights <log>` (several logs combine by the median; `--dry-run` only reports). The task reads the printed durations, or files written through `CODEX_POOLER_TEST_FILE_DURATIONS`, and reports the measured run times of the partitions next to the weights' loads for Mix's deal and for the balanced one.

A test file is compiled before any of its tests run, and most of that time is the Erlang compiler's optimization passes, in proportion to the code the module expands to. A comprehension that generates tests expands and compiles the whole `test` body once per generated test, so a loop that generates more than a few tests keeps its scenario in a private function below the loop and every generated test is one call into it (`unquote(x)` arguments become parameters named `x`). Credo checks that function as it checks any other, so a body over the complexity or nesting limits carries a `credo:disable-for-next-line` with a reason, as `lib/` does. A module that is large rather than repetitive compiles in a third to half of the time with `@compile [:no_bool_opt, :no_ssa_opt]`, the options Elixir passes for code it evaluates once; a test runs once, so the optimizer only costs time there.

Use `mix test.unix` to run just the Unix subset. These commands select files before loading them; `mix test --only unix_integration` remains valid but loads the entire test tree before applying tags. `CodexPooler.TestProfiles` owns the profile inventory. The normal suite rejects a Unix-tagged test in an application file not covered by the tooling inventory, so newly added Unix cases cannot silently disappear from CI.

`mix test.tooling` owns its profile filters; for custom tag/name filters, pass explicit file paths or use the ordinary `mix test` command. Execution options such as `--seed` and `--warnings-as-errors` remain available.

Use Linux, macOS, or WSL2 for tooling/Unix profiles, with the same isolated PostgreSQL test setup. The tests check prerequisites before starting their fixtures and report missing commands. The Compose test needs the Docker CLI and Compose plugin to render configuration; it does not need a Docker daemon. Ordinary application tests do not run these shell harness checks. Native Windows execution of the full application suite has not been certified.

## Dependency updates

Review Renovate's open pull requests and Dependency Dashboard together: major updates awaiting approval and scheduled lock-file maintenance are not necessarily represented by an open pull request. Check the published package registries as well, including the standalone contract-probe dependencies.

Keep exact package pins and their lockfiles together. Refresh compatible transitive dependencies without replacing intentional compatibility constraints with an unrelated `latest` tag. The website's font-rendering and compiler constraints are documented in [docs-site/README.md](docs-site/README.md#social-card-rendering).

After integrating related updates, run the quality gate before the four-partition application baseline:

```sh
mise x -- mix quality
make test-fast N=4
npm run check --prefix docs-site
npm run build --prefix docs-site
```

Also exercise the changed consumer boundary: browser forms for UI dependencies, generated social cards for font dependencies, and the real SDK contract probes for collaborator dependency updates. The SDK terminal-error probe consumes the public SSE fixtures generated by the transport contract test, including `response.created` before a relayed `response.failed`; sanitized token usage retained by the SDK includes `total_tokens`. Preserve the invalid-sequence negative control and verify generated OpenCode adapters against their pinned source commit without changing that provenance incidentally.

For chart-library updates, exercise the real operator charts with synthetic data: render, replace the series, switch interval/cumulative mode, resize at the final viewport, and remount the page. Check the rendered SVG bounds and browser errors; helper tests and a successful bundle alone do not certify the browser integration.

## Diagnostic output

Successful tests keep measurement output quiet. Query and frame budget failures include their measured values in the assertion. To print additional replay-cleanup measurements explicitly:

```sh
CODEX_POOLER_TEST_DIAGNOSTICS=1 mix test test/codex_pooler/accounting/request_replay_cleanup_test.exs
```

Expected error scenarios assert their diagnostics locally. Do not suppress unexpected application warnings or lower logging globally to make the suite pass.
