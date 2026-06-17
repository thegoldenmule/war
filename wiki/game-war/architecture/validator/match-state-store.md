# Match State Store

**Status:** current

## Kind
component

## Summary
The authoritative, per-match server state, keyed by match id and bound to the owning player. It holds the canonical copy of each live match — the deterministic state plus its cached canonical JSON and 8-lane state hash — that the optimistic client reconciles against.

## Purpose
Gives the validator a single source of truth for every live match so it can authoritatively answer *did this action advance the game, and to what hash?* It exists to (1) bind a match to its owning player for auth, (2) persist the result of each engine-applied action together with its canonical JSON and hash, and (3) serve cheap cached reads to history and debug surfaces. Crucially it owns *no rules*: it never decides legality or computes transitions itself — the service runs `@war/logic` and the store only caches the verdict.

## Design notes
The service layer (ValidatorService) is the only caller that drives the store through its lifecycle. initMatch computes the initial GameState from the seed via newGame and hands it to store.init. validateAction loads the record, parses a fresh copy of the persisted stateJson, runs applyAction over it, and on an ok verdict calls applyAndPersist; it then compares the recomputed authoritative hash to the client's predictedHash to set hashMatched, and auto-calls complete when the new phase is terminal. On an illegal move the store is left untouched and the unchanged authoritative state is returned so the client can snap back.

requireOpenMatch in the service combines getForPlayer with a completed check, raising FAILED_PRECONDITION if a caller tries to act on an already-finished match. Debug and MCP surfaces use the non-mutating helpers (get, has, all, summaries, simulateAction, delete) so previews and clears never touch the authoritative timeline.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `MatchStore` in `validator/src/validator/store/match-store.ts`
- constant `matchStore` in `validator/src/validator/store/match-store.ts`
- class `ValidatorService` in `validator/src/validator/service.ts`
- interface `MatchRecord` in `validator/src/validator/types.ts`

## Data model
Each match is a `MatchRecord` stored in a process-local `Map<matchId, MatchRecord>`. A record carries the immutable `matchId`, `playerId`, and `seed`; the current authoritative `state` (a `GameState`) alongside its cached `stateJson` (canonical JSON string) and `hash` (the determinism hash); a monotonic `appliedCount` cursor; a `completed` flag with an optional `finalPhase` recorded at completion; and `createdAt` / `updatedAt` epoch-millis timestamps. The cached `stateJson` and `hash` are recomputed together on every `applyAndPersist` so reads never re-stringify, and a lightweight `MatchSummary` projection (`toSummary`) feeds list/history endpoints. The store is a process-wide singleton (`matchStore`); a deployed validator would back it with a durable store instead of an in-memory Map.

## Usage
_None._

## Invariants & constraints
- Player binding is enforced on every mutating access: `apply` and `complete` go through `getForPlayer`, which throws `PlayerBindingError` if the caller's playerId does not match the record's bound playerId. Acting on another player's match is impossible.
- `stateJson` and `hash` are always kept consistent with `state` — they are recomputed atomically (via `canonicalStringify` / `stateHash`) in `init` and `applyAndPersist`, so the cached canonical string and hash never drift from the live state object.
- The store never computes game transitions or judges legality: it only persists an already-computed `nextState` handed in by the service after `@war/logic` ran. All rule authority lives in `@war/logic`.
- `init` refuses to overwrite an existing match id (throws), and `complete` is idempotent; completed records are retained (not deleted) so history endpoints and post-match flows can still read them.

## Synced commit
_None._
