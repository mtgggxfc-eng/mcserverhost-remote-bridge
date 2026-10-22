# MCServerHost Remote Bridge
A minimal authenticated HTTPS relay and outbound-only POSIX-shell agent for managing **your own Minecraft container** through API requests.

## Overview
- Render runs `server.py` over HTTPS (provider-side TLS), and stores a bounded SQLite queue.
- The container runs `agent.sh`; it polls the relay using outbound HTTPS, so no new inbound game port is needed.
- Operators use an independent secret to submit and read jobs via REST or the experimental MCP JSON-RPC endpoint.
- Secrets are only stored in Render environment variables or local secure runtime configuration; never commit them to Git.

## Important
This code grants the holder of OPERATOR_TOKEN remote shell execution with your game's existing Linux UID. Secure both keys like administrator credentials. Do not store the Operator key on the game server. 
Public GitHub source is fine; passwords/tokens must never be checked in.

## Environment variables on Render
- `OPERATOR_TOKEN` = random unique secret (24+ characters).
- `AGENT_TOKEN` = another random unique secret (24+ characters).
- `PORT` = injected automatically by Render.

## Deploy
Render: new Web Service -> Docker -> repo `mtgggxfc-eng/mcserverhost-remote-bridge` -> branch `main` -> plan Free. Set the two tokens above as environment variables. `GET /health` should return `{"status":"ok"}`.

## Install agent
Download `agent.sh` into `/home/container/lab/remote-agent/agent.sh`; it requires `curl`, `base64`, `/bin/sh`. Define RELAY_URL and AGENT_TOKEN in private runtime variables then execute `sh agent.sh`.

## API
`POST /v1/jobs`: operator authorization and JSON `{"command":"pwd; id -u","timeout_secs":30}` ; returns job ID.
`GET /v1/jobs/ID`: status, stdout, stderr, exit code.
`GET /v1/status`: relay status, last worker heartbeat.
`GET /mcp` is not used; `POST /mcp` handles experimental MCP JSON-RPC.

### Limitations
The agent must be running and the Minecraft container awake. Render Free may sleep or restart; transient SQLite queue and logs can be lost on reboot. This is a development bridge, not a permanent VPS supervisor.
