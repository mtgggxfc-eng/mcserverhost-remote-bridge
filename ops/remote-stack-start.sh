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
VLESS_PORT=21652 PUBLIC_VLESS_PORT=11651 SBOX_DIR="$SBOX_DIR" sh "$BASE/sing-box-install.sh"
if [ -x "$BASE/tcp-mux" ]; then
  mux_alive=0
  if [ -s "$BASE/tcp-mux.pid" ]; then
    mux_pid=$(cat "$BASE/tcp-mux.pid")
    if kill -0 "$mux_pid" 2>/dev/null && ps -p "$mux_pid" -o args= | grep -F "$BASE/tcp-mux" >/dev/null 2>&1;then
      mux_alive=1
    fi
  fi
  if [ "$mux_alive" -eq 0 ]; then
    nohup "$BASE/tcp-mux" -listen 0.0.0.0:11651 -ssh 127.0.0.1:21651 -reality 127.0.0.1:21652 >>"$BASE/mux.log" 2>&1 </dev/null &
    echo "$!" >"$BASE/tcp-mux.pid"
    echo TCP_MUX_START_REQUESTED
  else
    echo TCP_MUX_ALREADY_RUNNING
  fi
else
  echo TCP_MUX_BINARY_MISSING
fi
if [ "${MCBRIDGE_WATCHDOG_CHILD:-0}" != 1 ]; then
  if [ ! -s "$BASE/watchdog.pid" ] || ! kill -0 "$(cat "$BASE/watchdog.pid")" 2>/dev/null;then
    if [ ! -s "$BASE/watchdog.sh" ];then
      curl -fsSLo "$BASE/watchdog.sh" https://raw.githubusercontent.com/mtgggxfc-eng/mcserverhost-remote-bridge/main/ops/watchdog.sh
    fi
    nohup sh "$BASE/watchdog.sh" >>"$BASE/watchdog.log" 2>&1 </dev/null &
    echo "$!" >"$BASE/watchdog.pid"
    echo SERVICE_WATCHDOG_REQUESTED
  fi
fi

