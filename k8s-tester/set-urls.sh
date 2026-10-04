#!/usr/bin/env bash
# Point the browser-facing settings at the load balancers.
#
# The frontend hands AUTH_URL and BACKEND_URL to the browser, and trade-api
# only accepts calls from CORS_ALLOWED_ORIGINS. Those addresses exist only
# after the LoadBalancer Services are created, so run this once after the
# first `kubectl apply -k k8s-tester/`, and again if a Service is recreated.
set -euo pipefail
NS="${NS:-tester}"

lb() {
  local host=""
  for _ in $(seq 1 60); do
    host="$(kubectl -n "$NS" get service "$1" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    [ -n "$host" ] && { echo "$host"; return; }
    sleep 5
  done
  echo "No load balancer address for service $1 after 5 minutes" >&2
  exit 1
}

FRONTEND="http://$(lb frontend):4200"
AUTH="http://$(lb auth-service):3000"
ORDERS="http://$(lb order-service):8085"

kubectl -n "$NS" patch configmap trading-config --type merge -p \
  "{\"data\":{\"AUTH_URL\":\"$AUTH\",\"BACKEND_URL\":\"$ORDERS\",\"CORS_ALLOWED_ORIGINS\":\"$FRONTEND\"}}"

# Pods read the ConfigMap only at start.
kubectl -n "$NS" rollout restart deployment/frontend deployment/order-service
kubectl -n "$NS" rollout status deployment/frontend deployment/order-service --timeout=5m

echo
echo "Open:          $FRONTEND"
echo "Auth service:  $AUTH/docs"
echo "Order service: $ORDERS/health"
