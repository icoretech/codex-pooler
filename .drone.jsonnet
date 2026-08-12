local releaseBranch = 'release-please--branches--main--components--codex-pooler';
local registry = 'registry.icorete.ch';
local image = 'registry.icorete.ch/icoretech/codex-pooler';
local buildxPlugin = 'plugins/buildx:1.3.23';
local tagImage = 'alpine/git:latest';
local helmVersion = 'v4.2.3';

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
        exclude: [releaseBranch],
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
        image: 'elixir:1.20.2-otp-28-slim',
        commands: [
          'apt-get update',
          'apt-get install -y --no-install-recommends build-essential ca-certificates cmake curl git lsof procps python3 ripgrep tar tzdata',
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
          'mix format --check-formatted',
          'TEST_FAST_COMMAND="mix test --warnings-as-errors" make test-fast N=4',
        ],
        environment: {
          MIX_ENV: 'test',
          POSTGRES_HOST: 'pg',
          POSTGRES_PORT: '5432',
          POSTGRES_DB: 'codex_pooler_test',
          POSTGRES_TEST_DB: 'codex_pooler_test',
          POSTGRES_USER: 'postgres',
          POSTGRES_PASSWORD: 'postgres',
        },
      },
      {
        name: 'tag',
        image: tagImage,
        depends_on: ['quality'],
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
