# Crypto & Signing

**Status:** current

## Kind
component

## Summary
The trust boundary of the validator: a shared-secret configuration that gates how caller identity is established, and *hash verification* of submitted moves, where the state hash recomputed from canonical JSON is the sole arbiter of whether a client's optimistic prediction is accepted or flagged as an authoritative mismatch.

## Purpose
It exists to make the server the *single source of truth* without trusting the client. The client plays optimistically and predicts the next-state hash; the validator re-runs the same deterministic `@war/logic` engine over the authoritative state and compares its freshly computed hash to the client's `predictedHash`. A match means the prediction stood and the fast path is taken; a mismatch hands the client the authoritative state to snap back to. The shared secret (`VALIDATOR_SHARED_SECRET`) defines *who* is allowed to act: when present it verifies gateway-stamped identity in production, and when empty it drops to a local trusted-token mode keyed on `?token=<player-id>`.

## Design notes
Config fails fast at boot: loadConfig validates ports and throws on any structural problem (non-integer/out-of-range port, or PORT equal to GRPC_PORT) so a misconfigured trust boundary cannot start serving requests. The shared secret is read and trimmed but its mere presence is what flips the service out of local mode; an all-whitespace value is treated as unset.

Determinism parity is what makes hash verification meaningful. Because the TypeScript @war/logic engine is byte-for-byte equivalent to the GDScript game/logic engine — same canonical JSON serialization and the same rolling state hash — a correct client prediction deterministically yields hashMatched === true. Any divergence in rules, serialization, or float handling between the two engines would surface here as spurious mismatches, so this boundary doubles as a cross-engine conformance check.

simulateAction performs the same engine re-run and hash computation but never persists and always returns hashMatched: false, since a dry run does not advance the authoritative timeline; it is a debug/MCP affordance for previewing the engine verdict and resulting hash without touching the trust boundary's state.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- interface `ValidatorConfig` in `validator/src/validator/config.ts`
- function `loadConfig` in `validator/src/validator/config.ts`
- constant `config` in `validator/src/validator/config.ts`
- function `ValidatorService.validateAction` in `validator/src/validator/service.ts`
- function `ValidatorService.simulateAction` in `validator/src/validator/service.ts`

## Data model
Configuration is the immutable, `Object.freeze`d `ValidatorConfig`, resolved once at import time by `loadConfig`. Its security-relevant fields are `sharedSecret` (trimmed `VALIDATOR_SHARED_SECRET`, empty string meaning unset) and the derived `isLocal` boolean (`sharedSecret === ""`). Verification itself carries no separate persisted model: the comparison is `predictedHash !== "" && predictedHash === updated.hash`, where `updated.hash` is the rolling state hash computed over the canonical JSON of the authoritative post-action state produced by `applyAndPersist`.

## Usage
_None._

## Invariants & constraints
- The hash compared against the client is ALWAYS recomputed by the server from the authoritative state's canonical JSON (via stateHash over canonicalStringify) — the client-supplied predictedHash is never trusted, only compared.
- An empty predictedHash never counts as a match: hashMatched requires predictedHash !== "" AND predictedHash === updated.hash, so a missing/blank prediction always reconciles as a mismatch rather than silently passing.
- A hash mismatch is non-authoritative on its own: a legal action is still persisted and advances the timeline; hashMatched: false only tells the client its prediction diverged and to snap to authoritativeStateJson. Only the rules engine rejecting an action (ok: false) leaves the authoritative state unchanged.
- isLocal is true exactly when VALIDATOR_SHARED_SECRET is empty after trimming; production identity verification via the shared secret is bypassed only in this local trusted-token mode, never silently in a configured deployment.

## Synced commit
_None._
