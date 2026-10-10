#!/usr/bin/env bash
# Writes the load balancer addresses into the overlay's urls.env and applies it.
# Load balancer hostnames exist only after AWS has created them, so this runs
# after the first `kubectl apply -k`.
#
#   deploy/set-urls.sh            approach 1: four load balancers
#   deploy/set-urls.sh ingress    approach 2: one ALB (only fills in CORS)
#
# Run from the Application folder. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-four-elb}"
NS="$(awk '/^namespace:/{print $2}' k8s/base/kustomization.yaml)"
AUTH_PORT="${AUTH_PORT:-3000}"      # the auth Service's port   (k8s/base/auth-service.yaml)
ORDER_PORT="${ORDER_PORT:-8081}"    # the order Service's port  (k8s/base/order-service.yaml)

host() {   # host <kind> <name>: waits up to 5 minutes for AWS to assign a hostname
  for _ in $(seq 60); do
    h="$(kubectl -n "$NS" get "$1" "$2" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$h" ] && { echo "$h"; return; }
    sleep 5
  done
  echo "no address for $1/$2 after 5 minutes: kubectl -n $NS describe $1 $2" >&2; exit 1
}

if [ "$MODE" = ingress ]; then
  PAGE="http://$(host ingress app)"
  OVERLAY=k8s/overlays/2-ingress
  cat > "$OVERLAY/urls.env" <<ENV
# Written by deploy/set-urls.sh ingress
BROWSER_AUTH_URL=
BROWSER_ORDER_URL=
CORS_ALLOWED_ORIGINS=$PAGE
FRONTEND_URL=$PAGE
COOKIE_SECURE=false
ENV
else
  PAGE="http://$(host service frontend)"
  AUTH="http://$(host service auth-service):$AUTH_PORT"
  ORDER="http://$(host service order-service):$ORDER_PORT"
  OVERLAY=k8s/overlays/1-four-elb
  cat > "$OVERLAY/urls.env" <<ENV
# Written by deploy/set-urls.sh
BROWSER_AUTH_URL=$AUTH
BROWSER_ORDER_URL=$ORDER
CORS_ALLOWED_ORIGINS=$PAGE
FRONTEND_URL=$PAGE
COOKIE_SECURE=false
ENV
fi
cat "$OVERLAY/urls.env"
# A changed ConfigMap gets a new name, so this restarts the pods that read it.
kubectl apply -k "$OVERLAY"
kubectl -n "$NS" rollout status deployment --timeout=10m
echo; echo "Open: $PAGE   (a new load balancer can take 2-3 minutes to answer)"
