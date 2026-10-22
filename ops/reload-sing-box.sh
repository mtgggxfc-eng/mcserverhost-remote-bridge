#!/bin/sh
set -eu
umask 077
BASE="${SBOX_DIR:-/home/container/lab/sing-box}"
BIN="$BASE/sing-box"
CFG="$BASE/config.json"
PID="$BASE/sing-box.pid"
"$BIN" check -c "$CFG" >/dev/null || { echo SBOX_CONFIG_REJECTED; exit 1; }
if [ -s "$PID" ]; then
  old=$(cat "$PID")
  if kill -0 "$old" 2>/dev/null && ps -p "$old" -o args= | grep -q "$BIN run"; then
    kill "$old"
    sleep 2
  fi
fi
nohup "$BIN" run -c "$CFG" >"$BASE/server.log" 2>&1 </dev/null &
new=$!
printf '%s\n' "$new" >"$PID"
sleep 3
if ! kill -0 "$new" 2>/dev/null; then tail -n 15 "$BASE/server.log";exit 1;fi
if ! ss -lunp | grep -q ':11651'; then echo HY2_LISTENER_MISSING; exit 1; fi
if ! ss -ltnp | grep -q ':21652'; then echo VLESS_LISTENER_MISSING; exit 1; fi
echo SINGBOX_HY2_UDP_11651_ACTIVE
echo SINGBOX_VLESS_TCP_21652_INTERNAL_ACTIVE
