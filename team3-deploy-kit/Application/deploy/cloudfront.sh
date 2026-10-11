#!/usr/bin/env bash
# Approach 3, step 2: one CloudFront distribution in front of everything.
#
#   /api/*, /auth/*   -> the ALB of k8s/overlays/3-cloudfront (no caching, all headers)
#   everything else   -> the private S3 bucket (cached; app routes get index.html)
#
# Page and APIs share one https address, so there is no CORS and the login
# cookie can be Secure. The bucket stays private: only this distribution may
# read it (Origin Access Control).
#
#   deploy/cloudfront.sh <bucket>
#
# Run from the Application folder after publish-frontend.sh and after the
# 3-cloudfront overlay's Ingress has an address. Prints the distribution id
# and its https://dxxxx.cloudfront.net address.
set -euo pipefail
cd "$(dirname "$0")/.."
BUCKET="${1:?usage: deploy/cloudfront.sh <bucket>}"
NS="$(awk '/^namespace:/{print $2}' k8s/base/kustomization.yaml)"
BUCKET_REGION="$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text)"
[ "$BUCKET_REGION" = None ] && BUCKET_REGION=us-east-1
ALB="$(kubectl -n "$NS" get ingress app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[ -n "$ALB" ] || { echo "The Ingress has no address yet: kubectl -n $NS get ingress app" >&2; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
NAME="${BUCKET}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "== 1/4 Origin Access Control (lets CloudFront sign its requests to S3)"
OAC_ID="$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='$NAME'].Id | [0]" --output text)"
if [ "$OAC_ID" = None ] || [ -z "$OAC_ID" ]; then
  OAC_ID="$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=$NAME,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)"
fi
echo "   $OAC_ID"

echo "== 2/4 CloudFront Function: app routes such as /dashboard get index.html"
FN="${NAME}-spa"
cat > "$WORK/spa.js" <<'JS'
function handler(event) {
  var request = event.request;
  // A path without a file extension is an app route: serve the app.
  if (request.uri.indexOf('.') === -1) { request.uri = '/index.html'; }
  return request;
}
JS
if ! aws cloudfront describe-function --name "$FN" >/dev/null 2>&1; then
  aws cloudfront create-function --name "$FN" --function-code "fileb://$WORK/spa.js" \
    --function-config '{"Comment":"SPA routes","Runtime":"cloudfront-js-2.0"}' >/dev/null
fi
ETAG="$(aws cloudfront describe-function --name "$FN" --query ETag --output text)"
aws cloudfront publish-function --name "$FN" --if-match "$ETAG" >/dev/null
FN_ARN="$(aws cloudfront describe-function --name "$FN" --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"
echo "   $FN_ARN"

echo "== 3/4 Distribution"
sed -e "s|@CALLER@|$NAME-$(date +%s)|" -e "s|@BUCKET_DOMAIN@|$BUCKET.s3.$BUCKET_REGION.amazonaws.com|" \
    -e "s|@OAC_ID@|$OAC_ID|" -e "s|@ALB@|$ALB|" -e "s|@FUNCTION_ARN@|$FN_ARN|" \
    deploy/cloudfront-distribution.json > "$WORK/dist.json"
read -r DIST_ID DIST_DOMAIN < <(aws cloudfront create-distribution --distribution-config "file://$WORK/dist.json" \
  --query 'Distribution.[Id,DomainName]' --output text)
echo "   $DIST_ID  $DIST_DOMAIN"

echo "== 4/4 Bucket policy: only this distribution may read the bucket"
cat > "$WORK/policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "CloudFrontRead",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*",
    "Condition": {"StringEquals": {"AWS:SourceArn": "arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"}}
  }]
}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$WORK/policy.json"

echo
echo "Distribution $DIST_ID is deploying (5-10 minutes):"
echo "  aws cloudfront wait distribution-deployed --id $DIST_ID"
echo "Then open https://$DIST_DOMAIN and put that address in k8s/overlays/3-cloudfront/urls.env (CORS_ALLOWED_ORIGINS)."
