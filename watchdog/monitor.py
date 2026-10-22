#!/usr/bin/env python3
"""External monitoring for user's own MCServerHost service.
This monitor does not claim to stop provider idle sleep.
"""
import datetime
import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.request

BRIDGE = os.environ.get("BRIDGE_HEALTH_URL", "https://mcserverhost-remote-bridge.onrender.com/health")
GAME_HOST = os.environ.get("MC_GAME_HOST", "15.204.97.241")
GAME_PORT = int(os.environ.get("MC_GAME_PORT", "11648"))
SSH_PORT = int(os.environ.get("MC_SSH_PORT", "11651"))

def probe_tcp(host, port, timeout=5):
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return {"reachable": True, "latency_ms": round((time.monotonic() - start) * 1000)}
    except (OSError, TimeoutError) as exc:
        return {"reachable": False, "error_type": type(exc).__name__}

def varint(value):
    out = bytearray()
    while True:
        part = value & 127
        value >>= 7
        out.append(part | (128 if value else 0))
        if not value:
            return bytes(out)

def read_varint(conn):
    result = 0
    for i in range(5):
        b = conn.recv(1)
        if not b:
            raise ConnectionError("closed")
        val = b[0]
        result |= (val & 127) << (7 * i)
        if not val & 128:
            return result
    raise ValueError("Oversized varint")

def read_exact(conn, length):
    if not 0 <= length <= 65536:
        raise ValueError("Invalid packet size")
    data = b""
    while len(data) < length:
        packet = conn.recv(length - len(data))
        if not packet:
            raise ConnectionError("closed")
        data += packet
    return data

def minecraft_status(host, port):
    """Read vanilla server-list status (separate from TCP accept)."""
    try:
        with socket.create_connection((host, port), timeout=4) as conn:
            conn.settimeout(4)
            server_host = host.encode()
            handshake = b"\x00" + varint(0) + varint(len(server_host)) + server_host + port.to_bytes(2, "big") + b"\x01"
            conn.sendall(varint(len(handshake)) + handshake + b"\x01\x00")
            length = read_varint(conn)
            data = read_exact(conn, length)
            if not data or data[0] != 0:
                raise ValueError("Unexpected status response")
            # JSON status string is prefixed by a VarInt.
            off = 1
            strlen = 0
            for shift in range(0, 35, 7):
                byte = data[off]
                off += 1
                strlen |= (byte & 127) << shift
                if not byte & 128:
                    break
            result = json.loads(data[off:off + strlen].decode("utf-8"))
            return {"responded": True, "players_online": (result.get("players") or {}).get("online"),
                    "version": (result.get("version") or {}).get("name")}
    except (OSError, TimeoutError, IndexError, ValueError, UnicodeError) as exc:
        return {"responded": False, "error_type": type(exc).__name__}

def probe_tls_multiplex(host, port):
    """Check whether the SSH TCP port also accepts a TLS ClientHello."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=4) as sock:
            sock.settimeout(5)
            with ctx.wrap_socket(sock, server_hostname="www.microsoft.com") as tls:
                return {"tls_handshake": True, "version": tls.version()}
    except (OSError, TimeoutError, ssl.SSLError) as exc:
        return {"tls_handshake": False, "error_type": type(exc).__name__}

def probe_health(url):
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "MCBridge-Watch/1.0"})
        with urllib.request.urlopen(req, timeout=25) as res:
            if res.status != 200:
                return {"reachable": False, "http_status": res.status}
            doc = json.load(res)
        return {
            "reachable": True,
            "latency_ms": round((time.monotonic() - start) * 1000),
            "agent_connected": doc.get("agent_connected"),
            "command_probe": doc.get("command_probe"),
        }
    except (OSError, TimeoutError, ValueError, urllib.error.URLError) as exc:
        return {"reachable": False, "error_type": type(exc).__name__}

def probe_world_client(url):
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "MCBridge-Watch/1.1"})
        with urllib.request.urlopen(req, timeout=25) as res:
            data = json.load(res)
        return {
            "reachable": True,
            "connected": bool(data.get("connected")),
            "loginSucceeded": bool(data.get("loginSucceeded")),
            "status": str(data.get("status") or "unknown")[:50],
            "uptimeSeconds": data.get("uptimeSeconds"),
            "latency_ms": round((time.monotonic() - start) * 1000),
        }
    except (OSError, TimeoutError, ValueError, urllib.error.URLError) as exc:
        return {"reachable": False, "error_type": type(exc).__name__}

def main():
    report = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "mode": "monitor_only",
        "bridge": probe_health(BRIDGE),
        "minecraft_tcp": probe_tcp(GAME_HOST, GAME_PORT),
        "minecraft_status": minecraft_status(GAME_HOST, GAME_PORT),
        "ssh_tcp": probe_tcp(GAME_HOST, SSH_PORT),
        "tls_multiplexer": probe_tls_multiplex(GAME_HOST, SSH_PORT),
    }
    report["world_client"] = probe_world_client(os.environ.get("WORLD_CLIENT_HEALTH_URL", "https://mcserverhost-world-session.onrender.com/health"))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        bridge = report["bridge"]
        game = report["minecraft_tcp"]
        session = report["world_client"]
        ssh = report["ssh_tcp"]
        with open(summary, "a", encoding="utf-8") as out:
            out.write("## MCServerHost external monitoring\n\n")
            out.write(f"Time (UTC): {report['timestamp']}\n\n")
            out.write("| Item | Observation |\n|---|---|\n")
            out.write(f"| Bridge HTTPS | {'reachable' if bridge.get('reachable') else 'unreachable'} |\n")
            out.write(f"| Container Agent | {bridge.get('agent_connected', 'unknown')} |\n")
            out.write("| External game client | " + ("online" if session.get("connected") else session.get("status", "offline")) + " |\\n")
            out.write(f"| Minecraft TCP {GAME_PORT} | {'reachable' if game.get('reachable') else 'unreachable'} |\n")
            out.write("| Minecraft protocol status | " + ("responded" if report["minecraft_status"].get("responded") else "no response") + " |\\n")
            out.write(f"| FinalShell TCP {SSH_PORT} | {'reachable' if ssh.get('reachable') else 'unreachable'} |\n")
            out.write("\nThis probe observes connectivity only. It does not prevent provider idle sleep.\n")
    # Monitoring failures are observations, not CI failures (prevents repeated notification emails).
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
