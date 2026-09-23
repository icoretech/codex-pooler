#!/usr/bin/env sh
set -eu

# The target is created before the secrets are written into it, so it must be owner-only from the
# start; a later chmod leaves a window in which another local user can open it.
umask 077

target="${1:-.env}"

if [ -e "$target" ]; then
  echo "$target already exists; remove it or pass a different output path" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate compose secrets" >&2
  exit 1
fi

rand_b64() {
  openssl rand -base64 "$1" | tr -d '\n'
}

postgres_password="$(openssl rand -hex 24)"
http_port="${CODEX_POOLER_HTTP_PORT:-4000}"
phx_host="${PHX_HOST:-localhost}"

if [ "${http_proxy+x}" = x ]; then
  http_proxy_value=$http_proxy
else
  http_proxy_value=${HTTP_PROXY:-}
fi

if [ "${https_proxy+x}" = x ]; then
  https_proxy_value=$https_proxy
else
  https_proxy_value=${HTTPS_PROXY:-}
fi

if [ "${no_proxy+x}" = x ]; then
  no_proxy_value=$no_proxy
else
  no_proxy_value=${NO_PROXY:-}
fi

cat > "$target" <<EOF
CODEX_POOLER_IMAGE=${CODEX_POOLER_IMAGE:-ghcr.io/icoretech/codex-pooler}
CODEX_POOLER_IMAGE_TAG=${CODEX_POOLER_IMAGE_TAG:-latest}
CODEX_POOLER_HTTP_PORT=${http_port}

http_proxy=${http_proxy_value}
https_proxy=${https_proxy_value}
no_proxy=${no_proxy_value}

PHX_HOST=${phx_host}
OBAN_MODE=${OBAN_MODE:-all}

POSTGRES_DB=${POSTGRES_DB:-codex_pooler_prod}
POSTGRES_USER=${POSTGRES_USER:-postgres}
POSTGRES_PASSWORD=${postgres_password}
DATABASE_URL=ecto://${POSTGRES_USER:-postgres}:${postgres_password}@db:5432/${POSTGRES_DB:-codex_pooler_prod}

SECRET_KEY_BASE=$(rand_b64 64)
CODEX_POOLER_TOTP_ENCRYPTION_KEY=$(rand_b64 32)
CODEX_POOLER_TOTP_KEY_VERSION=${CODEX_POOLER_TOTP_KEY_VERSION:-v1}
CODEX_POOLER_UPSTREAM_SECRET_KEY=$(rand_b64 32)
CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION=${CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION:-v1}
EOF

chmod 0600 "$target"
echo "wrote $target"
