#!/bin/bash
# Deploy ETP-testing's own k8s-tester/ (phase 1: four Services) and then k8s-ingress/ (phase 2:
# one Ingress) on the local k3s, from origin/main. AWS-only parts are swapped as in k8s-test.sh:
# ECR -> localhost:30500, gp3 -> local-path, alb -> nginx, RDS -> a postgres:17 pod with SSL on.
# Results in etp-k8s/ and etp-k8s.txt.
S=$(cd "$(dirname "$0")" && pwd); A=$(dirname "$S")
export CONTAINERS_REGISTRIES_CONF=$S/registries.conf
REG=localhost:30500; ING=http://localhost:30080; NS=tester
ECR=323187579619.dkr.ecr.ap-south-1.amazonaws.com
OUT=$S/etp-k8s; T=$OUT/tree; rm -rf $OUT; mkdir -p $T
log() { echo "$*" | tee -a $S/etp-k8s.txt; }
: > $S/etp-k8s.txt
git -C $A/ETP-testing archive origin/main | tar -x -C $T
log "ETP-testing origin/main $(git -C $A/ETP-testing rev-parse --short origin/main)"
chcon -R -t container_file_t $OUT 2>/dev/null

# Images, built from the same contexts as the root docker-compose.yml
: > $OUT/build.txt
for pair in trading-auth-service:sprint8-auth-service trading-trade-api:sprint8 trading-executor:executor trading-frontend:sprint8/front-end; do
  n=${pair%%:*}; ctx=${pair#*:}; t0=$(date +%s)
  timeout 1800 podman build -q --format docker -t $REG/$n:1.0 $T/$ctx > $OUT/build-$n.log 2>&1 \
    && podman push -q --tls-verify=false $REG/$n:1.0 >> $OUT/build-$n.log 2>&1
  echo "$n rc=$? $(( $(date +%s)-t0 ))s" >> $OUT/build.txt
done
log "build: $(tr '\n' ' ' < $OUT/build.txt)"
grep -q "rc=[1-9]" $OUT/build.txt && { log "BUILD FAILED"; exit 1; }

K=$T/k8s-tester
sed -i "s|$ECR|$REG|" $K/*-deployment.yaml
sed -i 's/storageClassName: gp3/storageClassName: local-path/' $K/*.yaml
sed -i '/- storageclass.yaml/d' $K/kustomization.yaml
sed -i 's/^\(  DB_HOST:\).*/\1 postgres/' $K/configmap.yaml
sed -i 's/ingressClassName: alb/ingressClassName: nginx/; /alb\.ingress\.kubernetes\.io/d' $T/k8s-ingress/ingress.yaml

kubectl delete namespace $NS --timeout=3m > /dev/null 2>&1
kubectl apply -f $K/namespace.yaml > /dev/null
PW=pg-test-$(openssl rand -hex 8)
# README step 4: the runtime secret. No pull secret: the local registry needs none.
kubectl -n $NS create secret generic trading-secrets --from-literal=db-password=$PW \
  --from-literal=jwt-secret=$(openssl rand -hex 32) --from-literal=fauxnance-api-key=test-key > /dev/null
# README step 1: RDS with sprint8/db/schema.sql and seed-data.sql applied once
kubectl -n $NS create configmap db-init --from-file=01-schema.sql=$T/sprint8/db/schema.sql \
  --from-file=02-seed.sql=$T/sprint8/db/seed-data.sql > /dev/null
DBN=$(awk '/DB_NAME:/{print $2}' $K/configmap.yaml); DBU=$(awk '/DB_USER:/{print $2}' $K/configmap.yaml)
kubectl -n $NS apply -f - > /dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: postgres}
spec:
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
        - name: postgres
          image: postgres:17
          command: [sh, -c, "exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key"]
          env:
            - {name: POSTGRES_DB, value: "$DBN"}
            - {name: POSTGRES_USER, value: "$DBU"}
            - {name: POSTGRES_PASSWORD, value: "$PW"}
          readinessProbe:
            exec: {command: [sh, -c, "pg_isready -h 127.0.0.1 -U $DBU -d $DBN"]}
            periodSeconds: 5
          volumeMounts: [{name: init, mountPath: /docker-entrypoint-initdb.d}]
      volumes: [{name: init, configMap: {name: db-init}}]
---
apiVersion: v1
kind: Service
metadata: {name: postgres}
spec:
  selector: {app: postgres}
  ports: [{port: 5432, targetPort: 5432}]
EOF
kubectl -n $NS rollout status deploy/postgres --timeout=5m > /dev/null 2>&1
sleep 5; kubectl -n $NS logs deploy/postgres > $OUT/log-postgres.txt 2>&1
log "postgres: $(grep -c 'ERROR' $OUT/log-postgres.txt) errors while loading schema+seed"

pods() { kubectl -n $NS get pods --no-headers 2>/dev/null | awk '{print $1"="$2"/"$3"/r"$4}' | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}=/=/' | sort | tr '\n' ' '; }
wait_all() {
  for d in frontend auth-service order-service trade-executor; do
    kubectl -n $NS rollout status deploy/$d --timeout=8m > /dev/null 2>&1 &
  done
  kubectl -n $NS rollout status statefulset/kafka --timeout=8m > /dev/null 2>&1 &
  wait
  kubectl -n $NS wait --for=condition=complete job/kafka-topics --timeout=5m > /dev/null 2>&1
}
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1"; }

# ---- phase 1: k8s-tester as the README says, checked through port-forwards
kubectl apply -k $K > $OUT/apply-tester.log 2>&1 || log "apply -k k8s-tester FAILED: $(tail -2 $OUT/apply-tester.log)"
wait_all
log "phase 1 pods: $(pods)"
log "phase 1 jobs: $(kubectl -n $NS get jobs --no-headers | awk '{print $1"="$2}')"
kubectl -n $NS port-forward service/frontend 14200:4200 > /dev/null 2>&1 & p1=$!
kubectl -n $NS port-forward service/auth-service 13000:3000 > /dev/null 2>&1 & p2=$!
kubectl -n $NS port-forward service/order-service 18085:8085 > /dev/null 2>&1 & p3=$!
sleep 4
log "phase 1 port-forward: frontend /=$(code http://localhost:14200/) auth /docs/json=$(code http://localhost:13000/docs/json) order /health=$(code http://localhost:18085/health) order /api/v1/accounts/1=$(code http://localhost:18085/api/v1/accounts/1)"
kill $p1 $p2 $p3 2>/dev/null
kubectl -n $NS get svc > $OUT/svc-phase1.txt

# ---- phase 2: k8s-ingress (Services internal, one Ingress), checked through the ingress
kubectl apply -k $T/k8s-ingress > $OUT/apply-ingress.log 2>&1 || log "apply -k k8s-ingress FAILED: $(tail -2 $OUT/apply-ingress.log)"
kubectl -n $NS rollout restart deployment/frontend deployment/order-service > /dev/null
kubectl -n $NS rollout status deployment/frontend --timeout=5m > /dev/null 2>&1
kubectl -n $NS rollout status deployment/order-service --timeout=5m > /dev/null 2>&1
sleep 5
log "phase 2 services: $(kubectl -n $NS get svc --no-headers | awk '{print $1"="$2}' | tr '\n' ' ')"
log "phase 2 ingress: $(kubectl -n $NS get ingress trading --no-headers 2>&1 | tr -s ' ')"
body=$(curl -s -m 10 $ING/); page=$(echo "$body" | grep -qi "<app-root\|<!doctype html" && echo html || echo not-html)
log "phase 2 via ingress: /=$(code $ING/) ($page) /auth/docs/json=$(code $ING/auth/docs/json) /auth/me=$(code $ING/auth/me) /api/v1/accounts/1=$(code $ING/api/v1/accounts/1)"
log "phase 2 pods: $(pods)"
for d in frontend auth-service order-service trade-executor; do kubectl -n $NS logs deploy/$d --tail=200 > $OUT/log-$d.txt 2>&1; done
kubectl -n $NS logs statefulset/kafka --tail=100 > $OUT/log-kafka.txt 2>&1
kubectl -n $NS logs job/kafka-topics > $OUT/log-kafka-topics.txt 2>&1
kubectl -n $NS get events --sort-by=.lastTimestamp > $OUT/events.txt 2>&1
[ -n "$KEEP" ] || kubectl delete namespace $NS --timeout=3m > /dev/null 2>&1
log ETPDONE
