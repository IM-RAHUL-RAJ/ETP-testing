#!/bin/bash
# One-time setup on the local k3s for k8s-test.sh:
#   - a plain image registry on localhost:30500 (k3s pulls from localhost over HTTP; no root needed)
#   - ingress-nginx (bare-metal, NodePort) standing in for the AWS Load Balancer Controller
set -euo pipefail
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: k8s-test-infra
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: k8s-test-infra
spec:
  replicas: 1
  selector:
    matchLabels: {app: registry}
  template:
    metadata:
      labels: {app: registry}
    spec:
      containers:
        - name: registry
          image: registry:2.8.3
          ports: [{containerPort: 5000}]
          env:
            - {name: REGISTRY_STORAGE_DELETE_ENABLED, value: "true"}
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: k8s-test-infra
spec:
  type: NodePort
  selector: {app: registry}
  ports:
    - {port: 5000, targetPort: 5000, nodePort: 30500}
EOF
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx patch svc ingress-nginx-controller --type merge \
  -p '{"spec":{"ports":[{"name":"http","port":80,"protocol":"TCP","targetPort":"http","nodePort":30080},{"name":"https","port":443,"protocol":"TCP","targetPort":"https","nodePort":30443}]}}'
kubectl -n k8s-test-infra rollout status deploy/registry --timeout=5m
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5m
curl -sf http://localhost:30500/v2/ >/dev/null && echo "registry: localhost:30500 ok"
echo "ingress: http://localhost:30080"
