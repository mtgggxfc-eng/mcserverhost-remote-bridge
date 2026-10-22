#!/bin/sh
# Loopback REALITY authenticated proxy traffic test. No credentials printed.
set -eu
umask 077
BASE="${SBOX_DIR:-/home/container/lab/sing-box}"
BIN="$BASE/sing-box"
TESTDIR="$BASE/private/vless-selftest"
mkdir -p "$TESTDIR"
UUID=$(cat "$BASE/private/uuid")
SHORTID=$(cat "$BASE/private/shortid")
PUBLIC=$(awk -F ':' '/PublicKey|Public key/{gsub(/^[[:space:]]+/, "", $2);print $2}' "$BASE/private/reality.keys")
[ -n "$UUID" ] && [ -n "$SHORTID" ] && [ -n "$PUBLIC" ] || { echo MISSING_VLESS_CREDENTIALS; exit 2; }
cat >"$TESTDIR/config.json" <<EOF
{
 "log":{"level":"warn"},
 "inbounds":[{"type":"mixed","tag":"local-test","listen":"127.0.0.1","listen_port":17892}],
 "outbounds":[{"type":"vless","tag":"vless-test",
   "server":"127.0.0.1","server_port":21652,
   "uuid":"$UUID","flow":"xtls-rprx-vision",
   "tls":{"enabled":true,"server_name":"www.microsoft.com",
     "reality":{"enabled":true,"public_key":"$PUBLIC","short_id":"$SHORTID"},
     "utls":{"enabled":true,"fingerprint":"chrome"}}
 }],
 "route":{"final":"vless-test"}
}
EOF
"$BIN" check -c "$TESTDIR/config.json" >/dev/null
"$BIN" run -c "$TESTDIR/config.json" >"$TESTDIR/client.log" 2>&1 </dev/null &
pid=$!
cleanup(){ kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }
trap cleanup EXIT INT TERM
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then echo VLESS_CLIENT_START_FAILED;tail -n 10 "$TESTDIR/client.log";exit 1;fi
if curl -fsS --max-time 20 --proxy 'socks5h://127.0.0.1:17892' https://api.ipify.org >"$TESTDIR/egress-ip.txt";then
 echo VLESS_REALITY_AUTH_AND_PROXY_TRAFFIC_PASS
 echo PROXIED_EGRESS_IP_RETRIEVED
 exit 0
fi
echo VLESS_REALITY_TRAFFIC_FAILED
tail -n 14 "$TESTDIR/client.log"
exit 1
