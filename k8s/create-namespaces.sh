#!/bin/sh
set -eu

for team_number in $(seq -w 1 30); do
  team_namespace="team-${team_number}"
  kubectl create namespace "$team_namespace" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$team_namespace" -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-capacity
spec:
  hard:
    pods: "35"
    requests.cpu: "3"
    requests.memory: 8Gi
    limits.cpu: "12"
    limits.memory: 20Gi
    persistentvolumeclaims: "5"
    requests.storage: 10Gi
EOF
done