#!/usr/bin/env bash
set -euo pipefail
umask 022
fail() { printf 'pooler-hosted: %s\n' "$*" >&2; exit 2; }
case "${1:-}" in
  -h|--help) echo 'usage: hosted.sh tools|run|cleanup (CI_LANE=static|dialyzer|partition-1..4)'; exit 0 ;;
  tools|run|cleanup) mode=$1 ;;
  *) fail 'usage: hosted.sh tools|run|cleanup' ;;
esac
[[ $# == 1 ]] || fail 'unexpected arguments'
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == icoretech/codex-pooler ]] || fail 'canonical GitHub repository required'
case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
  push:refs/heads/*|workflow_dispatch:refs/heads/feat/tolgee-translations-*) ;;
  *) fail 'only branch pushes or translation branch dispatches are allowed' ;;
esac
if [[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]]; then
  [[ ${DEVELOPMENT_EXPECTED_SHA:-} == "${GITHUB_SHA:-}" ]] || fail 'dispatched translation revision changed'
fi
[[ ${RUNNER_OS:-} == Linux && ${RUNNER_ARCH:-} == X64 ]] || fail 'Linux x64 runner required'
[[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ && ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'invalid GitHub source/run identity'
[[ ${RUNNER_TEMP:-} == /* && -d $RUNNER_TEMP && ! -L $RUNNER_TEMP ]] || fail 'absolute runner temporary directory required'
for override in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
  [[ -z ${!override:-} ]] || fail "Docker override is forbidden: $override"
done
export DOCKER_CONTEXT=default
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
runner_temp=$(cd "$RUNNER_TEMP" && pwd -P)
lane=${CI_LANE:-tools}
if [[ $mode != tools ]]; then
  case "$lane" in static|dialyzer|partition-[1-4]) ;; *) fail 'invalid hosted lane' ;; esac
fi
run_id="github-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$lane"
docker_command=${CI_DOCKER_COMMAND:-docker}
# shellcheck source=scripts/ci/resources.sh
source "$repo/scripts/ci/resources.sh"
[[ $(docker_cli context inspect default --format '{{.Endpoints.docker.Host}}') == unix:///var/run/docker.sock ]] || fail 'local default Docker socket required'
tools_dir="$runner_temp/pooler-tools"
cache_dir="$runner_temp/pooler-cache"
for directory in "$tools_dir" "$cache_dir" "$cache_dir/build" "$cache_dir/deps" "$cache_dir/home"; do
  [[ ! -L $directory ]] || fail "symlink cache directory: $directory"
  [[ ! -e $directory || -d $directory ]] || fail "invalid cache directory: $directory"
done
cache_ownership() {
  [[ -d $cache_dir ]] || return 0
  if [[ $(id -u) == 0 ]]; then
    chown -R -h -P "$(id -u):$(id -g)" "$cache_dir"
  else
    sudo -n chown -R -h -P "$(id -u):$(id -g)" "$cache_dir"
  fi
}
if [[ $mode == cleanup ]]; then
  cleanup_rc=0
  cleanup || cleanup_rc=$?
  cache_ownership || cleanup_rc=$?
  exit "$cleanup_rc"
fi
[[ $(git rev-parse HEAD) == "$GITHUB_SHA" ]] || fail 'checkout differs from event revision'
[[ -z $(git status --porcelain --untracked-files=all) ]] || fail 'GitHub checkout must be clean'
[[ $(docker_cli info --format '{{.OSType}}/{{.Architecture}}') =~ ^linux/(amd64|x86_64)$ ]] || fail 'native Linux amd64 Docker daemon required'
tools_hash=$(sha256sum scripts/ci/Dockerfile | cut -d ' ' -f 1)
image="pooler-ci-hosted-tools:amd64-${tools_hash:0:20}"
verify_tools() {
  [[ $(docker_cli image inspect --format '{{.Os}} {{.Architecture}} {{index .Config.Labels "io.codex-pooler.ci.tools-source"}}' "$image") == "linux amd64 $tools_hash" ]] || fail 'tools image differs from Dockerfile or platform'
}
if [[ $mode == tools ]]; then
  mkdir -p "$tools_dir"
  archive="$tools_dir/tools.tar"
  [[ ! -L $archive && ! -L $tools_dir/tools.tar.partial ]] || fail 'symlink tools archive'
  if [[ -e $archive ]]; then
    [[ -f $archive && -s $archive ]] || fail 'invalid tools archive'
    phase tools-load docker_cli load --input "$archive"
    verify_tools
  else
    phase tools-build docker_cli build --builder default --platform linux/amd64 --provenance=false \
      --label "io.codex-pooler.ci.tools-source=$tools_hash" --tag "$image" - < scripts/ci/Dockerfile
    verify_tools
    docker_cli save --output "$tools_dir/tools.tar.partial" "$image"
    mv "$tools_dir/tools.tar.partial" "$archive"
  fi
  runtime_identity=$(image_runtime_identity "$image")
  printf 'tools_image=%s tools_source=%s runtime_identity=%s\n' "$image" "$tools_hash" "$runtime_identity"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'runtime_identity=%s\n' "$runtime_identity" >> "$GITHUB_OUTPUT"; fi
  exit 0
fi
verify_tools
output="$repo/tmp/ci-results/$run_id"
[[ ! -e $output && ! -L $output ]] || fail 'lane output already exists'
mkdir -p "$output" "$cache_dir/build" "$cache_dir/deps" "$cache_dir/home"
exec > >(tee "$output/run.log") 2>&1
started=$SECONDS
for kind in container network volume; do
  [[ -z $(resource_ids "$kind" --filter "label=io.codex-pooler.ci.run=$run_id") ]] || fail 'lane already owns resources; clean it first'
done
finish() {
  local rc=$1 cleanup_rc=0 ownership_rc=0
  trap - EXIT INT TERM HUP
  cleanup || cleanup_rc=$?
  cache_ownership || ownership_rc=$?
  if [[ $rc == 0 ]]; then
    [[ $cleanup_rc == 0 ]] || rc=$cleanup_rc
    [[ $ownership_rc == 0 ]] || rc=$ownership_rc
  fi
  printf '{"run":"%s","lane":"%s","exit":%s,"cleanupExit":%s,"cacheOwnershipExit":%s,"seconds":%s}\n' \
    "$run_id" "$lane" "$rc" "$cleanup_rc" "$ownership_rc" "$((SECONDS - started))" > "$output/receipt.json"
  exit "$rc"
}
trap 'finish "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
runtime_identity=$(image_runtime_identity "$image")
cache_identity=$(printf '%s\n' "$runtime_identity" "$(sha256sum mix.lock)" "$lane" | sha256sum | cut -d ' ' -f 1)
[[ ! -L $cache_dir/identity ]] || fail 'symlink cache identity'
if [[ -f $cache_dir/identity ]]; then
  [[ $(cat "$cache_dir/identity") == "$cache_identity" ]] || fail 'restored cache is incompatible with this runtime, lockfile or lane'
  printf 'lane_cache=%s state=hit\n' "$lane"
else
  [[ -z $(find "$cache_dir/build" "$cache_dir/deps" "$cache_dir/home" -mindepth 1 -print -quit) ]] || fail 'cache data has no compatibility identity'
  printf '%s\n' "$cache_identity" > "$cache_dir/identity"
  printf 'lane_cache=%s state=created\n' "$lane"
fi
node scripts/ci/snapshot.mjs "$repo" "$output/snapshot"
cp "$output/snapshot/source.json" "$output/source.json"
prefix="pooler-ci-$run_id"
label="io.codex-pooler.ci.run=$run_id"
workspace="$prefix-workspace"
docker_cli volume create --label "$label" "$workspace" >/dev/null
docker_cli run --rm -i --label "$label" --mount "type=volume,src=$workspace,dst=/workspace" "$image" tar -xf - -C /workspace < "$output/snapshot/source.tar"
mounts=(--mount "type=volume,src=$workspace,dst=/workspace" --mount "type=bind,src=$output,dst=/evidence")
for part in build deps home; do
  case "$part" in build) target=/workspace/_build ;; deps) target=/workspace/deps ;; home) target=/cache ;; esac
  mounts+=(--mount "type=bind,src=$cache_dir/$part,dst=$target")
done
extra=()
phase_name=$lane
if [[ $lane == partition-* ]]; then
  phase_name=partition
  network="$prefix-network"
  docker_cli network create --label "$label" "$network" >/dev/null
  docker_cli run -d --name "$prefix-pg" --label "$label" --network "$network" --network-alias pg \
    --tmpfs /var/lib/postgresql:rw,size=4g --shm-size=256m \
    -e POSTGRES_DB=codex_pooler_test -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
    postgres:18 -c max_connections=400 >/dev/null
  ready=0
  for _ in $(seq 1 120); do
    if docker_cli exec "$prefix-pg" pg_isready -h 127.0.0.1 -U postgres -d codex_pooler_test >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [[ $ready == 1 ]] || { docker_cli logs "$prefix-pg"; fail 'PostgreSQL did not become ready'; }
  namespace=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ $namespace =~ ^[0-9a-f]{16}$ ]] || fail 'invalid test namespace'
  extra=(--network "$network" -e "MIX_TEST_PARTITION=${lane#partition-}" -e "CODEX_POOLER_TEST_RUN_NAMESPACE=$namespace" -e CI_PARTITION_OUTPUT=/evidence)
fi
cpus=$(getconf _NPROCESSORS_ONLN)
[[ $cpus =~ ^[1-9][0-9]*$ ]] || fail 'invalid runner CPU count'
printf 'runner_cpus=%s lane=%s\n' "$cpus" "$lane"
docker_cli create --name "$prefix-lane" --label "$label" "${mounts[@]}" "${extra[@]}" \
  -e CI=true -e MIX_ENV=test -e MIX_HOME=/cache/mix -e HEX_HOME=/cache/hex \
  -e MIX_BUILD_PATH=/workspace/_build -e MIX_DEPS_PATH=/workspace/deps -e "ERL_FLAGS=+hmbs 1000000 +S $cpus:$cpus" \
  -e POSTGRES_HOST=pg -e POSTGRES_PORT=5432 -e POSTGRES_DB=codex_pooler_test -e POSTGRES_TEST_DB=codex_pooler_test \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  "$image" bash scripts/ci/phases.sh "$phase_name" >/dev/null
docker_cli start "$prefix-lane" >/dev/null
docker_cli logs --follow "$prefix-lane" 2>&1 | tee "$output/lane.log" &
log_pid=$!
lane_rc=$(docker_cli wait "$prefix-lane")
wait "$log_pid"
[[ $lane_rc =~ ^[0-9]+$ ]] || fail 'invalid container exit result'
printf 'lane=%s exit=%s\n' "$lane" "$lane_rc"
finish "$lane_rc"
