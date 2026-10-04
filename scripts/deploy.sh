#!/usr/bin/env bash
# Roll the cluster to one image tag: k8s-ingress/ with the four images
# pinned to <tag>. Kubernetes replaces only the pods whose image changed.
#
#   ./scripts/deploy.sh <tag>
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pipeline-env.sh
TAG="${1:?usage: deploy.sh <tag>}"
REGISTRY="${REGISTRY:-$(registry)}"
# Keep the trade API's allowed origin on the live address across re-applies.
HOST="${INGRESS_HOST-$(kubectl -n "$NS" get ingress trading -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)}"

OVERLAY=build/deploy
rm -rf "$OVERLAY"; mkdir -p "$OVERLAY"
{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  echo "  - ../../k8s-ingress"
  echo "images:"
  for entry in "${IMAGES[@]}"; do
    echo "  - name: ${REGISTRY}/${entry%%:*}"
    echo "    newTag: \"${TAG}\""
  done
  if [ -n "$HOST" ]; then
    echo "patches:"
    echo "  - target: {kind: ConfigMap, name: trading-config}"
    echo "    patch: |-"
    echo "      - {op: replace, path: /data/CORS_ALLOWED_ORIGINS, value: \"http://${HOST}\"}"
  fi
} > "$OVERLAY/kustomization.yaml"

[ "${RENDER_ONLY:-}" = 1 ] && { kubectl kustomize "$OVERLAY"; exit 0; }

kubectl apply -k "$OVERLAY"
for d in auth-service order-service trade-executor frontend; do
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=10m
done
kubectl -n "$NS" get pods -o wide
