#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${CODEX_POOLER_OPERATOR_IMAGE_NAME:-codex-pooler}"
IMAGE_TAG="${CODEX_POOLER_OPERATOR_IMAGE_TAG:-operator-workspace-slot}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$repo_root"

docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .

cat <<MSG
Built ${IMAGE_NAME}:${IMAGE_TAG}.

To run this image with Docker Compose, set these in .env:
CODEX_POOLER_IMAGE=${IMAGE_NAME}
CODEX_POOLER_IMAGE_TAG=${IMAGE_TAG}

Then recreate only the app container:
docker compose up -d --no-deps app
MSG
