#!/bin/sh
# forge-ci-build — `docker build` with the job's registry-backed layer cache.
# Installed into job containers by the runner for setup_remote_docker jobs
# with `docker_layer_caching: true` (see docs/configuration.md). Builds run
# through the job's buildx builder, so image layers are exported to the
# cache registry during the build and reloaded on the next runner:
#
#   forge-ci-build -t registry/app:sha .
#
# Every argument passes through to `docker buildx build`.
set -eu

if [ -z "${FORGE_CI_BUILD_BUILDER:-}" ] || [ -z "${FORGE_CI_BUILD_CACHE_TO:-}" ]; then
  echo "forge-ci-build: this job has no layer cache configured." >&2
  echo "Set docker_layer_caching: true under setup_remote_docker, and" >&2
  echo "FORGE_CI_BUILD_CACHE_REGISTRY on the forge-ci server (docs/configuration.md)." >&2
  exit 2
fi

set -- --builder "$FORGE_CI_BUILD_BUILDER" \
       --cache-from "type=registry,ref=$FORGE_CI_BUILD_CACHE_FROM" \
       --cache-to "type=registry,ref=$FORGE_CI_BUILD_CACHE_TO,mode=max" \
       "$@"

# --load makes the built image visible to `docker run` / `docker push`
# afterwards; skip it when the caller ships the image somewhere itself.
loads_image=1
for arg in "$@"; do
  case "$arg" in
    --push | --output | -o | --load) loads_image=0 ;;
  esac
done
[ "$loads_image" = 1 ] && set -- --load "$@"

exec docker buildx build "$@"
