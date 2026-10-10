#!/usr/bin/env bash
# Pushes the images docker compose built to ECR, one repository per image.
# Creates the repositories the first time. The Kubernetes files then pull
# <account>.dkr.ecr.<region>.amazonaws.com/<prefix>-<service>:<tag>.
#
#   deploy/push-ecr.sh <tag>          e.g. deploy/push-ecr.sh 1.0
#
# Run from the Application folder after `docker compose build`.
# Use a NEW tag for every change (1.1, 1.2...): nodes keep an image they
# already have under the same tag.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: deploy/push-ecr.sh <tag>}"
REGION="${AWS_REGION:-$(aws configure get region || true)}"
REGION="${REGION:?set AWS_REGION, e.g. export AWS_REGION=ap-south-1}"
PREFIX="${IMAGE_PREFIX:-trading}"                                     # <-- PROJECT (same as .env)
SERVICES="${SERVICES:-frontend auth-service order-service executor-service}"   # <-- PROJECT
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
for s in $SERVICES; do
  repo="$PREFIX-$s"
  aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1 ||
    aws ecr create-repository --region "$REGION" --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true --query 'repository.repositoryUri' --output text
  docker tag "$PREFIX-$s:${LOCAL_TAG:-latest}" "$REGISTRY/$repo:$TAG"
  docker push -q "$REGISTRY/$repo:$TAG"
done
echo
echo "Pushed. In k8s/base/kustomization.yaml set, under images:"
echo "  newName: $REGISTRY/$PREFIX-<service>     newTag: \"$TAG\""
