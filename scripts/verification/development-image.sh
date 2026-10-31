#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' 'usage: development-image.sh run|rehearse|cleanup'; }
[[ $# == 1 ]] || { usage >&2; exit 1; }
mode=$1
case "$mode" in
  --help|-h) usage; exit 0 ;;
  run|rehearse|cleanup) ;;
  *) usage >&2; exit 1 ;;
esac

registry=registry.icorete.ch
image="$registry/icoretech/codex-pooler"
source_url=https://github.com/icoretech/codex-pooler
current_main_revision() {
  local remote pattern=$'^[0-9a-f]{40}\trefs/heads/main$'
  remote=$(GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$source_url" refs/heads/main) || fail 'cannot resolve current main revision'
  [[ $remote =~ $pattern ]] || fail 'invalid current main revision'
  printf '%s\n' "${remote%%$'\t'*}"
}
rehearsal=false
content_hash=''
source_kind=commit
cache_dir=''
cache_imported=false
cache_exported=false
builder=default
if [[ $mode == rehearse || ( $mode == cleanup && ${CI_REHEARSAL:-} == true ) ]]; then
  rehearsal=true
  source_kind=snapshot
  [[ ${CI_REHEARSAL:-} == true ]] || fail 'rehearse requires explicit CI_REHEARSAL=true'
  [[ ${CI_RUN_ID:-} =~ ^rehearsal-[a-z0-9][a-z0-9-]{5,60}$ ]] || fail 'invalid rehearsal identity'
  [[ ${CI_SOURCE_RECEIPT:-} == /* && -f $CI_SOURCE_RECEIPT && ! -L $CI_SOURCE_RECEIPT ]] || fail 'absolute snapshot receipt required'
  revision=$(jq -er '.revision | select(type == "string" and test("^[0-9a-f]{40}$"))' "$CI_SOURCE_RECEIPT") || fail 'invalid snapshot revision'
  content_hash=$(jq -er '.contentHash | select(type == "string" and test("^[0-9a-f]{64}$"))' "$CI_SOURCE_RECEIPT") || fail 'invalid snapshot content hash'
  state_root=${CI_STATE_ROOT:-${TMPDIR:-/tmp}}
  [[ $state_root == /* && -d $state_root ]] || fail 'absolute existing state directory required'
  state_root=$(cd -- "$state_root" && pwd -P)
  state="$state_root/codex-pooler-image-$CI_RUN_ID"
  owner="$CI_RUN_ID:$revision:$content_hash"
  image=pooler-ci-rehearsal
  revision_label="snapshot:$content_hash"
  # Rehearsal never authenticates or publishes, including in an inherited CI shell.
  unset ICORETECH_REGISTRY_USER ICORETECH_REGISTRY_PASSWORD GITHUB_TOKEN GH_TOKEN
else
  [[ ${CI_REHEARSAL:-false} != true ]] || fail 'use rehearse for snapshot builds'
  [[ ${GITHUB_REPOSITORY:-} == icoretech/codex-pooler ]] || fail 'unexpected repository'
  case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
    push:refs/heads/*|workflow_dispatch:refs/heads/feat/tolgee-translations-*) ;;
    *) fail 'only branch pushes or translation branch dispatches are allowed' ;;
  esac
  if [[ ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]]; then
    [[ ${DEVELOPMENT_EXPECTED_SHA:-} == "${GITHUB_SHA:-}" ]] || fail 'dispatched translation revision changed'
  fi
  case "$GITHUB_REF" in
    refs/heads/release-please--branches--main--components--codex-pooler|refs/heads/release-please--branches--main--components--codex-pooler--release-notes)
      fail 'release automation branch is excluded' ;;
  esac
  [[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] || fail 'invalid run identity'
  [[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'invalid source revision'
  [[ ${RUNNER_TEMP:-} == /* && -d $RUNNER_TEMP ]] || fail 'missing absolute runner temporary directory'
  [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux && ${RUNNER_ARCH:-} == X64 ]] || fail 'native Linux x64 GitHub runner required'
  revision=$GITHUB_SHA
  revision_label=$revision
  state="$RUNNER_TEMP/codex-pooler-image-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  owner="$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT:$revision"
  if [[ -n ${CI_IMAGE_CACHE_DIR:-} ]]; then
    [[ $CI_IMAGE_CACHE_DIR == "$RUNNER_TEMP/pooler-image-cache" ]] || fail 'image cache must be RUNNER_TEMP/pooler-image-cache'
    case "$CI_IMAGE_CACHE_DIR/" in */../*|*/./*) fail 'image cache cannot contain traversal components' ;; esac
    [[ ! -L $CI_IMAGE_CACHE_DIR && ( ! -e $CI_IMAGE_CACHE_DIR || -d $CI_IMAGE_CACHE_DIR ) ]] || fail 'image cache must be a real directory'
    cache_dir=$CI_IMAGE_CACHE_DIR
    builder="pooler-image-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  fi
fi

cleanup() {
  [[ -e $state || -L $state ]] || return 0
  [[ -d $state && ! -L $state && -f $state/owner && ! -L $state/owner ]] || return 1
  [[ $(cat "$state/owner") == "$owner" ]] || return 1
  local tag owned_builder rc=0
  # Remove credentials even when Docker is unavailable or image removal fails.
  rm -f "$state/docker/config.json"
  rm -rf "$state/context"
  export DOCKER_CONFIG="$state/docker" DOCKER_CONTEXT=default
  unset DOCKER_HOST DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_CONFIG BUILDX_BUILDER
  if [[ -f $state/builder && ! -L $state/builder ]]; then
    owned_builder=$(cat "$state/builder")
    [[ $rehearsal == false && $owned_builder == "pooler-image-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" ]] || return 1
    if docker buildx rm --force "$owned_builder"; then
      rm "$state/builder"
    else
      rc=1
    fi
  fi
  [[ -e $state/builder ]] || rm -rf "$state/docker"
  if [[ -d $state/previous-cache ]]; then
    [[ -n $cache_dir && ! -L $cache_dir ]] || return 1
    # Restore a previous valid cache if interruption occurred between directory renames.
    [[ -e $cache_dir ]] || mv "$state/previous-cache" "$cache_dir" || rc=1
  fi
  if [[ -f $state/tag && ! -L $state/tag ]]; then
    tag=$(cat "$state/tag")
    [[ $tag =~ ^[a-z0-9][a-z0-9.-]*-${revision:0:8}-[0-9]+$ && ${#tag} -le 128 ]] || return 1
    if ! docker info >/dev/null 2>&1; then
      rc=1
    elif docker image inspect "$image:$tag" >/dev/null 2>&1; then
      docker image rm "$image:$tag" || rc=$?
    fi
  fi
  if [[ $rc == 0 ]]; then rm -rf "$state"; fi
  return "$rc"
}

if [[ $mode == cleanup ]]; then cleanup; exit; fi
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail 'native Linux x86_64 host required'
for override in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_CONFIG BUILDX_BUILDER; do
  [[ -z ${!override:-} ]] || fail "Docker override is forbidden: $override"
done
export DOCKER_CONTEXT=default
[[ $(docker context inspect default --format '{{.Endpoints.docker.Host}}') == unix:///var/run/docker.sock ]] || fail 'local default Docker socket required'
[[ $(docker info --format '{{.OSType}}/{{.Architecture}}') == linux/x86_64 ]] || fail 'local Linux amd64 daemon required'
if [[ -z $cache_dir ]]; then
  [[ $(docker buildx inspect default | awk '$1 == "Driver:" {print $2}') == docker ]] || fail 'default Docker driver required for local cache'
elif [[ -d $cache_dir ]]; then
  [[ -z $(find "$cache_dir" -type l -print -quit) ]] || fail 'image cache cannot contain symlinks'
  if [[ -n $(find "$cache_dir" -mindepth 1 -print -quit) ]]; then
    [[ -f $cache_dir/index.json && -f $cache_dir/oci-layout && -d $cache_dir/blobs ]] || fail 'image cache is not an OCI layout'
    jq -e '.schemaVersion == 2 and (.manifests | type == "array" and length > 0)' "$cache_dir/index.json" >/dev/null || fail 'invalid image cache index'
    cache_imported=true
  fi
fi
if [[ $rehearsal == true ]]; then
  [[ ${CI_SOURCE_DIR:-} == /* && -d $CI_SOURCE_DIR && ! -L $CI_SOURCE_DIR ]] || fail 'absolute frozen source directory required'
  [[ ${CI_OUTPUT_DIR:-} == /* && -d $CI_OUTPUT_DIR && ! -L $CI_OUTPUT_DIR ]] || fail 'absolute existing rehearsal output directory required'
  source_dir=$(cd -- "$CI_SOURCE_DIR" && pwd -P)
  evidence=$(cd -- "$CI_OUTPUT_DIR" && pwd -P)
  case "$evidence/" in "$source_dir/"*) fail 'rehearsal output must be outside the frozen source' ;; esac
  case "$state/" in "$source_dir/"*) fail 'rehearsal state must be outside the frozen source' ;; esac
  snapshot_tool="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../ci" && pwd)/snapshot.mjs"
  node "$snapshot_tool" --verify "$source_dir" "$CI_SOURCE_RECEIPT" >/dev/null
else
  [[ $(git rev-parse HEAD) == "$revision" ]] || fail 'checkout does not match event revision'
  if [[ $GITHUB_REF == refs/heads/main ]]; then
    [[ -n ${ICORETECH_REGISTRY_USER:-} && -n ${ICORETECH_REGISTRY_PASSWORD:-} ]] || fail 'main publication requires registry credentials'
  fi
  evidence="$(git rev-parse --show-toplevel)/tmp/ci-results/github-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
fi
[[ ! -e $evidence/image.json && ! -e $evidence/image-build.log ]] || fail 'image evidence already exists; choose a fresh run output'

mkdir "$state" || fail 'run already has image state; clean it before retrying'
printf '%s\n' "$owner" > "$state/owner"
trap 'rc=$?; trap - EXIT; cleanup || { [[ $rc != 0 ]] || rc=1; }; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$state/context" "$state/docker"
plugin_dir="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
if [[ -d $plugin_dir ]]; then ln -s "$plugin_dir" "$state/docker/cli-plugins"; fi
export DOCKER_CONFIG="$state/docker"
if [[ -n $cache_dir ]]; then
  # Builder metadata must use this isolated config, not the caller's Docker credentials.
  [[ -z $(docker container ls --all --filter "name=^/buildx_buildkit_${builder}0$" --format '{{.ID}}') ]] || fail 'image builder container already exists'
  docker buildx create --name "$builder" --driver docker-container default >/dev/null
  printf '%s\n' "$builder" > "$state/builder"
  docker buildx inspect "$builder" --bootstrap >/dev/null
fi

extra_labels=()
if [[ $rehearsal == true ]]; then
  # Copy and verify the supplied frozen tree, including its uncommitted changes.
  COPYFILE_DISABLE=1 tar -C "$source_dir" -cf "$state/source.tar" .
  tar -xf "$state/source.tar" -C "$state/context"
  rm "$state/source.tar"
  node "$snapshot_tool" --verify "$state/context" "$CI_SOURCE_RECEIPT" >/dev/null
  branch="rehearsal-${content_hash:0:12}"
  extra_labels=(--label "io.codex-pooler.ci.snapshot=$content_hash" --label "io.codex-pooler.ci.base-revision=$revision")
else
  # Build the exact event commit; ignored runner files never enter its context.
  git archive --output="$state/source.tar" "$revision"
  tar -xf "$state/source.tar" -C "$state/context"
  rm "$state/source.tar"
  branch=${GITHUB_REF#refs/heads/}
  branch=${branch##*/}
  branch=$(printf '%s' "$branch" | LC_ALL=C tr '[:upper:]_' '[:lower:]-' | LC_ALL=C sed 's/[^a-z0-9.-]/-/g; s/^[.-]*//')
  branch=${branch:-branch}
fi
# Freeze tag ordering before checking main; a stale run remains build-only.
suffix="-${revision:0:8}-$(date +%s)"
publish_eligible=false
if [[ $rehearsal == false && ${GITHUB_REF:-} == refs/heads/main ]]; then
  main_revision=$(current_main_revision)
  [[ $main_revision != "$revision" ]] || publish_eligible=true
fi
branch=${branch:0:$((128 - ${#suffix}))}
tag="$branch$suffix"
printf '%s\n' "$tag" > "$state/tag"
mkdir -p "$evidence"
: > "$evidence/image-build.log"
chmod 0644 "$evidence/image-build.log"

cache_args=()
if [[ -n $cache_dir ]]; then
  [[ $cache_imported == false ]] || cache_args+=(--cache-from "type=local,src=$cache_dir")
  cache_args+=(--cache-to "type=local,dest=$state/cache-export,mode=max")
fi
docker buildx build --builder "$builder" --platform linux/amd64 --load --provenance=false --pull --progress plain "${cache_args[@]}" \
  --label "org.opencontainers.image.revision=$revision_label" \
  --label "org.opencontainers.image.source=$source_url" "${extra_labels[@]}" \
  --tag "$image:$tag" "$state/context" 2>&1 | tee "$evidence/image-build.log"
docker image inspect "$image:$tag" > "$state/local.json"
jq -e --arg sha "$revision_label" --arg source "$source_url" '
  length == 1 and .[0].Architecture == "amd64" and .[0].Os == "linux" and
  .[0].Config.Labels["org.opencontainers.image.revision"] == $sha and
  .[0].Config.Labels["org.opencontainers.image.source"] == $source
' "$state/local.json" >/dev/null
if [[ -n $cache_dir ]]; then
  [[ -f $state/cache-export/index.json && -f $state/cache-export/oci-layout && -d $state/cache-export/blobs ]] || fail 'image cache export is incomplete'
  [[ -z $(find "$state/cache-export" -type l -print -quit) ]] || fail 'image cache export contains symlinks'
  jq -e '.schemaVersion == 2 and (.manifests | type == "array" and length > 0)' "$state/cache-export/index.json" >/dev/null || fail 'invalid image cache export index'
  [[ ! -e $cache_dir ]] || mv "$cache_dir" "$state/previous-cache"
  mv "$state/cache-export" "$cache_dir"
  rm -rf "$state/previous-cache"
  cache_exported=true
fi

published=false
digest=''
if [[ $publish_eligible == true ]]; then
  main_revision=$(current_main_revision)
  [[ $main_revision == "$revision" ]] || publish_eligible=false
fi
if [[ $publish_eligible == true ]]; then
  printf '%s' "$ICORETECH_REGISTRY_PASSWORD" | docker login "$registry" --username "$ICORETECH_REGISTRY_USER" --password-stdin
  unset ICORETECH_REGISTRY_PASSWORD
  : > "$evidence/image-push.log"
  chmod 0644 "$evidence/image-push.log"
  docker push "$image:$tag" | tee "$evidence/image-push.log"
  digest=$(sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p' "$evidence/image-push.log" | tail -1)
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'push returned no valid digest'
  [[ $(docker buildx imagetools inspect "$image:$tag" --format '{{.Manifest.Digest}}') == "$digest" ]] || fail 'published tag digest mismatch'
  docker buildx imagetools inspect "$image@$digest" --format '{{json .Image}}' > "$state/remote.json"
  jq -e --arg sha "$revision_label" --arg source "$source_url" '
    .architecture == "amd64" and .os == "linux" and
    .config.Labels["org.opencontainers.image.revision"] == $sha and
    .config.Labels["org.opencontainers.image.source"] == $source
  ' "$state/remote.json" >/dev/null
  published=true
fi
jq -n --arg image "$image" --arg tag "$tag" --arg revision "$revision" \
  --arg sourceKind "$source_kind" --arg contentHash "$content_hash" \
  --arg digest "$digest" --argjson published "$published" --argjson cacheImported "$cache_imported" --argjson cacheExported "$cache_exported" \
  '{image: $image, tag: $tag, revision: $revision, sourceKind: $sourceKind, contentHash: $contentHash, platform: "linux/amd64", published: $published, digest: $digest, cacheImported: $cacheImported, cacheExported: $cacheExported}' \
  > "$evidence/image.json"
chmod 0644 "$evidence/image.json"
printf 'image=%s:%s source=%s revision=%s snapshot=%s platform=linux/amd64 published=%s digest=%s\n' "$image" "$tag" "$source_kind" "$revision" "$content_hash" "$published" "$digest"
