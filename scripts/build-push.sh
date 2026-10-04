#!/usr/bin/env bash
# Build the four images, push them to ECR under one tag, then remove the
# local copies so the build machine's disk does not fill up.
#
#   ./scripts/build-push.sh <tag>
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pipeline-env.sh
TAG="${1:?usage: build-push.sh <tag>}"
REGISTRY="$(registry)"

aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

for entry in "${IMAGES[@]}"; do
  name="${entry%%:*}"; context="${entry#*:}"
  ref="${REGISTRY}/${name}:${TAG}"
  args=()
  [ "$name" = trading-frontend ] && args=(--build-arg APP_PORT=4200)
  echo "==> ${name}"
  docker build "${args[@]}" -t "$ref" "$context"
  docker push "$ref"
  # The image is safe in ECR; the cluster pulls it from there.
  docker rmi "$ref" >/dev/null
done

# Leftover layers from this and earlier builds. The build cache is kept (up
# to 4 GB) so the next build does not download every dependency again.
docker image prune -f >/dev/null
docker builder prune -f --keep-storage 4GB >/dev/null
docker system df
