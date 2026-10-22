#!/bin/sh
# HY2 authenticated end-to-end loopback-to-proxy test.
# No credentials are logged or uploaded; temporary config stays on the game container.
set -eu
umask 077
BASE="${SBOX_DIR:-/home/container/lab/sing-box}"
PORT="${HY2_PORT:-11651}"
CLIENT_PORT=17891
BIN="$BASE/sing-box"
TESTDIR="$BASE/private/selftest"
mkdir -p "$TESTDIR"
pass=$(cat "$BASE/private/hy2.pass")
cat >"$TESTDIR/config.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "mixed",
    "tag": "local-client",
    "listen": "127.0.0.1",
    "listen_port": $CLIENT_PORT
  }],
  "outbounds": [{
    "type": "hysteria2",
    "tag": "hy2-test",
    "server": "127.0.0.1",
    "server_port": $PORT,
    "password": "$pass",
    "tls": {
      "enabled": true,
      "server_name": "mcbridge-lab",
      "insecure": true,
      "alpn": ["h3"]
    }
  }],
  "route": {"final": "hy2-test"}
}
EOF
"$BIN" check -c "$TESTDIR/config.json" >/dev/null
"$BIN" run -c "$TESTDIR/config.json" >"$TESTDIR/client.log" 2>&1 </dev/null &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
trap cleanup EXIT INT TERM
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then echo HY2_SELFTEST_CLIENT_FAILED; tail -n 12 "$TESTDIR/client.log"; exit 1; fi
if curl --silent --show-error --fail --max-time 18 --proxy "socks5h://127.0.0.1:$CLIENT_PORT" 'https://api.ipify.org' >"$TESTDIR/public-ip.txt"; then
  echo HY2_AUTH_AND_PROXY_TRAFFIC_PASS
  echo 'PROXIED_EGRESS_IP_RETRIEVED'
  exit 0
fi
echo HY2_AUTH_OR_PROXY_TRAFFIC_FAILED
tail -n 14 "$TESTDIR/client.log"
exit 1
