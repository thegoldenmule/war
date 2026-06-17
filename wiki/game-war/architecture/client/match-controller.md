# Match Controller

**Status:** current

## Kind
component

## Summary
*WarMatch* is the client-side match runtime: a `Node` that owns the live game-state `Dictionary`, drives it through the pure `WarEngine`, and bridges the deterministic core to UI and networking. It applies actions *optimistically* for instant feedback, sends the predicted hash to the validator, and snaps to the authoritative state on a mismatch, announcing all changes via signals. *WarDebug* is the headless/LLM driving surface — an autoload wrapping one WarMatch.

## Purpose
WarMatch exists to be the *single funnel* for all game input and the sole owner of canonical match state, keeping the hard wall intact: it touches no scenes and no UI widgets, speaking only to pure logic (`WarEngine`, `WarHasher`, `WarActions`) and, optionally, the validator (`WarValidatorClient`). Presentation observes it purely through signals. Its optimistic-then-reconcile model gives the player zero-latency feedback while still letting an authoritative server correct divergence. WarDebug exists because the deterministic core plus WarMatch make the whole game drivable *without any UI* — it is the documented programmatic entry point for headless verifiers, the in-editor console, and an LLM/agent driving the game through the godot-ai MCP.

## Design notes
Reconcile flow in detail. submit_action applies the action through WarEngine.apply, and on success bumps _apply_seq, adopts the new state, emits state_changed plus per-event signals, then (only when a validator is attached and online) fires _validate_async with the predicted hash and the captured seq. The validator can answer three ways: a matched ACK is a silent fast-path no-op; a mismatch snaps to the authoritative state via _reconcile_from_json and emits reconciled (unless a newer action has superseded it); a hard rejection with authoritative state also snaps, otherwise it surfaces action_rejected. new_game additionally calls init_match in the background so the server tracks the seed, but it does NOT overwrite the local deal on success — by the determinism parity contract the server's deal for the same seed is byte-identical, so a t0 hash divergence is treated as a determinism bug, logged loudly with push_warning, and snapped.

WarDebug autoload caveat. The script is registered as the WarDebug autoload in project.godot (WarDebug = "*res://game/mcp_game_api.gd"), so it is globally reachable as WarDebug everywhere. In Godot 4 a script registered as an autoload singleton MUST NOT also declare class_name WarDebug — the engine rejects it with "Class hides an autoload singleton" — so this file deliberately omits class_name; the autoload registration is the contract's WarDebug. It owns one WarMatch created in _ready, relays its three observation signals (state_changed, event, reconciled) outward, and by default runs OFFLINE (optimistic-only, no validator), which is exactly what headless determinism tests and LLM driving want; call attach_validator() to go online and detach_validator() to return to offline.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarMatch` in `game/game/match_controller.gd`
- function `submit_action` in `game/game/match_controller.gd`
- class `WarDebug` in `game/game/mcp_game_api.gd`
- function `snapshot` in `game/game/mcp_game_api.gd`

## Data model
WarMatch holds a small private set of fields. `_state` is the canonical game-state `Dictionary` (the hashed contract: `version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot, rng:{seq}, specials:{player,cpu}, pending_special, war_depth`), mutated only via engine results and never handed out directly — `get_state()` returns a deep copy across the hash boundary. `_hash` is the cached 64-hex hash of `_state`, refreshed by `_adopt_state` so it is never recomputed redundantly. `_validator` is the optional `WarValidatorClient` (null = offline/optimistic-only). `_apply_seq` is a monotonic counter of local applies used to drop stale reconciles. WarDebug adds `_match` (the single owned WarMatch) and `_event_log`, a rolling buffer of recent engine events capped at `EVENT_LOG_CAP` (256) for `snapshot()` introspection.

## Usage
Create a `WarMatch`, optionally `set_validator(...)` to go online, then `new_game(seed)` to deal and `submit_action(action)` to drive each move; read back state with `get_state()` / `get_hash()` and react to `state_changed` / `event` / `reconciled` / `action_rejected`. Through the autoload the same flow is `WarDebug.new_game("seed-123")`, `WarDebug.do({"type": "start_round"})` (or the wrappers `start_round()` / `play_special(id)` / `flip()` / `resolve()` / `ack_war()`), then `WarDebug.snapshot()` for a compact LLM-friendly view (hash, phase, deck counts, war depth, pending special, event tail).

## Invariants & constraints
- WarMatch never mutates `_state` in place: every state change flows through `_adopt_state`, which stores a deep copy and re-derives `_hash`, and all state handed to observers is a deep copy — external references can never bleed into the canonical hash domain.
- Every action is applied LOCALLY through the pure engine first (optimistic), and a rejected action leaves `_state` untouched; the validator is only ever consulted to confirm or correct, never to produce the local move — so the match stays fully playable offline.
- A reconcile is dropped if a newer local action has superseded it (the validation's `from_seq` no longer equals `_apply_seq`): WarMatch never rewinds past fresher optimistic state, relying on the next validation to correct it instead.
- `WarDebug.get_hash()` equals `WarHasher.hash_value(get_state())` and equals the hash the TypeScript validator computes for the same state; two runs of the same seed plus action sequence MUST yield identical hashes — the determinism assertion the verifier scripts depend on.

## Synced commit
_None._
