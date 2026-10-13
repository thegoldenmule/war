# Byte-for-byte determinism parity between the GDScript engine and the TS validator

**Status:** accepted

## Metadata
- **Number:** ADR-1
- **Date:** 2026-06-17
- **Scope:** engine/validator

## Context
The client must be **playable offline** — the player should be able to deal, reveal, trigger WARs, and play Special Cards with zero network round-trips — yet every game must be **validated authoritatively online** to keep the meta layer (gems, gacha, leaderboards, IAP) honest. The naive path is a bespoke server protocol that re-encodes each rule as a request/response, but that couples the wire format to every rule change, drifts out of sync between client and server, and makes offline play a second-class citizen. The forcing tension: we want one rules engine the client can run locally *and* the server can re-run authoritatively, with a cheap, unambiguous way to detect when the two disagree.

## Decision
Keep game/logic (GDScript) and validator/src/logic (TypeScript) behaviorally identical: the same state schema, the same canonical JSON serialization, and the same 8-lane rolling state hash. Because both engines produce byte-for-byte identical canonical JSON and therefore the same 64-character state hash for any sequence of moves, the client and the validator can agree on the entire game state by comparing a single hash rather than exchanging or diffing full state. This is the hard wall between the deterministic rules engine and presentation: rules live only in the engine, and the wire never carries rule semantics, only moves and a hash.

## Consequences
Neither engine may be changed without the other: any rule, schema, or serialization change must be applied to both game/logic and validator/src/logic in lockstep, and the parity vectors must be re-run to prove byte-for-byte agreement before the change ships.

The canonical JSON layout and the 8-lane rolling state hash rules are frozen: their key ordering, encoding, and lane-mixing are part of the contract, so they cannot be refactored or 'optimized' independently in either language without breaking parity across all historical and future games.

Optimistic play with cheap reconciliation becomes possible: the client plays locally and offline, and reconciliation against the authoritative validator reduces to comparing one 64-character hash — no bespoke per-rule server protocol and no full-state diffing are required.

## Relations
_None._
