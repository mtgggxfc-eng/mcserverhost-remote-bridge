#!/bin/sh
# Paper starts this script on each Minecraft process boot.
# Secrets are read only from local 0600 files.
set -eu
umask 077
BASE=/home/container/lab/remote-stack
AGENT_DIR=/home/container/lab/remote-agent
SBOX_DIR=/home/container/lab/sing-box
RELAY_URL=https://mcserverhost-remote-bridge.onrender.com
mkdir -p "$BASE" "$AGENT_DIR" "$SBOX_DIR"
cd "$BASE"
if [ ! -s "$AGENT_DIR/agent.sh" ]; then
  curl -fsSLo "$AGENT_DIR/agent.sh" \
    https://raw.githubusercontent.com/mtgggxfc-eng/mcserverhost-remote-bridge/main/agent.sh
  chmod 700 "$AGENT_DIR/agent.sh"
fi
if [ -s "$BASE/agent.token" ]; then
  alive=0
  if [ -s "$BASE/agent.pid" ]; then
    pid=$(cat "$BASE/agent.pid")
    if kill -0 "$pid" 2>/dev/null; then alive=1; fi
  fi
  if [ "$alive" -eq 0 ]; then
    AGENT_TOKEN=$(cat "$BASE/agent.token")
    RELAY_URL="$RELAY_URL" AGENT_TOKEN="$AGENT_TOKEN" AGENT_DATA_DIR="$AGENT_DIR" \
      nohup sh "$AGENT_DIR/agent.sh" >>"$BASE/agent.log" 2>&1 </dev/null &
    echo "$!" >"$BASE/agent.pid"
    echo AGENT_START_REQUESTED
  else
    echo AGENT_ALREADY_RUNNING
  fi
else
  echo AGENT_TOKEN_FILE_MISSING
fi
if [ ! -s "$BASE/sing-box-install.sh" ]; then
  curl -fsSLo "$BASE/sing-box-install.sh" \
    https://raw.githubusercontent.com/mtgggxfc-eng/mcserverhost-remote-bridge/main/ops/sing-box-install.sh
fi
SBOX_DIR="$SBOX_DIR" sh "$BASE/sing-box-install.sh"
