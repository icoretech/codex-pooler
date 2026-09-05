# Contributing

## Tests

Use the Elixir and Erlang versions in `mise.toml` and an isolated PostgreSQL test database. Never point tests at a development or production database.

Run application tests with:

```sh
mix test
```

Run a focused file by passing its path to the same command. On Unix, `make test-fast N=4` runs the application suite in four isolated database partitions.

The default suite excludes the `unix_integration` profile. That profile tests the repository's Bash lifecycle scripts and Makefile, plus fixture contracts that require POSIX file ownership, permissions, or symbolic links. It includes process signals, resource cleanup, source manifests, and Docker Compose configuration merging. Parsing and domain tests remain in the ordinary suite. The integration profile runs separately and is required in CI:

```sh
mix test --only unix_integration
```

Use Linux, macOS, or WSL2 for this profile, with the same isolated PostgreSQL test setup. The tests check prerequisites before starting their fixtures and report missing commands. The Compose test needs the Docker CLI and Compose plugin to render configuration; it does not need a Docker daemon. Ordinary application tests do not run these shell harness checks. Native Windows execution of the full application suite has not been certified.

## Diagnostic output

Successful tests keep measurement output quiet. Query and frame budget failures include their measured values in the assertion. To print additional replay-cleanup measurements explicitly:

```sh
CODEX_POOLER_TEST_DIAGNOSTICS=1 mix test test/codex_pooler/accounting/request_replay_cleanup_test.exs
```

Expected error scenarios assert their diagnostics locally. Do not suppress unexpected application warnings or lower logging globally to make the suite pass.
