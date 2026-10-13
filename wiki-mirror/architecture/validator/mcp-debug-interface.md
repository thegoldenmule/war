# MCP Debug Interface

**Status:** current

## Kind
component

## Summary
A minimal **JSON-RPC 2.0 MCP server** exposed at `POST /mcp` on the validator, giving MCP clients (agent tooling, godot-ai) a debug surface onto authoritative match state. It declares four tools — `list_matches`, `get_match_state`, `simulate_action`, and `clear_match` — implemented over a single HTTP endpoint.

## Purpose
It exists to let an operator or agent *inspect and poke at live match state without going through the game client* — listing matches, dumping a match's canonical-JSON state, dry-running an action to see the engine verdict, and deleting a match. This makes desyncs and reconciliation bugs debuggable by reading the validator's own authoritative truth directly.

## Design notes
Registered in .mcp.json as the validator MCP server at http://127.0.0.1:5555/mcp. Start the validator first — the MCP endpoint is served by the same Hono app that hosts the validator, so the server must be running before any MCP client can connect.

The server is intentionally read/debug oriented. clear_match is the only destructive tool; it deletes a match from the in-memory store and returns whether a match was actually removed. There is no tool to apply a persisting action through MCP by design — authoritative mutations flow through the normal validator path, not this debug surface.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `handleMcpRequest` in `validator/src/validator/mcp.ts`
- constant `TOOLS` in `validator/src/validator/mcp.ts`
- function `callTool` in `validator/src/validator/mcp.ts`
- function `POST /mcp` in `validator/src/validator/index.ts`
- class `ValidatorService` in `validator/src/validator/service.ts`
- `.mcp.json`

## Data model
The endpoint speaks JSON-RPC 2.0 and handles three methods: `initialize` (returns protocolVersion `2024-11-05`, serverInfo `war-validator` v0.1.0, and a `tools` capability), `tools/list` (returns the static `TOOLS` catalog), and `tools/call` (dispatches by `params.name` with `params.arguments`). The `notifications/initialized` notification returns no response. Each tool maps to a `ValidatorService` method: `list_matches` to `listMatches()`, `get_match_state({match_id})` to `getMatchStateJson()`, `simulate_action({match_id, action_json})` to `simulateAction()`, and `clear_match({match_id})` to `clearMatch()`. Results are wrapped as MCP text content via `textResult`; non-string values are pretty-printed JSON.

## Usage
_None._

## Invariants & constraints
- simulate_action is a dry run: it delegates to ValidatorService.simulateAction and NEVER mutates the authoritative timeline — it returns the engine verdict, resulting state JSON, and hash without persisting.
- handleMcpRequest is pure-ish: it returns the JSON-RPC response object (or null for notifications) and does not perform I/O itself; the Hono /mcp route in index.ts owns request/response transport.
- All tool results route through textResult, so every successful response is MCP text content; thrown errors are caught and surfaced as a JSON-RPC error with code -32603 (internal error), and unknown methods return -32601 (method not found).
- The tool catalog is static: TOOLS declares each tool's name, description, and JSON-Schema inputSchema with additionalProperties:false, so argument shapes are validated against a fixed contract.

## Synced commit
_None._
