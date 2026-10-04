#!/usr/bin/env bash
# Prove the deployed application answers through the load balancer:
# the page, the auth service and the trade API, each by its Ingress path.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pipeline-env.sh
HOST="$(kubectl -n "$NS" get ingress trading -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
[ -n "$HOST" ] || { echo "Ingress has no address" >&2; exit 1; }
BASE="http://$HOST"

check() {  # name, path, expected status
  local code=""
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$BASE$2" || true)"
    [ "$code" = "$3" ] && { echo "ok    $1  $2 -> $code"; return; }
    sleep 10
  done
  echo "FAIL  $1  $2 -> $code (wanted $3)" >&2
  return 1
}

check frontend      /                     200
check auth-service  /auth/public-key      200
# No token, so the trade API must refuse: proves the route and its login check.
check trade-api     /api/v1/accounts/1    401
echo "Smoke test passed: $BASE"
