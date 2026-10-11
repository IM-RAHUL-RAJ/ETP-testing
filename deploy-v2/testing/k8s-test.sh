#!/bin/bash
# Deploy each team with the kit's own Kubernetes files (apply.py eks) on the local k3s and test it
# through the ingress, as the class will on EKS. Run k8s-setup.sh once first.
# Only the AWS-specific parts are swapped: images go to localhost:30500 instead of ECR, the ingress
# class is nginx instead of alb, Kafka's volume uses local-path instead of gp3, and a Postgres pod
# (loaded with the team's SQL by the kit's postgres-init.sh) stands in for RDS.
# Usage: k8s-test.sh [team ids...]   results in k8srun/<id>/ and k8sall.txt
S=$(cd "$(dirname "$0")" && pwd); A=$(dirname "$S")
export CONTAINERS_REGISTRIES_CONF=$S/registries.conf
REG=localhost:30500; ING=http://localhost:30080
ids=${@:-$(cut -f1 $S/teams.tsv)}
# K8SQUEUE=1: take ids one by one from k8squeue.txt, which several workers share
Q=$S/k8squeue.txt; [ -n "$K8SQUEUE" ] || { Q=$S/k8squeue-$$.txt; printf '%s\n' $ids > $Q; }
next_id() { flock $S/k8squeue.lock sh -c "head -1 $Q; sed -i 1d $Q"; }
while id=$(next_id); [ -n "$id" ]; do
  # K8SCONFIG=1: mount the files from overrides/<id>.yml as ConfigMaps (results as <id>+configmap)
  tag=$id; [ -n "$K8SCONFIG" ] && tag=$id+configmap
  OUT=$S/k8srun/$tag; D=$OUT/deploy; rm -rf $OUT; mkdir -p $OUT
  echo "$(date +%H:%M) k8s start $id" >> $S/progress.txt
  cp -r $A/handover/kit/deploy $D; chcon -R -t container_file_t $OUT 2>/dev/null
  cp $A/handover/teams/$id/project.yaml $A/handover/teams/$id/application.yaml $D/config/
  python3 -I - "$D/config/project.yaml" "$S/trees/$id" "$REG" <<'EOF'
import sys, yaml
p = yaml.safe_load(open(sys.argv[1])); p["root"] = sys.argv[2]
p.setdefault("kubernetes", {})["registry"] = sys.argv[3]
yaml.safe_dump(p, open(sys.argv[1], "w"), sort_keys=False)
EOF
  # docker phase first: build settings and the secrets in .env; then eks: k8s/ and secrets.env
  ( cd $D && python3 config/apply.py docker && python3 config/apply.py eks ) > $OUT/apply.log 2>&1 \
    || { echo "$id|APPLY FAILED|$(tail -2 $OUT/apply.log | tr '\n' ' ')" >> $S/k8sall.txt; continue; }
  python3 -I - "$D/secrets.env" <<'EOF'
import sys
p=sys.argv[1]; out=[]
for l in open(p).read().splitlines():
    k,_,v=l.partition("=")
    if not v:
        v = "test-key" if "API" in k else "test-secret-0123456789-abcdefghijklmnopqrstuvwxyz"
    out.append(f"{k}={v}")
open(p,"w").write("\n".join(out)+"\n")
EOF
  set -a; . $D/.env; set +a
  NS=$PROJECT_NAME
  : > $OUT/build.txt
  for pair in FRONTEND:frontend AUTH:auth-service ORDER:order-service EXECUTOR:executor-service; do
    r=${pair%%:*}; n=${pair##*:}; v() { local x=${r}_$1; echo "${!x}"; }
    img=$REG/${IMAGE_PREFIX}-$n:1.0; t0=$(date +%s)
    for try in 1 2; do timeout 1800 podman build -q --format docker --pull=missing -f $D/docker/$(v TYPE).Dockerfile \
      --build-arg RUNTIME_VERSION="$(v VERSION)" --build-arg APP_PORT="$(v LISTEN)" --build-arg HEALTH_PATH="$(v HEALTH)" \
      --build-arg MODULE="$(v MODULE)" --build-arg PREBUILD="$(v PREBUILD)" --build-arg START_CMD="$(v START)" \
      --build-arg APP_ENTRY="$(v START)" --build-arg MAIN_CLASS="$(v MAIN_CLASS)" \
      -t $img "$PROJECT_DIR/$(v CONTEXT)" > $OUT/build-$n.log 2>&1 \
      && podman push -q --tls-verify=false $img >> $OUT/build-$n.log 2>&1; rc=$?; [ $rc = 0 ] && break; done
    echo "$n rc=$rc try=$try $(( $(date +%s)-t0 ))s" >> $OUT/build.txt
  done
  if grep -q "rc=[1-9]" $OUT/build.txt; then
    echo "$id|BUILD FAILED|$(grep 'rc=[1-9]' $OUT/build.txt | cut -d' ' -f1 | tr '\n' ' ')" >> $S/k8sall.txt
    continue
  fi
  # Two teams at a time on the cluster (memory). Each team's Ingress gets its own host name so their
  # paths do not collide on the shared nginx; the checks send that Host header.
  while :; do for slot in "" .2; do exec 9>$S/k8s.lock$slot; flock -n 9 && break 2; exec 9>&-; done; sleep 10; done
  # AWS-only parts -> local equivalents
  K=$D/k8s
  sed -i 's/ingressClassName: alb/ingressClassName: nginx/; /alb\.ingress\.kubernetes\.io/d' $K/ingress.yaml
  sed -i 's/storageClassName: gp3/storageClassName: local-path/' $K/*.yaml
  # Docker Hub keeps refusing pulls tonight: mailpit comes from the local registry (same version).
  sed -i "s|image: axllent/mailpit:.*|image: $REG/axllent/mailpit:v1.31.4|" $K/*.yaml
  sed -i '/- storageclass.yaml/d' $K/kustomization.yaml
  sed -i "s/^    - http:/    - host: $NS.k3s.local\n      http:/" $K/ingress.yaml
  kubectl create namespace $NS > /dev/null 2>&1
  kubectl -n $NS create secret generic app-secrets --from-env-file=$D/secrets.env > $OUT/secret.log 2>&1
  # Postgres in place of RDS, loaded the same way as in docker-compose
  kubectl -n $NS create configmap postgres-init --from-file=00-load.sh=$D/docker/postgres-init.sh > /dev/null
  PW=$(printenv "$DB_PASSWORD_ENV"); [ -z "$PW" ] && PW=$(grep "^$DB_PASSWORD_ENV=" $D/secrets.env | cut -d= -f2-)
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
            - {name: POSTGRES_DB, value: "$DB_NAME"}
            - {name: POSTGRES_USER, value: "$DB_USER"}
            - {name: POSTGRES_PASSWORD, value: "$PW"}
            - {name: SQL_PATHS, value: "$DB_SQL"}
            - {name: SQL_VARS, value: "$DB_SQL_VARS"}
          ports: [{containerPort: 5432}]
          readinessProbe:
            exec: {command: [sh, -c, "pg_isready -h 127.0.0.1 -U $DB_USER -d $DB_NAME"]}
            periodSeconds: 5
          volumeMounts:
            - {name: project, mountPath: /project, readOnly: true}
            - {name: init, mountPath: /docker-entrypoint-initdb.d}
      volumes:
        - {name: project, hostPath: {path: "$PROJECT_DIR", type: Directory}}
        - {name: init, configMap: {name: postgres-init, defaultMode: 0755}}
---
apiVersion: v1
kind: Service
metadata: {name: postgres}
spec:
  selector: {app: postgres}
  ports: [{port: 5432, targetPort: 5432}]
EOF
  kubectl -n $NS rollout status deploy/postgres --timeout=5m > /dev/null 2>&1
  if [ -n "$K8SCONFIG" ] && [ -f $S/overrides/$id.yml ]; then
    python3 $S/k8s-configmount.py $S/overrides/$id.yml $K $NS > $OUT/configmaps.sh && bash $OUT/configmaps.sh > $OUT/configmaps.log 2>&1
  fi
  kubectl apply -k $K > $OUT/apply-k.log 2>&1
  for n in frontend auth-service order-service executor-service; do
    kubectl -n $NS rollout status deploy/$n --timeout=8m > /dev/null 2>&1 &
  done; wait
  sleep 10
  st=$(kubectl -n $NS get pods --no-headers 2>/dev/null | awk '{split($1,a,"-[a-z0-9]+-[a-z0-9]+$"); print a[1]"="$2"/"$3"/r"$4}' | sort | tr '\n' ' ')
  authp=$(python3 -c "import yaml;p=yaml.safe_load(open('$D/config/project.yaml'));print((p.get('kubernetes',{}).get('routes',{}).get('auth') or ['/auth'])[0])")
  apip=$(python3 -c "import yaml;p=yaml.safe_load(open('$D/config/project.yaml'));print((p.get('kubernetes',{}).get('routes',{}).get('order') or ['/api'])[0])")
  chk() { local body; body=$(curl -s -m 10 -H "Host: $NS.k3s.local" -w '\n%{http_code}' "$ING$1"); local c=${body##*$'\n'}; if [ "$1" != / ] && [ "$c" = 200 ] && echo "$body" | grep -qi "<app-root\|<!doctype html"; then echo PAGE; else echo $c; fi; }
  apiu=$apip/v1/accounts/1; case "$apip" in */v1) apiu=$apip/accounts/1 ;; esac
  codes="/=$(chk /) $authp/me=$(chk $authp/me) $apiu=$(chk $apiu)"
  kubectl -n $NS logs deploy/postgres > $OUT/log-postgres.txt 2>&1
  if grep -q "== SQL loaded" $OUT/log-postgres.txt; then sql=loaded; elif grep -q "SQL path not found" $OUT/log-postgres.txt; then sql="FAILED: $(grep -m1 "SQL path not found" $OUT/log-postgres.txt)"; elif grep -q "^== " $OUT/log-postgres.txt; then sql="FAILED: $(grep -m1 'ERROR:' $OUT/log-postgres.txt | sed 's/.*ERROR:/ERROR:/' | cut -c1-100)"; else sql="none (services make their own)"; fi
  for n in frontend auth-service order-service executor-service; do
    kubectl -n $NS logs deploy/$n --all-containers --tail=300 > $OUT/log-$n.txt 2>&1
  done
  kubectl -n $NS get events --sort-by=.lastTimestamp > $OUT/events.txt 2>&1
  kubectl -n $NS get ingress app -o wide > $OUT/ingress.txt 2>&1
  echo "$tag|$st|$codes|sql: $sql" >> $S/k8sall.txt
  kubectl delete namespace $NS --timeout=3m > /dev/null 2>&1
  flock -u 9; exec 9>&-
  podman rmi -f $REG/${IMAGE_PREFIX}-frontend:1.0 $REG/${IMAGE_PREFIX}-auth-service:1.0 $REG/${IMAGE_PREFIX}-order-service:1.0 $REG/${IMAGE_PREFIX}-executor-service:1.0 >/dev/null 2>&1
  podman image prune -f >/dev/null 2>&1
done
[ -n "$NOALLDONE" ] || echo K8SDONE >> $S/k8sall.txt
