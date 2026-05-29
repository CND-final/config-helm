#!/bin/bash
# watch-health.sh — Continuous end-to-end health probe for HA demo
#
# Hits the frontend NodePort (30080), which proxies /api to the backend.
# A single 200 here proves the whole chain is alive:
#   nginx (frontend) -> proxy -> backend -> (DB if health checks it)
#
# Run this side-by-side with `kubectl get pods -n config-man -w`,
# then delete a pod in a third terminal and watch this stay UP.

URL="http://localhost:30080/api/v1/health"
INTERVAL=1

up_count=0
down_count=0

echo "Probing $URL every ${INTERVAL}s  (Ctrl-C to stop)"
echo "------------------------------------------------------------"

while true; do
  TS=$(date +%H:%M:%S)
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$URL" 2>/dev/null)

  if [ "$CODE" = "200" ]; then
    up_count=$((up_count + 1))
    printf "%s  \033[32m✅ UP  \033[0m (HTTP %s)   up=%d down=%d\n" "$TS" "$CODE" "$up_count" "$down_count"
  else
    down_count=$((down_count + 1))
    # curl returns 000 when it can't connect at all
    printf "%s  \033[31m❌ DOWN\033[0m (HTTP %s)   up=%d down=%d\n" "$TS" "$CODE" "$up_count" "$down_count"
  fi

  sleep "$INTERVAL"
done
