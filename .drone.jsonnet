local releaseBranch = 'release-please--branches--main--components--codex-pooler';
local releaseNotesBranch = releaseBranch + '--release-notes';
local registry = 'registry.icorete.ch';
local image = 'registry.icorete.ch/icoretech/codex-pooler';
local buildxPlugin = 'plugins/buildx:1.3.23';
local tagImage = 'alpine/git:latest';
local helmVersion = 'v4.3.1';

[
  {
    kind: 'pipeline',
    type: 'kubernetes',
    name: 'next',
    clone: {
      depth: 1,
    },
    trigger: {
      branch: {
        // release-please stores oversized PR bodies on a sibling
        // `--release-notes` branch. Neither branch contains a candidate that
        // needs the application build pipeline.
        exclude: [releaseBranch, releaseNotesBranch],
      },
      event: {
        include: ['push'],
      },
      action: {
        exclude: ['synchronized'],
      },
    },
    services: [
      {
        name: 'pg',
        image: 'postgres:18',
        environment: {
          POSTGRES_DB: 'codex_pooler_test',
          POSTGRES_USER: 'postgres',
          POSTGRES_PASSWORD: 'postgres',
        },
        ports: [5432],
      },
    ],
    steps: [
      {
        name: 'quality',
        image: 'elixir:1.20.4-otp-29-slim',
        commands: [
          'mix quality.test_cleanup',
          'apt-get update',
          'apt-get install -y --no-install-recommends build-essential ca-certificates cmake curl git libsctp1 lsof procps python3 ripgrep tar tzdata',
          'curl -fsSLO https://get.helm.sh/helm-' + helmVersion + '-linux-amd64.tar.gz',
          'curl -fsSLO https://get.helm.sh/helm-' + helmVersion + '-linux-amd64.tar.gz.sha256sum',
          'sha256sum -c helm-' + helmVersion + '-linux-amd64.tar.gz.sha256sum',
          'tar -xzf helm-' + helmVersion + '-linux-amd64.tar.gz',
          'install -m 0755 linux-amd64/helm /usr/local/bin/helm',
          'helm version --short',
          'mix local.hex --force',
          'mix local.rebar --force',
          'mix deps.get',
          'mix compile --warnings-as-errors',
          // The image build runs this compile-connected graph check too, but only after the suites have passed.
          'mix quality.xref',
          'mix format --check-formatted',
          // The other static checks of `mix quality` except Dialyzer (its own step below), cheapest first, so a violation
          // fails here within a minute instead of after the suites.
          'mix quality.security',
          'mix quality.credo',
          'TEST_FAST_COMMAND="mix test.product --warnings-as-errors" make test-fast N=4',
          'apt-get install -y --no-install-recommends docker-cli docker-compose',
          'docker compose version',
          'TEST_FAST_COMMAND="mix test.tooling --warnings-as-errors" make test-fast N=4',
        ],
        environment: {
          MIX_ENV: 'test',
          POSTGRES_HOST: 'pg',
          POSTGRES_PORT: '5432',
          POSTGRES_DB: 'codex_pooler_test',
          POSTGRES_TEST_DB: 'codex_pooler_test',
          POSTGRES_USER: 'postgres',
          POSTGRES_PASSWORD: 'postgres',
          // Both `make test-fast` runs print each partition's per-file wall times after they pass, so the step log carries
          // the duration of every test file; `mix test.partition_weights <saved log>` turns it into the weights the
          // partitions are dealt by (test/partition_weights.tsv).
          TEST_FAST_PRINT_FILE_DURATIONS: '1',
        },
      },
      {
        // The Dialyzer part of `mix quality`, in `:test` like the local gate: Dialyxir is a dev/test dependency, and `:test`
        // also analyses `dev_support` and `test/support`. It starts with the build and runs beside the quality step, which
        // it finishes well before: a cold run (its own compile and PLT build) is a fraction of that step, so it stays off the
        // critical path, and `tag` waits for it so a red analysis never publishes an image. A cold PLT build does not
        // speed up past four cores, so the BEAM is held to four schedulers, which keeps it from starving the suites. The
        // steps share the workspace, so it builds into its own paths.
        name: 'dialyzer',
        image: 'elixir:1.20.4-otp-29-slim',
        commands: [
          'apt-get update',
          'apt-get install -y --no-install-recommends build-essential ca-certificates cmake git',
          'mix local.hex --force',
          'mix local.rebar --force',
          'mix deps.get',
          'mix quality.dialyzer',
        ],
        environment: {
          MIX_ENV: 'test',
          MIX_BUILD_PATH: '/tmp/dialyzer/_build',
          MIX_DEPS_PATH: '/tmp/dialyzer/deps',
          ERL_FLAGS: '+S 4:4',
        },
      },
      {
        name: 'tag',
        image: tagImage,
        depends_on: ['quality', 'dialyzer'],
        commands: [
          'CUSTOM_BRANCH_NAME=$(basename "${DRONE_SOURCE_BRANCH:-$DRONE_BRANCH}" | tr "[:upper:]" "[:lower:]" | sed "s/_/-/g")',
          'printf "%s" "$CUSTOM_BRANCH_NAME-$SHORT_SHA-$(date +%s)" > .tags',
          'cat .tags',
        ],
        environment: {
          SHORT_SHA: '${DRONE_COMMIT_SHA:0:8}',
        },
      },
      {
        name: 'build-and-push-main',
        image: buildxPlugin,
        privileged: true,
        depends_on: ['tag'],
        settings: {
          purge: true,
          no_cache: true,
          pull_image: true,
          platforms: ['linux/amd64'],
          repo: image,
          registry: registry,
          tags_file: '.tags',
          username: {
            from_secret: 'icoretech_registry_user',
          },
          password: {
            from_secret: 'icoretech_registry_secret_key',
          },
        },
        when: {
          branch: ['main'],
          event: ['push'],
        },
      },
      {
        name: 'build-no-push',
        image: buildxPlugin,
        privileged: true,
        depends_on: ['tag'],
        settings: {
          dry_run: true,
          purge: true,
          pull_image: true,
          no_cache: true,
          platforms: ['linux/amd64'],
          repo: image,
          registry: registry,
          tags_file: '.tags',
        },
        when: {
          branch: {
            exclude: ['main'],
          },
          event: ['push'],
        },
      },
    ],
  },
]
