#!/usr/bin/env bash
# Approach 3, step 1: put the frontend's static files on S3.
#
# The files are taken out of the frontend image that was already built and
# tested (the same files nginx served), so nothing is rebuilt. app-config.js
# is written with empty addresses: on CloudFront the page and the APIs share
# one address.
#
#   deploy/publish-frontend.sh <bucket> [image]
#     image defaults to the frontend image pushed to ECR, from k8s/base/kustomization.yaml
#   DIST_ID=<CloudFront id> deploy/publish-frontend.sh <bucket>   also clears CloudFront's cache
#
# Run from the Application folder, on the EC2 box (Docker + AWS CLI).
set -euo pipefail
cd "$(dirname "$0")/.."
BUCKET="${1:?usage: deploy/publish-frontend.sh <bucket> [image]}"
IMAGE="${2:-$(awk '/name: frontend/{f=1} f&&/newName:/{n=$2} f&&/newTag:/{gsub(/"/,"",$2); print n":"$2; exit}' k8s/base/kustomization.yaml)}"
SITE="$(mktemp -d)"
trap 'rm -rf "$SITE"; docker rm -f frontend-files >/dev/null 2>&1 || true' EXIT

echo "== files from $IMAGE"
docker pull -q "$IMAGE" >/dev/null 2>&1 || true        # needs `docker login` to ECR first
docker create --name frontend-files "$IMAGE" >/dev/null
docker cp frontend-files:/usr/share/nginx/html/. "$SITE/"
printf 'window.__APP_CONFIG__ = { "authApiUrl": "", "tradeApiUrl": "" };\n' > "$SITE/app-config.js"   # <-- PROJECT: key names

echo "== upload to s3://$BUCKET"
# Hashed bundles can be cached for a year; the entry files must always be fresh.
aws s3 sync "$SITE/" "s3://$BUCKET/" --delete \
  --exclude index.html --exclude app-config.js \
  --cache-control "public, max-age=31536000, immutable"
aws s3 cp "$SITE/index.html" "s3://$BUCKET/index.html" --cache-control "no-cache" --content-type text/html
aws s3 cp "$SITE/app-config.js" "s3://$BUCKET/app-config.js" --cache-control "no-store" --content-type application/javascript
aws s3 ls "s3://$BUCKET/" | head

if [ -n "${DIST_ID:-}" ]; then
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/index.html' '/app-config.js' \
    --query 'Invalidation.Status' --output text
fi
