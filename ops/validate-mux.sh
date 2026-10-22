#!/bin/sh
set -eu
umask 077
BASE=/home/container/lab/remote-stack
BIN="$BASE/tcp-mux"
[ -x "$BIN" ]
nohup "$BIN" -listen 127.0.0.1:23000 -ssh 127.0.0.1:11651 -reality 127.0.0.1:21652 -detect 350ms >"$BASE/mux-local-test.log" 2>&1 </dev/null &
pid=$!
trap 'kill "$pid" 2>/dev/null || :' EXIT
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then echo MUX_TEST_PROCESS_FAILED;exit 1;fi
# SSH server-first banner over temporary loopback mux.
banner=$(curl -fsS --silent --max-time 3 telnet://127.0.0.1:23000 2>/dev/null | head -c 70 || :)
case "$banner" in SSH-2.0-*) echo MUX_REAL_SSH_BACKEND_BANNER_PASS ;; *)
  echo MUX_REAL_SSH_BACKEND_BANNER_PENDING
  exit 1 ;;
esac
echo MUX_PRE_SWITCH_VALIDATION_PASS
