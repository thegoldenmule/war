# ADR-2: Optimistic client updates with authoritative validator reconciliation

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** client/validator

## Context
The core hook of War is the *flip moment*: because cards are dealt face-down, the player chooses whether to play a collectible Special Card *before* the reveal. That moment must feel instant — any perceptible lag between tapping a Special Card (or committing a flip/war) and seeing the board respond would gut the snappiness that makes the loop addictive and undermines the monetization surface built on top of it.

At the same time, the server must remain *authoritative*. Because Special Cards drive gems, gacha, and IAP, there is direct financial incentive to cheat — a client that could forge favorable reveals, rig war outcomes, or fabricate card grants would corrupt economy integrity and leaderboards. We cannot trust the client's claimed result.

These two forces — *instant local feedback* versus *server-side authority against a tampered client* — are in tension. A naive request/response design (wait for the validator before showing anything) is safe but laggy; a pure client-authoritative design is snappy but exploitable. We already have a hard wall between a pure deterministic rules engine and presentation, with the GDScript engine being byte-for-byte hash-identical to the TypeScript validator engine (same canonical JSON, same 8-lane rolling state hash), which makes a third option viable.

## Decision
Apply each player action (flip, Special Card play, war stake) to the local deterministic engine immediately for instant UI feedback, then send the action plus the client's predicted post-action state hash to the authoritative validator over the Hermes gRPC/WebSocket channel. If the validator's recomputed hash matches the predicted hash, it ACKs the fast path and the optimistic state stands. If the hashes mismatch, the validator returns the authoritative state and the client discards its optimistic prediction and snaps to the authoritative state. Determinism parity (the hash-identical GDScript and TypeScript engines over identical canonical JSON and the same 8-lane rolling state hash) is what makes the matching-hash fast path the common case rather than the exception.

## Consequences
The flip moment feels instant — actions resolve on-screen with zero round-trip latency — while the validator remains authoritative, so cheating (forged reveals, rigged wars, fabricated card grants) is caught by the hash mismatch and corrected, protecting economy integrity and leaderboards.

The client must implement reconciliation/rollback: it has to retain enough state to discard an optimistic prediction and snap to the authoritative state on a hash mismatch, and the presentation layer must gracefully handle a visible correction (e.g. animating the board back to the server's truth) without confusing the player.

Correctness now depends entirely on determinism parity between the GDScript and TypeScript engines. Any divergence in canonical JSON serialization or the 8-lane rolling state hash produces spurious mismatches that force needless rollbacks, so engine parity becomes a hard, continuously-tested invariant rather than a nice-to-have.

## Relations
_None._
