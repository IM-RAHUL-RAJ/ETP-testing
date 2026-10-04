#!/usr/bin/env bash
# Switch the tester stack from four load balancers to one.
#
# Installs the AWS Load Balancer Controller (once), then applies this folder:
# the Ingress is created, the four Services become internal (AWS deletes
# their load balancers), and the frontend is told to use relative addresses.
# Nothing is changed in the cluster until the controller is confirmed running.
#
#   ./k8s-ingress/enable-ingress.sh
#
# To go back: kubectl -n tester delete ingress trading
#             kubectl apply -k k8s-tester/ && ./k8s-tester/set-urls.sh
set -euo pipefail

CLUSTER="${CLUSTER:-capstone}"
REGION="${AWS_REGION:-ap-south-1}"
NS=tester
POLICY_NAME=AWSLoadBalancerControllerIAMPolicy
cd "$(dirname "$0")/.."

echo "==> 1/5 Helm"
if ! command -v helm >/dev/null; then
  curl -fsSL --http1.1 --retry 5 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> 2/5 IAM: let the worker nodes manage load balancers"
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

echo "==> 3/5 AWS Load Balancer Controller"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" \
  --wait --timeout 5m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m

echo "==> 4/5 Ingress on, four load balancers off"
# The controller's admission webhook can take a few seconds to accept calls.
for attempt in 1 2 3 4 5 6; do
  kubectl apply -k k8s-ingress/ && break
  [ "$attempt" = 6 ] && { echo "apply kept failing" >&2; exit 1; }
  echo "retrying in 10s"; sleep 10
done
# Pods read the ConfigMap only at start.
kubectl -n "$NS" rollout restart deployment/frontend
kubectl -n "$NS" rollout status deployment/frontend --timeout=5m

echo "==> 5/5 Waiting for the load balancer address"
HOST=""
for _ in $(seq 1 60); do
  HOST="$(kubectl -n "$NS" get ingress trading -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [ -n "$HOST" ] && break
  sleep 5
done
if [ -z "$HOST" ]; then
  echo "No address after 5 minutes. See: kubectl -n $NS describe ingress trading" >&2
  exit 1
fi

# Page and API now share one address, so the trade API should see these as
# same-origin calls. Listing the address as well costs nothing and covers the
# case where it does not.
kubectl -n "$NS" patch configmap trading-config --type merge -p "{\"data\":{\"CORS_ALLOWED_ORIGINS\":\"http://$HOST\"}}"
kubectl -n "$NS" rollout restart deployment/order-service
kubectl -n "$NS" rollout status deployment/order-service --timeout=5m

echo
echo "Open:  http://$HOST"
echo "The address can take 2 to 3 minutes to start answering."
kubectl -n "$NS" get services
