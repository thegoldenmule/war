# Client

**Status:** current

## Kind
subsystem

## Summary
The Godot 4.6 (GDScript) client: boot, the meta shell (home, shop, daily, leaderboard), and the game table that drives a single deterministic match against the CPU. It renders state and captures input but **never owns rules** — every gameplay change flows through `WarEngine.apply` via a unified action interface.

## Purpose
To be the *presentation and input* half of the hard wall between rules and rendering. The client exists to draw the current game state, capture player intent, and funnel that intent into the pure deterministic engine — playing **optimistically** for instant feedback while **reconciling** against the authoritative validator over Hermes. It deliberately holds no authority over the rules so that the GDScript engine stays byte-for-byte hash-identical to the TypeScript validator.

## Design notes
Boot and shell: project.godot sets res://ui/boot.tscn as the main scene and registers three autoloads — WarDebug (the deterministic-state debug and LLM control surface, game/mcp_game_api.gd), GameState (cross-screen UI state), and UiRouter (the meta-shell screen router). The display is configured portrait (720x1560, canvas_items stretch, expand aspect) under the GL Compatibility renderer for broad mobile reach. The meta shell screens (home, table) live under game/ui/screens.

Optimistic-by-default loop: input becomes an action, WarEngine.apply produces a new state plus hash which is adopted and rendered immediately; when online, WarValidatorClient.validate_action is called with the predicted hash. A matching hash is a silent fast-path ACK; a mismatch causes a snap to the authoritative canonical-JSON state and a reconciled emission so the UI re-renders from scratch rather than tweening from the discarded optimistic state. With no validator attached the match is fully playable offline because the deterministic engine is the source of truth.

Scaffolding status: as of this writing the boot script game/ui/boot.gd and the UiRouter autoload script are referenced by project.godot and this design but are not yet present in the tree; the match runtime is implemented as game/game/match_controller.gd (class WarMatch). Code references below point at the real and intended entry-point files named in the brief.

## Components
- [Rules Engine](architecture:mqiff9ri-00c1-bz5lp5)
- [Determinism Primitives](architecture:mqiffdep-00c3-wi8v9r)
- [Match Controller](architecture:mqiffgkq-00c5-u32a7j)
- [Validator Client](architecture:mqiffk7g-00c7-kfdofn)
- [Special Cards](architecture:mqiffocr-00c9-bmde8m)
- [Presentation & VFX](architecture:mqiffsj2-00cb-jel2kh)
- [UI & Meta Shell](architecture:mqiffwts-00cd-bm9ipe)
- [Editor Tool Framework](architecture:mqifg298-00cf-orkb2o)
- [Build & Distribution](architecture:mqifg5hx-00ch-km5tng)
- [Round Director](architecture:mqij0zl8-01dm-ekie5g)
- [Game Control API (WarDebug)](architecture:mqjwv82c-00l8-rn1hje)
- [UI Control API (WarUi)](architecture:mqjwvdio-00la-inyz89)

## Dependencies
_No dependencies._

## Code references
- `game/project.godot`
- `game/ui/boot.gd`
- class `WarMatch` in `game/game/match_controller.gd`

## Data model
The client owns no canonical game state of its own; the only hashed state lives inside `WarMatch`, which holds `_state` (the hash domain: version, seed, phase, decks, pots, rng seq, specials, pending_special, war_depth) plus its cached 64-hex `_hash`. The match exposes state only as a deep copy via `get_state()` so observers across the hash boundary cannot mutate canonical state. Cross-screen presentation state (currency, profile, settings mirror) lives separately in the `GameState` autoload, and screen routing lives in the `UiRouter` autoload — neither is part of the hashed contract.

## Usage
_None._

## Invariants & constraints
- Presentation mutates no game state directly: UI and scenes observe WarMatch through signals (state_changed, event, reconciled, action_rejected) and receive only deep copies; the canonical _state is mutated solely by WarEngine results.
- All input is unified as action messages: every gameplay change (new_game, start_round, play_special, flip, resolve, ack_war) is built via WarActions and submitted through the single WarMatch funnel, never applied ad hoc.
- Every gameplay change flows through WarEngine.apply: the client applies locally first (optimistic), then validates the predicted hash against the authoritative validator and snaps to the authoritative state on mismatch — it never edits state outside an engine result.
- Stale reconciles are dropped: a validation result is only allowed to snap state when its apply-sequence still matches the latest local apply, so a late authoritative response never rewinds past fresher optimistic input.

## Synced commit
_None._
