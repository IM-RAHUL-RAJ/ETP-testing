#!/usr/bin/env bash
# Install the AWS Load Balancer Controller, the component that turns an
# Ingress into a real AWS load balancer. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pipeline-env.sh
REGION="$AWS_REGION"
POLICY_NAME=AWSLoadBalancerControllerIAMPolicy

echo "==> Helm"
if ! command -v helm >/dev/null; then
  curl -fsSL --http1.1 --retry 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> IAM: let the worker nodes manage load balancers"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  curl -fsSL --http1.1 --retry 5 -o /tmp/alb-iam-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file:///tmp/alb-iam-policy.json >/dev/null
fi
NODEGROUP="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[0]' --output text)"
NODE_ROLE="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --query 'nodegroup.nodeRole' --output text | awk -F/ '{print $NF}')"
aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "$POLICY_ARN"

echo "==> AWS Load Balancer Controller"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" \
  --wait --timeout 5m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
