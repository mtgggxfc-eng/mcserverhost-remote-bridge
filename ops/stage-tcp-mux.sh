#!/bin/sh
# Stage a tested Linux mux and updated Java SSH bridge; does NOT change live ports.
set -eu
umask 077
BASE=/home/container/lab/remote-stack
PLUGINS=/home/container/plugins
mkdir -p "$BASE/backup"
test -f "$PLUGINS/MineSHHShellMode.jar"
curl -fsSL --retry 3 -o "$BASE/tcp-mux.download" \
  https://github.com/mtgggxfc-eng/mcserverhost-remote-bridge/releases/download/tcp-mux-v0.1.0/tcp-mux
echo "641a670427a2c72831c4cb4b799de4f061344d851d8f45f4bcf99ffeee755aeb  $BASE/tcp-mux.download" | sha256sum -c - >/dev/null
chmod 700 "$BASE/tcp-mux.download"
mv "$BASE/tcp-mux.download" "$BASE/tcp-mux"
curl -fsSL --retry 3 -o "$BASE/MineSHHShellMode-v0.3.0.jar.b64" \
  https://raw.githubusercontent.com/mtgggxfc-eng/mcserverhost-remote-bridge/main/ops/binaries/MineSHHShellMode-v0.3.0.jar.b64
base64 -d "$BASE/MineSHHShellMode-v0.3.0.jar.b64" >"$BASE/MineSHHShellMode-v0.3.0.jar"
echo "191e327c1cfe1b1f420d9302df40b8e4fcab9d73f0a56d2eff64dd76ad976209  $BASE/MineSHHShellMode-v0.3.0.jar" | sha256sum -c - >/dev/null
cp -p "$PLUGINS/MineSHHShellMode.jar" "$BASE/backup/MineSHHShellMode-before-mux.jar"
cp "$BASE/MineSHHShellMode-v0.3.0.jar" "$PLUGINS/MineSHHShellMode.jar"
echo TCP_MULTIPLEXER_BINARY_STAGED
echo MINE_SHH_SHELL_PLUGIN_STAGED_NOT_ACTIVE
echo NO_GAME_PORT_CHANGES_MADE
