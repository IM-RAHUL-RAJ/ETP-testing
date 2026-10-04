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
cd "$(dirname "$0")/.."

echo "==> 1/3 AWS Load Balancer Controller"
./scripts/install-lb-controller.sh

echo "==> 2/3 Ingress on, four load balancers off"
# The controller's admission webhook can take a few seconds to accept calls.
for attempt in 1 2 3 4 5 6; do
  kubectl apply -k k8s-ingress/ && break
  [ "$attempt" = 6 ] && { echo "apply kept failing" >&2; exit 1; }
  echo "retrying in 10s"; sleep 10
done
# Pods read the ConfigMap only at start.
kubectl -n "$NS" rollout restart deployment/frontend
kubectl -n "$NS" rollout status deployment/frontend --timeout=5m

echo "==> 3/3 Waiting for the load balancer address"
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
