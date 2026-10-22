#!/bin/sh
# Hysteria 2 / QUIC on the user-allocated UDP port; no root required.
set -eu
umask 077
BASE="${HY2_DIR:-/home/container/lab/hy2}"
PORT="${HY2_PORT:-11651}"
HOST="${HY2_PUBLIC_HOST:-15.204.97.241}"
BIN="$BASE/hysteria"
CFG="$BASE/config.yaml"
PIDFILE="$BASE/hysteria.pid"
LOG="$BASE/hysteria.log"
mkdir -p "$BASE"
cd "$BASE"
case "$PORT" in ''|*[!0-9]*) echo "Invalid HY2_PORT"; exit 2;; esac
command -v openssl >/dev/null 2>&1 || { echo "OpenSSL missing"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl missing"; exit 2; }
if [ ! -s "$BIN" ]; then
  temp="$BIN.download"
  curl -fLsS --connect-timeout 10 --max-time 120 'https://download.hysteria.network/app/latest/hysteria-linux-amd64' -o "$temp"
  chmod 700 "$temp"
  "$temp" version >/dev/null
  mv -f "$temp" "$BIN"
fi
"$BIN" version >/dev/null
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "HY2_ALREADY_RUNNING pid=$pid udp_port=$PORT"
    exit 0
  fi
fi
if [ ! -s "$BASE/server.crt" ] || [ ! -s "$BASE/server.key" ]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 \
    -keyout "$BASE/server.key" -out "$BASE/server.crt" \
    -subj "/CN=mcbridge-lab" -addext "subjectAltName=IP:$HOST" >/dev/null 2>&1
  chmod 600 "$BASE/server.key"
fi
if [ ! -s "$BASE/password.txt" ]; then
  openssl rand -hex 24 >"$BASE/password.txt"
  chmod 600 "$BASE/password.txt"
fi
{
  printf 'listen: 0.0.0.0:%s\n' "$PORT"
  printf 'tls:\n  cert: %s/server.crt\n  key: %s/server.key\n' "$BASE" "$BASE"
  printf 'auth:\n  type: password\n  password: "%s"\n' "$(cat "$BASE/password.txt")"
} >"$CFG"
chmod 600 "$CFG"
nohup "$BIN" server -c "$CFG" >>"$LOG" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" >"$PIDFILE"
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
  echo "HY2_START_FAILED, check $LOG"
  tail -n 15 "$LOG"
  exit 1
fi
fingerprint=$(openssl x509 -in "$BASE/server.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')
{
  printf 'server: %s:%s\n' "$HOST" "$PORT"
  printf 'auth: "%s"\n' "$(cat "$BASE/password.txt")"
  printf 'tls:\n  sni: %s\n  insecure: true\n  pinSHA256: "%s"\n' "$HOST" "$fingerprint"
} >"$BASE/client.yaml"
chmod 600 "$BASE/client.yaml"
echo "HY2_PROCESS_RUNNING pid=$pid udp_port=$PORT"
echo "CLIENT_CONFIG=$BASE/client.yaml"
echo "SERVER_LOG=$LOG"
echo "PUBLIC_UDP_REACHABILITY=NOT_YET_VERIFIED"
