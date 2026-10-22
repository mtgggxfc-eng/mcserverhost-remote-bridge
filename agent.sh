#!/bin/sh
# Outbound-only remote command agent, /bin/sh + curl + base64
set -u
umask 077
: "${RELAY_URL:?Set RELAY_URL to your HTTPS relay URL}"
: "${AGENT_TOKEN:?Set AGENT_TOKEN for this paired agent}"
RELAY_URL=${RELAY_URL%/}
case "$RELAY_URL" in https://*) ;; *) echo 'RELAY_URL must use https://' >&2; exit 2;; esac
command -v curl >/dev/null || exit 2
command -v base64 >/dev/null || exit 2
AGENT_DATA_DIR=${AGENT_DATA_DIR:-/home/container/lab/remote-agent}
COMMAND_WORKDIR=${COMMAND_WORKDIR:-/home/container}
mkdir -p "$AGENT_DATA_DIR" || exit 2
cd "$COMMAND_WORKDIR" || exit 2
echo 'MCBridge agent started: polling remote tasks.'
while :; do
    response=$(curl -fsS --connect-timeout 8 --max-time 20 -H "X-Agent-Token: $AGENT_TOKEN" "$RELAY_URL/v1/agent/next" 2>/dev/null) || { sleep 5; continue; }
    [ -n "$response" ] || { sleep 3; continue; }
    IFS='|' read -r job_id command_b64 timeout_secs <<EOF
$response
EOF
    case "$job_id" in *[!a-f0-9]*|'') sleep 3; continue;; esac
    case "$timeout_secs" in *[!0-9]*|'') timeout_secs=40;; esac
    command_text=$(printf %s "$command_b64" | base64 -d 2>/dev/null) || continue
    work=$(mktemp -d "$AGENT_DATA_DIR/job.XXXXXXXX") || { sleep 4; continue; }
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 3 "$timeout_secs" /bin/sh -c "$command_text" >"$work/out" 2>"$work/err"
        exit_code=$?
    else
        /bin/sh -c "$command_text" >"$work/out" 2>"$work/err"
        exit_code=$?
    fi
    head -c 100000 "$work/out" | base64 | tr -d '\n' >"$work/out.b64"
    head -c 100000 "$work/err" | base64 | tr -d '\n' >"$work/err.b64"
    printf '{"id":"%s","exit_code":%s,"stdout_b64":"%s","stderr_b64":"%s"}' \
      "$job_id" "$exit_code" "$(cat "$work/out.b64")" "$(cat "$work/err.b64")" >"$work/result.json"
    curl -fsS --connect-timeout 8 --max-time 20 -H "X-Agent-Token: $AGENT_TOKEN" -H 'Content-Type: application/json' \
      --data-binary "@$work/result.json" "$RELAY_URL/v1/agent/result" >/dev/null 2>&1 || \
      echo "Result submit failed for $job_id; command will not be retried" >&2
    rm -rf "$work"
done
