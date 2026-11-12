#!/usr/bin/env sh
set -eu

# The target is created before the secrets are written into it, so it must be owner-only from the
# start; a later chmod leaves a window in which another local user can open it.
umask 077

target="${1:-.env}"

target_exists() {
  echo "$target already exists; remove it or pass a different output path" >&2
  exit 1
}

if [ -e "$target" ] || [ -L "$target" ]; then
  target_exists
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate compose secrets" >&2
  exit 1
fi

generation_failed() {
  echo "openssl failed to generate a secret; $target was not written" >&2
  exit 1
}

# Every secret is generated and checked before anything is created: a failure inside a pipeline or
# a here-document substitution would otherwise leave an empty value behind a success message.
rand_b64() {
  encoded="$(openssl rand -base64 "$1")" || return 1
  encoded="$(printf '%s' "$encoded" | tr -d '\n')" || return 1
  [ -n "$encoded" ] || return 1
  printf '%s' "$encoded"
}

postgres_password="$(openssl rand -hex 24)" || generation_failed
[ -n "$postgres_password" ] || generation_failed
secret_key_base="$(rand_b64 64)" || generation_failed
totp_encryption_key="$(rand_b64 32)" || generation_failed
upstream_secret_key="$(rand_b64 32)" || generation_failed

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

# The complete file is written to a private sibling first. The target name is then claimed with an
# exclusive create, so an invocation that lost a race to another writer fails instead of truncating
# the winner, and the rename replaces only the placeholder this invocation owns.
staged=""
claimed=""

cleanup() {
  [ -z "$staged" ] || rm -f "$staged"
  [ -z "$claimed" ] || rm -f "$target"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

staged="$(mktemp "$(dirname -- "$target")/.generate-env.XXXXXX")"

cat > "$staged" <<EOF
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

SECRET_KEY_BASE=${secret_key_base}
CODEX_POOLER_TOTP_ENCRYPTION_KEY=${totp_encryption_key}
CODEX_POOLER_TOTP_KEY_VERSION=${CODEX_POOLER_TOTP_KEY_VERSION:-v1}
CODEX_POOLER_UPSTREAM_SECRET_KEY=${upstream_secret_key}
CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION=${CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION:-v1}
EOF

chmod 0600 "$staged"

if ! (set -C && : > "$target") 2>/dev/null; then
  target_exists
fi

claimed=1
mv -f "$staged" "$target"
claimed=""
staged=""
echo "wrote $target"
