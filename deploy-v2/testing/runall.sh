#!/bin/bash
# Run each team's stack with the handover kit's own docker-compose.yml (images built by podman).
# Usage: runall.sh [team ids...]   results in run/<id>/ and runall.txt
S=$(cd "$(dirname "$0")" && pwd); A=$(dirname "$S")
export CONTAINERS_REGISTRIES_CONF=$S/registries.conf DOCKER_HOST=unix://$S/pd.sock
DC=$S/bin/docker-compose
ids=${@:-$(cut -f1 $S/teams.tsv)}
for id in $ids; do
  OUT=$S/run/$id; D=$OUT/deploy; rm -rf $OUT; mkdir -p $OUT
  echo "$(date +%H:%M) start $id" >> $S/progress.txt
  cp -r $A/handover/kit/deploy $D; chcon -R -t container_file_t $OUT 2>/dev/null;
  # SLOT=2: a second worker on the same machine; publish every host port with a leading 1.
  if [ "${SLOT:-1}" = 2 ]; then sed -i -E 's/- "(5432|8025|1025):/- "1\1:/; s/- "\$\{(KAFKA_HOST_PORT:-9092|AUTH_PORT|ORDER_PORT|EXECUTOR_PORT|FRONTEND_PORT)\}:/- "1${\1}:/' $D/docker-compose.yml; fi
  cp $A/handover/teams/$id/project.yaml $A/handover/teams/$id/application.yaml $D/config/
  python3 -I - "$D/config/project.yaml" "$S/trees/$id" <<'EOF'
import sys, yaml
p = yaml.safe_load(open(sys.argv[1])); p["root"] = sys.argv[2]
yaml.safe_dump(p, open(sys.argv[1], "w"), sort_keys=False)
EOF
  ( cd $D && python3 config/apply.py docker ) > $OUT/apply.log 2>&1 || { echo "$id|APPLY FAILED|$(tail -2 $OUT/apply.log | tr '\n' ' ')" >> $S/runall.txt; continue; }
  python3 -I - "$D/.env" <<'EOF'
import sys
p=sys.argv[1]; L=open(p).read().splitlines(); out=[]
for l in L:
    if "=" in l and not l.startswith("#"):
        k,v=l.split("=",1)
        if v in ("",'""'):
            if "SECRET" in k or k.endswith("TOKEN") or k.endswith("_KEY") and "API" not in k: v="test-secret-0123456789-abcdefghijklmnopqrstuvwxyz"
            elif "PASSWORD" in k: v="TestPass123"
            elif k.endswith("API_KEY"): v="test-key"
        l=f"{k}={v}"
    out.append(l)
open(p,"w").write("\n".join(out)+"\n")
EOF
  [ -f $S/overrides/$id.yml ] && cp $S/overrides/$id.yml $D/docker-compose.override.yml
  set -a; . $D/.env; set +a
  : > $OUT/build.txt
  for pair in FRONTEND:frontend AUTH:auth-service ORDER:order-service EXECUTOR:executor-service; do
    r=${pair%%:*}; n=${pair##*:}; v() { local x=${r}_$1; echo "${!x}"; }
    t0=$(date +%s)
    timeout 1800 podman build -q --format docker --pull=missing -f $D/docker/$(v TYPE).Dockerfile \
      --build-arg RUNTIME_VERSION="$(v VERSION)" --build-arg APP_PORT="$(v LISTEN)" --build-arg HEALTH_PATH="$(v HEALTH)" \
      --build-arg MODULE="$(v MODULE)" --build-arg PREBUILD="$(v PREBUILD)" --build-arg START_CMD="$(v START)" \
      --build-arg APP_ENTRY="$(v START)" --build-arg MAIN_CLASS="$(v MAIN_CLASS)" \
      -t docker.io/library/${IMAGE_PREFIX}-$n:latest -t localhost/${IMAGE_PREFIX}-$n:latest "$PROJECT_DIR/$(v CONTEXT)" > $OUT/build-$n.log 2>&1
    echo "$n rc=$? $(( $(date +%s)-t0 ))s" >> $OUT/build.txt
  done
  if grep -q "rc=[1-9]" $OUT/build.txt; then
    echo "$id|BUILD FAILED|$(grep 'rc=[1-9]' $OUT/build.txt | cut -d' ' -f1 | tr '\n' ' ')" >> $S/runall.txt
  else
    ( cd $D && timeout 600 $DC up -d --no-build ) > $OUT/up.log 2>&1; uprc=$?
    for i in $(seq 60); do
      jl=$(for c in $(cd $D && $DC ps -q order-service executor-service 2>/dev/null); do podman logs $c 2>&1 | grep -cE "Started [A-Za-z]+ in|APPLICATION FAILED|Exception in thread \"main\""; done | tr '\n' ' ')
      case "$jl" in *0*) sleep 5 ;; *) break ;; esac
    done
    sleep 20
    st=$(cd $D && $DC ps -a --format '{{.Service}}={{.State}}' 2>/dev/null | sort | tr '\n' ' ')
    P=http://127.0.0.1:$([ "${SLOT:-1}" = 2 ] && echo 1)$FRONTEND_PORT
    authp=$(python3 -c "import yaml;p=yaml.safe_load(open('$D/config/project.yaml'));print((p.get('kubernetes',{}).get('routes',{}).get('auth') or ['/auth'])[0])")
    apip=$(python3 -c "import yaml;p=yaml.safe_load(open('$D/config/project.yaml'));print((p.get('kubernetes',{}).get('routes',{}).get('order') or ['/api'])[0])")
    chk() { local body; body=$(curl -s -m 10 -w '\n%{http_code}' "$P$1"); local c=${body##*$'\n'}; if [ "$1" != / ] && [ "$c" = 200 ] && echo "$body" | grep -qi "<app-root\|<!doctype html"; then echo PAGE; else echo $c; fi; }
    apiu=$apip/v1/accounts/1; case "$apip" in */v1) apiu=$apip/accounts/1 ;; esac
    codes="/=$(chk /) $authp/me=$(chk $authp/me) $apiu=$(chk $apiu)"
    fc=$(cd $D && $DC ps -q frontend 2>/dev/null); [ -n "$fc" ] && podman exec $fc cat /etc/nginx/proxy-routes.inc > $OUT/proxy-routes.txt 2>&1
    pl=$(cd $D && $DC logs postgres 2>/dev/null); echo "$pl" > $OUT/log-postgres.txt
    if echo "$pl" | grep -q "== SQL loaded"; then sql=loaded; elif echo "$pl" | grep -q "SQL path not found"; then sql="FAILED: $(echo "$pl" | grep -m1 'SQL path not found' | sed 's/.*SQL path/SQL path/')"; elif echo "$pl" | grep -qE "(^|\| )== "; then sql="FAILED: $(echo "$pl" | grep -m1 'ERROR:' | sed 's/.*ERROR:/ERROR:/' | cut -c1-110)"; else sql="none (services make their own)"; fi
    errs=""
    for svc in auth-service order-service executor-service frontend; do
      c=$(cd $D && $DC ps -aq $svc 2>/dev/null); [ -z "$c" ] && continue
      podman logs $c > $OUT/log-$svc.txt 2>&1
      s=$(podman inspect -f '{{.State.Status}}' $c)
      # A crash loop shows "running" between restarts: count restarts and start failures too.
      rc=$(podman inspect -f '{{.RestartCount}}' $c 2>/dev/null)
      if [ "$s" != running ] || [ "${rc:-0}" -gt 0 ] || grep -qE "APPLICATION FAILED TO START|Application run failed" $OUT/log-$svc.txt; then errs="$errs $svc: $(grep -E 'Caused by|Error:|ERROR|Exception|error' $OUT/log-$svc.txt | grep -v -i 'warn' | tail -1 | cut -c1-160);"; fi
    done
    echo "$id|up=$uprc|$st|$codes|sql: ${sql:-?}|$errs" >> $S/runall.txt
    ( cd $D && $DC down -v --remove-orphans ) > /dev/null 2>&1
  fi
  podman rmi -f localhost/${IMAGE_PREFIX}-frontend localhost/${IMAGE_PREFIX}-auth-service localhost/${IMAGE_PREFIX}-order-service localhost/${IMAGE_PREFIX}-executor-service >/dev/null 2>&1
  podman rmi -f docker.io/library/${IMAGE_PREFIX}-frontend docker.io/library/${IMAGE_PREFIX}-auth-service docker.io/library/${IMAGE_PREFIX}-order-service docker.io/library/${IMAGE_PREFIX}-executor-service >/dev/null 2>&1
  podman image prune -f >/dev/null 2>&1
done
[ -z "${NOALLDONE:-}" ] && echo ALLDONE >> $S/runall.txt
