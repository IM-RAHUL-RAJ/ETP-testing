#!/bin/bash
# Take teams from queue.txt one at a time (shared by the workers) and run each.
# A build that failed on the network (DNS, timeout, rate limit) goes back to the queue, at most twice.
S=$(cd "$(dirname "$0")" && pwd); SLOT=${1:-1}
while true; do
  id=$(flock $S/queue.lock sh -c 'id=$(head -1 '"$S"'/queue.txt); [ -n "$id" ] && sed -i 1d '"$S"'/queue.txt; echo $id')
  [ -z "$id" ] && break
  SLOT=$SLOT NOALLDONE=1 bash $S/runall.sh $id >> $S/worker$SLOT.log 2>&1
  if tail -1 $S/runall.txt | grep -q "^$id|BUILD FAILED" && \
     grep -qiE "DNS: transient|EAI_AGAIN|ENOTFOUND|ETIMEDOUT|ECONNRESET|toomanyrequests|Temporary failure in name resolution|Could not transfer artifact" $S/run/$id/build-*.log; then
    n=$(grep -c "^$id$" $S/netretry.txt 2>/dev/null)
    if [ "${n:-0}" -lt 2 ]; then echo $id >> $S/netretry.txt; echo $id >> $S/queue.txt; echo "$(date +%H:%M) network retry $id" >> $S/progress.txt; fi
  fi
done
echo "worker $SLOT done" >> $S/progress.txt
