#!/bin/sh
set -u
BASE=/home/container/lab/remote-stack
while :; do
  sleep 90
  MCBRIDGE_WATCHDOG_CHILD=1 sh "$BASE/start.sh" >>"$BASE/watchdog-actions.log" 2>&1 || \
    echo "SERVICE_WATCHDOG_RETRY_FAILED"
done
