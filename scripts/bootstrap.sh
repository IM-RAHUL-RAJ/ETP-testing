#!/usr/bin/env bash
# One-time preparation of the cluster for the pipeline. Safe to run again:
# every step checks before it creates.
#
# Not done here, because they are done once by hand and involve a password
# or the network (see GUIDE.html): the RDS schema, the VPC peering to RDS,
# and the trading-secrets Secret.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pipeline-env.sh

echo "==> ECR repositories"
for entry in "${IMAGES[@]}"; do
  name="${entry%%:*}"
  aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$name" >/dev/null 2>&1 ||
    aws ecr create-repository --region "$AWS_REGION" --repository-name "$name" >/dev/null
done

echo "==> Disk add-on (EBS CSI)"
if ! aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" >/dev/null 2>&1; then
  NODEGROUP="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$AWS_REGION" --query 'nodegroups[0]' --output text)"
  NODE_ROLE="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" \
    --query 'nodegroup.nodeRole' --output text | awk -F/ '{print $NF}')"
  aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
  aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" >/dev/null
  aws eks wait addon-active --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver --region "$AWS_REGION"
fi

./scripts/install-lb-controller.sh

echo "==> Namespace and Secret"
kubectl apply -f k8s-tester/namespace.yaml
if ! kubectl -n "$NS" get secret trading-secrets >/dev/null 2>&1; then
  echo "Secret trading-secrets is missing. Create it once (GUIDE.html, Deploy to the cluster):" >&2
  echo "  kubectl -n $NS create secret generic trading-secrets --from-literal=db-password=... --from-literal=jwt-secret=... --from-literal=fauxnance-api-key=..." >&2
  exit 1
fi
echo "Cluster is ready for the pipeline."
