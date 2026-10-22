#!/bin/sh
# Deploy sing-box 1.14.1 in the Minecraft container, no root or apt.
# HY2: UDP 11651. VLESS+REALITY: requires another assigned TCP port.
set -eu
umask 077
BASE="${SBOX_DIR:-/home/container/lab/sing-box}"
HOST="${PUBLIC_HOST:-15.204.97.241}"
UDP_PORT="${HY2_PORT:-11651}"
TCP_PORT="${VLESS_PORT:-}"
VERSION=1.14.1
SHA256=12cb2816b52febb356f6a885b740cc8758c3f30b8ae0ca8edba80f0d2d35343f
mkdir -p "$BASE/private"
cd "$BASE"
case "$UDP_PORT" in ''|*[!0-9]*) echo HY2_PORT_INVALID; exit 2;; esac
if [ -n "$TCP_PORT" ]; then
  case "$TCP_PORT" in *[!0-9]*) echo VLESS_PORT_INVALID; exit 2;; esac
  if [ "$TCP_PORT" -eq 11648 ] || [ "$TCP_PORT" -eq 11651 ]; then echo TCP_PORT_IN_USE; exit 2; fi
  if [ "$TCP_PORT" -le 1024 ] || [ "$TCP_PORT" -gt 65535 ]; then echo TCP_PORT_INVALID; exit 2; fi
fi
for tool in curl tar openssl sha256sum awk sed; do
  command -v "$tool" >/dev/null || { echo "MISSING_TOOL=$tool"; exit 2; }
done
if [ ! -x "$BASE/sing-box" ]; then
  curl --fail --location --silent --show-error --retry 3 --max-time 160 \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.1/sing-box-1.14.1-linux-amd64.tar.gz" \
    -o "$BASE/sing-box.tar.gz"
  echo "$SHA256  $BASE/sing-box.tar.gz" | sha256sum -c - >/dev/null
  mkdir -p "$BASE/unpacked"
  tar -xzf "$BASE/sing-box.tar.gz" -C "$BASE/unpacked" "sing-box-1.14.1-linux-amd64/sing-box"
  mv "$BASE/unpacked/sing-box-1.14.1-linux-amd64/sing-box" "$BASE/sing-box"
  chmod 700 "$BASE/sing-box"
fi
"$BASE/sing-box" version >/dev/null
if [ ! -s "$BASE/private/hy2.pass" ]; then
  openssl rand -hex 24 >"$BASE/private/hy2.pass"
  chmod 600 "$BASE/private/hy2.pass"
fi
if [ ! -s "$BASE/private/hy2.crt" ] || [ ! -s "$BASE/private/hy2.key" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 -sha256 \
    -subj '/CN=mcbridge-lab' -addext "subjectAltName=IP:$HOST" \
    -keyout "$BASE/private/hy2.key" -out "$BASE/private/hy2.crt" >/dev/null 2>&1
  chmod 600 "$BASE/private/hy2.key"
fi
HY2_PASSWORD=$(cat "$BASE/private/hy2.pass")
if [ -n "$TCP_PORT" ]; then
  if [ ! -s "$BASE/private/reality.keys" ]; then
    "$BASE/sing-box" generate reality-keypair >"$BASE/private/reality.keys"
    chmod 600 "$BASE/private/reality.keys"
  fi
  REALITY_PRIVATE=$(awk -F ':' '/PrivateKey|Private key/{gsub(/^[[:space:]]+/, "", $2);print $2}' "$BASE/private/reality.keys")
  REALITY_PUBLIC=$(awk -F ':' '/PublicKey|Public key/{gsub(/^[[:space:]]+/, "", $2);print $2}' "$BASE/private/reality.keys")
  [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || { echo REALITY_KEYPARSE_FAILED; exit 2; }
  if [ ! -s "$BASE/private/uuid" ]; then
    cat /proc/sys/kernel/random/uuid >"$BASE/private/uuid"
    chmod 600 "$BASE/private/uuid"
  fi
  if [ ! -s "$BASE/private/shortid" ]; then
    openssl rand -hex 4 >"$BASE/private/shortid"
    chmod 600 "$BASE/private/shortid"
  fi
  UUID=$(cat "$BASE/private/uuid")
  SHORTID=$(cat "$BASE/private/shortid")
fi
cat >"$BASE/config.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $UDP_PORT,
      "users": [{"password": "$HY2_PASSWORD"}],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$BASE/private/hy2.crt",
        "key_path": "$BASE/private/hy2.key"
      }
    }
EOF
if [ -n "$TCP_PORT" ]; then
cat >>"$BASE/config.json" <<EOF
    ,{
      "type": "vless",
      "tag": "vless-reality",
      "listen": "127.0.0.1",
      "listen_port": $TCP_PORT,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "www.microsoft.com", "server_port": 443},
          "private_key": "$REALITY_PRIVATE",
          "short_id": ["$SHORTID"]
        }
      }
    }
EOF
fi
cat >>"$BASE/config.json" <<EOF
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF
chmod 600 "$BASE/config.json"
"$BASE/sing-box" check -c "$BASE/config.json"
{
  printf 'hysteria2://%s@%s:%s?sni=mcbridge-lab&insecure=1#MC-HY2-sing-box\n' "$HY2_PASSWORD" "$HOST" "$UDP_PORT"
  if [ -n "$TCP_PORT" ]; then
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=%s&sid=%s&type=tcp#MC-VLESS-REALITY-sing-box\n' \
      "$UUID" "$HOST" "${PUBLIC_VLESS_PORT:-$TCP_PORT}" "$REALITY_PUBLIC" "$SHORTID"
  fi
} >"$BASE/private/share-links.txt"
chmod 600 "$BASE/private/share-links.txt"
if [ "${SBOX_CHECK_ONLY:-0}" = 1 ]; then
  echo SBOX_CONFIG_CHECK_OK
  exit 0
fi
if [ -s "$BASE/sing-box.pid" ]; then
  p=$(cat "$BASE/sing-box.pid")
  if kill -0 "$p" 2>/dev/null; then
    echo SBOX_ALREADY_RUNNING
    exit 0
  fi
fi
nohup "$BASE/sing-box" run -c "$BASE/config.json" >"$BASE/server.log" 2>&1 </dev/null &
pid=$!
echo "$pid" >"$BASE/sing-box.pid"
sleep 3
if ! kill -0 "$pid" 2>/dev/null; then
  echo SBOX_START_FAILED
  tail -n 20 "$BASE/server.log"
  exit 1
fi
echo SBOX_PROCESS_STARTED
echo "HY2_UDP=$UDP_PORT"
if [ -n "$TCP_PORT" ]; then echo "VLESS_TCP=$TCP_PORT"; else echo VLESS_TCP_PORT_NOT_ALLOCATED; fi
echo "SHARE_LINKS_FILE=$BASE/private/share-links.txt"
echo EXTERNAL_REACHABILITY_NOT_YET_VERIFIED
