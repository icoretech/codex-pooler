#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
image=""
mode=""
receipt=""

while (($#)); do
  case "$1" in
    --image) image="${2:-}"; shift 2 ;;
    --mode) mode="${2:-}"; shift 2 ;;
    --receipt) receipt="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

[[ "$image" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]+$ ]] || { printf 'invalid image reference\n' >&2; exit 2; }
[[ "$mode" == "equivalent" || "$mode" == "changed-second" ]] || { printf 'invalid mode\n' >&2; exit 2; }

if [[ -z "$receipt" ]]; then
  receipt="$root_dir/.omo/evidence/task-11-local-${mode}.tsv"
fi

mkdir -p "$(dirname "$receipt")"
run_label="quota-proof-${mode}-$$"
network="${run_label}-network"
database="${run_label}-db"
proof="${run_label}-app"
database_name="quota_proof"
database_user="quota_proof"
database_credential="quota-proof-local-only"

cleanup() {
  docker rm -f "$proof" "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create --label codex-pooler.quota-proof=true "$network" >/dev/null
docker run -d --name "$database" --network "$network" \
  --label codex-pooler.quota-proof=true \
  -e POSTGRES_DB="$database_name" \
  -e POSTGRES_USER="$database_user" \
  -e POSTGRES_PASSWORD="$database_credential" \
  postgres:18 >/dev/null

for _attempt in $(seq 1 60); do
  if docker exec "$database" pg_isready -U "$database_user" -d "$database_name" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$database" pg_isready -U "$database_user" -d "$database_name" >/dev/null

common_env=(
  -e "DATABASE_URL=ecto://${database_user}:${database_credential}@${database}:5432/${database_name}"
  -e "SECRET_KEY_BASE=quota-proof-local-secret-key-base-with-more-than-sixty-four-bytes-000000"
  -e "PHX_HOST=localhost"
  -e "OBAN_MODE=web"
  -e "CODEX_POOLER_TOTP_ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  -e "CODEX_POOLER_TOTP_KEY_VERSION=v1"
  -e "CODEX_POOLER_UPSTREAM_SECRET_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  -e "CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION=v1"
)

docker run --rm --name "${proof}-migrate" --network "$network" \
  --label codex-pooler.quota-proof=true "${common_env[@]}" \
  "$image" /bin/sh -lc 'env -u PHX_SERVER /app/bin/codex_pooler eval "CodexPooler.Release.migrate()"' >/dev/null

temp_receipt="${receipt}.tmp"
raw_output="${receipt}.raw.tmp"
rm -f "$temp_receipt" "$raw_output"
docker run --rm --name "$proof" --network "$network" \
  --label codex-pooler.quota-proof=true "${common_env[@]}" \
  -e "QUOTA_PROOF_MODE=$mode" \
  -v "$root_dir/scripts/verification/quota-convergence:/proof:ro" \
  "$image" /bin/sh -lc 'env -u PHX_SERVER /app/bin/codex_pooler eval "Code.eval_file(\"/proof/proof.exs\")"' \
  >"$raw_output"

grep -E '^(transition|row|projection|cleanup)\t' "$raw_output" >"$temp_receipt"
rm -f "$raw_output"

"$root_dir/scripts/verification/quota-convergence/check-receipts.sh" \
  --mode "$mode" --receipt "$temp_receipt"
mv "$temp_receipt" "$receipt"
printf 'release quota proof passed mode=%s receipt=%s\n' "$mode" "$(basename "$receipt")"
