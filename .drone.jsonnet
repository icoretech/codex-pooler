local releaseBranch = 'release-please--branches--main--components--codex-pooler';
local registry = 'registry.icorete.ch';
local image = 'registry.icorete.ch/icoretech/codex-pooler';
local helmVersion = 'v4.2.3';
local nodeImage = 'node:26.5.0-slim';

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
        name: 'assets-deps',
        image: nodeImage,
        environment: {
          NPM_CONFIG_UPDATE_NOTIFIER: 'false',
        },
        commands: [
          'npm ci --prefix assets',
        ],
      },
      {
        name: 'quality',
        image: 'elixir:1.20.1-otp-28-slim',
        depends_on: ['assets-deps'],
        commands: [
          'apt-get update',
          'apt-get install -y --no-install-recommends build-essential ca-certificates curl git nodejs python3 ripgrep tar tzdata',
          'curl -fsSLO https://get.helm.sh/helm-' + helmVersion + '-linux-amd64.tar.gz',
          'curl -fsSLO https://get.helm.sh/helm-' + helmVersion + '-linux-amd64.tar.gz.sha256sum',
          'sha256sum -c helm-' + helmVersion + '-linux-amd64.tar.gz.sha256sum',
          'tar -xzf helm-' + helmVersion + '-linux-amd64.tar.gz',
          'install -m 0755 linux-amd64/helm /usr/local/bin/helm',
          'helm version --short',
          'mix local.hex --force',
          'mix local.rebar --force',
          'mix deps.get',
          'mix format --check-formatted',
          'mix compile --warnings-as-errors',
          'mix ecto.create --quiet',
          'mix ecto.migrate --quiet',
          'mix test',
          'mix assets.deploy',
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
        image: 'registry.icorete.ch/proxy-dockerhub/alpine/git',
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
        image: 'thegeeklab/drone-docker-buildx',
        privileged: true,
        depends_on: ['tag'],
        settings: {
          purge: true,
          no_cache: true,
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
        },
      },
      {
        name: 'build-no-push',
        image: 'thegeeklab/drone-docker-buildx',
        privileged: true,
        depends_on: ['tag'],
        settings: {
          dry_run: true,
          purge: true,
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
        },
      },
    ],
  },
]
