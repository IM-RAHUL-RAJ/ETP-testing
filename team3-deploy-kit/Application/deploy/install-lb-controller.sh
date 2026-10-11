#!/usr/bin/env bash
# Installs the AWS Load Balancer Controller: the piece that turns a Kubernetes
# Ingress into an AWS Application Load Balancer. Needed for approaches 2 and 3.
# Safe to run again.
#
#   deploy/install-lb-controller.sh <cluster-name> <region>
set -euo pipefail
CLUSTER="${1:?usage: deploy/install-lb-controller.sh <cluster-name> <region>}"
REGION="${2:?usage: deploy/install-lb-controller.sh <cluster-name> <region>}"
POLICY_NAME=AWSLoadBalancerControllerIAMPolicy

if ! command -v helm >/dev/null; then
  curl -fsSL --retry 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "== IAM: allow the worker nodes to manage load balancers"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
POLICY_ARN="arn:aws:iam::$ACCOUNT:policy/$POLICY_NAME"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  curl -fsSL --retry 5 -o /tmp/alb-iam-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file:///tmp/alb-iam-policy.json >/dev/null
fi
for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[]' --output text); do
  role="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --region "$REGION" \
    --query 'nodegroup.nodeRole' --output text | awk -F/ '{print $NF}')"
  aws iam attach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN"
done

echo "== Helm chart"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" --wait --timeout 5m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
