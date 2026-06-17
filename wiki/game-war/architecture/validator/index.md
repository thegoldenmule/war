# Validator

**Status:** current

## Kind
service

## Summary
The authoritative move-validation service for War (Bun + Hono + gRPC + a Hermes WebSocket + an MCP debug surface). It owns *no rules of its own*: it re-runs the SAME deterministic rules engine the client runs — its TypeScript twin in `validator/src/logic` — and confirms every action by recomputing the canonical state hash. Deployed as a Snapser BYOSnap.

## Purpose
It is the server half of the client's optimistic-reconcile loop and the one place server-side rules are enforced. The client plays optimistically and predicts the next-state hash; the validator loads the authoritative state, re-applies the action through `@war/logic`, and compares hashes. A *matching* hash means the prediction was correct and ACKs (fast path); a *mismatch* (or an illegal action) returns the authoritative state so the client can snap to it. Because the TS engine is byte-for-byte equivalent to the GDScript engine, a correct prediction always matches.

## Design notes
Transports are thin adapters over a single transport-agnostic ValidatorService: gRPC (war.validator.v1.ValidatorService), the Hermes-envelope WebSocket at /hermes/ws?token=<player-id>, and an MCP JSON-RPC debug surface at POST /mcp all route to the SAME service methods (initMatch, validateAction, completeMatch, plus read/simulate/clear helpers). Bun's native server lets the Hermes WS upgrade and the Hono HTTP routes share one port.

Lifecycle: InitMatch deals a fresh deterministic game from a seed (the seed fully determines the 26/26 deal) and returns the canonical initial state + hash for the client to mirror. ValidateAction re-applies over the authoritative state, persists on accept, compares predicted vs authoritative hash, and auto-completes when the phase is terminal (player_win / cpu_win) so the lifecycle is self-closing. CompleteMatch is idempotent and retains the record for history endpoints.

Skeleton-phase status: gRPC boot is best-effort and never blocks HTTP/WS/MCP startup (it awaits the committed proto descriptor), and the Hermes WS currently accepts a plain-JSON dev frame pending protobufjs envelope encode/decode. The logic.ts adapter resolves @war/logic exports defensively by trying plausible names (apply/applyAction, stateHash/hashValue, etc.); these fallbacks are to be replaced with direct typed imports once @war/logic ships its .d.ts.

## Components
- [Realtime Gateway (Hermes)](architecture:mqifg9io-00cj-1nzngt)
- [Match State Store](architecture:mqifgd1w-00cl-fg6qxq)
- [Crypto & Signing](architecture:mqifghlw-00cn-me41pg)
- [MCP Debug Interface](architecture:mqifgmct-00cp-c168mh)
- [Deploying the Validator (BYOSnap)](architecture:mqifgqqc-00cr-8k8pqf)

## Dependencies
_No dependencies._

## Code references
- function `start` in `validator/src/validator/index.ts`
- class `ValidatorService` in `validator/src/validator/service.ts`
- function `applyAction` in `validator/src/validator/logic.ts`
- class `MatchStore` in `validator/src/validator/store/match-store.ts`
- interface `ValidateResult` in `validator/src/validator/types.ts`
- function `hashString` in `validator/src/logic/src/hashing.ts`
- `validator/src/logic`

## Data model
Live matches are held in an in-memory, process-local `MatchStore` (a `Map` keyed by match id; a deployed validator would swap in a durable backing store). Each `MatchRecord` binds a `matchId` to the `playerId` it was created for, plus the `seed`, the current authoritative `state`, its cached canonical `stateJson` and 64-hex `hash`, an `appliedCount` cursor, and a `completed`/`finalPhase` lifecycle flag. State and actions never travel as structured fields — they are canonical-JSON *strings* on the wire (gRPC string fields, WS payloads), because that exact canonical string is the hash domain; the service parses them into permissive shapes only to hand them to the engine and re-serializes with the engine's canonical stringifier before hashing or returning. `ValidateResult` carries the reconcile verdict: `ok` (engine accepted), `hashMatched` (prediction equalled the authoritative hash), the authoritative `stateJson` + `hash`, engine `events`, and an `error`.

## Usage
_None._

## Invariants & constraints
- The validator NEVER implements War's rules. All deal/flip/war/special-card/win logic funnels through `@war/logic` via the `logic.ts` adapter; new rule-dependent behavior must be added to the shared engine (and kept in GDScript parity), not here.
- Determinism parity is the contract: `@war/logic` (TS) and `game/logic` (GDScript) produce byte-for-byte identical canonical JSON and the identical 64-hex 8-lane rolling state hash. A correct client prediction therefore always yields hashMatched === true; any divergence breaks the fast path and the golden vectors.
- Synchronized state and actions are canonical-JSON STRINGS on the wire, never proto/structured messages — that exact string IS the hash domain. Always serialize with `canonicalStringify` from the engine, never `JSON.stringify`.
- Matches are player-bound: every action asserts the caller's identity equals the match's bound `playerId` (PlayerBindingError otherwise), and a completed match rejects further actions (FAILED_PRECONDITION). The local-dev `?token=<player-id>` path and the deployed gateway-stamped `User-Id` path are behaviorally identical so the client has ONE codepath.

## Synced commit
_None._
