#!/usr/bin/env python3
"""External monitoring for user's own MCServerHost service.
This monitor does not claim to stop provider idle sleep.
"""
import datetime
import json
import os
import socket
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

def main():
    report = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "mode": "monitor_only",
        "bridge": probe_health(BRIDGE),
        "minecraft_tcp": probe_tcp(GAME_HOST, GAME_PORT),
        "ssh_tcp": probe_tcp(GAME_HOST, SSH_PORT),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        bridge = report["bridge"]
        game = report["minecraft_tcp"]
        ssh = report["ssh_tcp"]
        with open(summary, "a", encoding="utf-8") as out:
            out.write("## MCServerHost external monitoring\n\n")
            out.write(f"Time (UTC): {report['timestamp']}\n\n")
            out.write("| Item | Observation |\n|---|---|\n")
            out.write(f"| Bridge HTTPS | {'reachable' if bridge.get('reachable') else 'unreachable'} |\n")
            out.write(f"| Container Agent | {bridge.get('agent_connected', 'unknown')} |\n")
            out.write(f"| Minecraft TCP {GAME_PORT} | {'reachable' if game.get('reachable') else 'unreachable'} |\n")
            out.write(f"| FinalShell TCP {SSH_PORT} | {'reachable' if ssh.get('reachable') else 'unreachable'} |\n")
            out.write("\nThis probe observes connectivity only. It does not prevent provider idle sleep.\n")
    # Monitoring failures are observations, not CI failures (prevents repeated notification emails).
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
