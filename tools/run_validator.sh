#!/usr/bin/env bash
#
# run_validator.sh — one-shot: install deps and start the War validation service.
#
# Brings up the self-contained validator/ workspace and serves it locally:
#   HTTP + Hermes WS + MCP on :5555   (gRPC on :8081)
#
# In-game, press V to connect to the local validator. The client talks the same
# Snapser Hermes WebSocket envelope it would in production; locally that envelope is
# served at  ws://localhost:5555/hermes/ws?token=<player-id>  (the ?token= query param
# is the self-stamped player id — there is no gateway locally).
#
# Usage:
#   tools/run_validator.sh
#
# Notes:
#   - bun run dev uses --watch, so it hot-reloads on change. Don't kill/restart it to
#     pick up edits — just save.
#   - Override the runner with:  BUN=/path/to/bun  tools/run_validator.sh
#
# Make executable once:  chmod +x tools/run_validator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR_DIR="$REPO_DIR/validator"

BUN="${BUN:-bun}"

if ! command -v "$BUN" >/dev/null 2>&1; then
  echo "error: bun not found on PATH. Install from https://bun.sh or set BUN=/path/to/bun." >&2
  exit 1
fi
if [[ ! -f "$VALIDATOR_DIR/package.json" ]]; then
  echo "error: $VALIDATOR_DIR/package.json missing — is this the War repo?" >&2
  exit 1
fi

echo "→ validator: $VALIDATOR_DIR"
echo "→ bun install (links the src/logic workspace)"
( cd "$VALIDATOR_DIR" && "$BUN" install )

echo "→ bun run dev  (HTTP + Hermes WS + MCP on :5555, gRPC on :8081 — press V in-game)"
exec "$BUN" --cwd "$VALIDATOR_DIR" run dev
