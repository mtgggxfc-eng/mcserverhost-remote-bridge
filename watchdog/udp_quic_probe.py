#!/usr/bin/env python3
"""Public UDP/QUIC TLS reachability, not credential authentication."""
import asyncio
import json
import os
import ssl
import time
from aioquic.asyncio.client import connect
from aioquic.quic.configuration import QuicConfiguration

async def check():
    host = os.environ.get("HY2_HOST", "15.204.97.241")
    port = int(os.environ.get("HY2_PORT", "11651"))
    cfg = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    cfg.verify_mode = ssl.CERT_NONE  # Probe only: non-production self-signed cert
    cfg.server_name = "mcbridge-lab"
    t0 = time.monotonic()
    try:
        async with asyncio.timeout(9):
            async with connect(host, port, configuration=cfg, wait_connected=True):
                elapsed_ms = round((time.monotonic() - t0) * 1000)
                print(json.dumps({"reachable": True, "quic_tls_handshake": "pass", "remote_port": port, "ms": elapsed_ms}))
                return 0
    except Exception as e:
        print(json.dumps({"reachable": False, "quic_tls_handshake": "failed", "remote_port": port,
                          "reason": type(e).__name__, "message": str(e)[:170]}))
        return 1

if __name__ == "__main__":
    raise SystemExit(asyncio.run(check()))
