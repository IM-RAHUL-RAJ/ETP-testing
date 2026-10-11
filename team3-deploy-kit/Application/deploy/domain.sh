#!/usr/bin/env bash
# Approach 3, step 3: your own https address, e.g. https://trade.example.com
#
#   1. an ACM certificate for the name (in us-east-1: CloudFront only reads certificates there),
#      proved by a DNS record that this script adds to your Route 53 hosted zone
#   2. the name and certificate added to the CloudFront distribution
#   3. a Route 53 alias record: the name -> the distribution
#
#   deploy/domain.sh <distribution-id> <name>        e.g. deploy/domain.sh E1ABCDEF2GHIJ trade.example.com
#
# Needs a public hosted zone in Route 53 for the name's domain (example.com),
# in this AWS account. Run from the Application folder.
set -euo pipefail
DIST_ID="${1:?usage: deploy/domain.sh <distribution-id> <name>}"
NAME="${2:?usage: deploy/domain.sh <distribution-id> <name>}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The hosted zone whose domain is the longest suffix of NAME.
ZONE_ID=""; zone_name="$NAME"
while [ -z "$ZONE_ID" ] && [[ "$zone_name" == *.* ]]; do
  ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$zone_name." --max-items 1 \
    --query "HostedZones[?Name=='$zone_name.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's|/hostedzone/||')"
  [ "$ZONE_ID" = None ] && ZONE_ID=""
  zone_name="${zone_name#*.}"
done
[ -n "$ZONE_ID" ] || { echo "No public Route 53 hosted zone found for $NAME" >&2; exit 1; }
echo "== hosted zone $ZONE_ID"

echo "== 1/3 certificate for $NAME (us-east-1)"
CERT_ARN="$(aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='$NAME'].CertificateArn | [0]" --output text)"
if [ "$CERT_ARN" = None ] || [ -z "$CERT_ARN" ]; then
  CERT_ARN="$(aws acm request-certificate --region us-east-1 --domain-name "$NAME" \
    --validation-method DNS --query CertificateArn --output text)"
  sleep 10   # ACM needs a moment before it shows the validation record
fi
read -r REC_NAME REC_VALUE < <(aws acm describe-certificate --region us-east-1 --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)
cat > "$WORK/validation.json" <<JSON
{"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
  "Name": "$REC_NAME", "Type": "CNAME", "TTL": 300, "ResourceRecords": [{"Value": "$REC_VALUE"}]}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$WORK/validation.json" >/dev/null
echo "   waiting for ACM to see the DNS record (usually 1-5 minutes)"
aws acm wait certificate-validated --region us-east-1 --certificate-arn "$CERT_ARN"
echo "   $CERT_ARN ISSUED"

echo "== 2/3 name + certificate on distribution $DIST_ID"
aws cloudfront get-distribution-config --id "$DIST_ID" > "$WORK/current.json"
ETAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$WORK/current.json")"
python3 - "$WORK/current.json" "$WORK/new.json" "$NAME" "$CERT_ARN" <<'PY'
import json, sys
src, dst, name, cert = sys.argv[1:]
cfg = json.load(open(src))["DistributionConfig"]
cfg["Aliases"] = {"Quantity": 1, "Items": [name]}
cfg["ViewerCertificate"] = {"ACMCertificateArn": cert, "SSLSupportMethod": "sni-only",
                            "MinimumProtocolVersion": "TLSv1.2_2021"}
json.dump(cfg, open(dst, "w"))
PY
aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
  --distribution-config "file://$WORK/new.json" --query 'Distribution.Status' --output text
DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"

echo "== 3/3 $NAME -> $DIST_DOMAIN (alias record)"
cat > "$WORK/alias.json" <<JSON
{"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
  "Name": "$NAME", "Type": "A",
  "AliasTarget": {"HostedZoneId": "Z2FDTNDATAQYW2", "DNSName": "$DIST_DOMAIN", "EvaluateTargetHealth": false}}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$WORK/alias.json" \
  --query 'ChangeInfo.Status' --output text

echo
echo "When the distribution is Deployed (aws cloudfront wait distribution-deployed --id $DIST_ID):"
echo "  open https://$NAME"
echo "  and make sure k8s/overlays/3-cloudfront/urls.env has CORS_ALLOWED_ORIGINS=https://$NAME,https://$DIST_DOMAIN"
