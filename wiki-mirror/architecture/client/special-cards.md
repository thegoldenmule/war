# Special Cards

**Status:** current

## Kind
component

## Summary
**WarSpecialCards** is the collectible power-up subsystem — Balatro-style cards a player can spend around a flip to bend a round in their favor. Effects resolve *inside* the deterministic engine so they stay hash-parity-safe between the GDScript and TypeScript twins, making the play-a-Special decision the game's central flip-moment hook and primary monetization surface.

## Purpose
Special Cards turn the otherwise-fixed War flip into a *decision*: because cards are dealt face-down, the player gets a window before the reveal to play a power-up. This subsystem owns the resolution of those power-ups — applying an effect to a copy of the engine state, consuming the card from the player's owned list, and emitting events the presentation layer animates. Resolving effects authoritatively in the shared rules engine (rather than in the client) is what lets a gacha/IAP economy hang off them safely: the validator independently recomputes the same result, so a tampered client cannot fabricate an advantage.

## Design notes
Extension point: a new Special is added by (1) appending its entry to validator/content/card_catalog.json (and the baked client copy), (2) adding its id to WarConstants.SPECIAL_CARDS / SPECIAL_CARD_IDS, (3) adding a branch to WarSpecialCards._apply keyed on the id, and (4) if it is a post-flip / on-resolve effect, teaching WarEngine.resolve (and ack_war where relevant) to honor the pending_special marker. The GDScript and TypeScript engines must be extended in lockstep, and a golden vector generated from the real TS dist before committing.

WarSpecialCards is a pure static utility (class_name WarSpecialCards extends RefCounted) with zero Node or scene dependencies, so it is headless-loadable and lives entirely within the deterministic logic layer. Catalog discovery for the engine, validator, and UI goes through ids(), catalog(), and is_valid_id().

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarSpecialCards` in `game/logic/special_cards.gd`
- function `resolve` in `game/logic/special_cards.gd`
- function `_apply` in `game/logic/special_cards.gd`
- `validator/content/card_catalog.json`
- constant `SPECIAL_CARDS` in `game/logic/constants.gd`

## Data model
Each Special is a catalog entry `{ id, name, when, rarity, desc }`. The canonical catalog lives at `validator/content/card_catalog.json` (version-stamped) with a baked client copy mirrored in `WarConstants.SPECIAL_CARDS`; insertion order is load-bearing for parity. The `when` field tags *when* the effect resolves relative to the flip: `pre_flip` cards resolve fully in place (e.g. `peek` flips the player's staged top card face-up so its rank is known) and clear `pending_special`; effects that need cooperation from the engine's resolve step (e.g. `steal_tie`) instead set `state.pending_special = id` so `WarEngine.apply(resolve)` can read and consume the marker at resolution time. Resolution flows through `WarSpecialCards.resolve(state, special_id)`, which returns the standard `{ ok, state, events, error }` result against a deep copy of the input state. Note: `card_catalog.json` ships richer flavor entries (e.g. `on_tie`, `on_war`, `legendary` rarities), but only `peek`, `rank_boost`, and `steal_tie` are wired into the engine dispatch today; unimplemented ids fall through to `special_not_implemented`.

## Usage
_None._

## Invariants & constraints
- Special-card effects are validator-authoritative and deterministic: WarSpecialCards resolution must be byte-for-byte equivalent to the TypeScript special_cards.ts, so the client's optimistic result reconciles exactly against the validator's recomputation.
- resolve() never mutates the input state across the hash boundary — it operates on state.duplicate(true) and returns a NEW state, mirroring the WarEngine.apply contract.
- A Special is consumed exactly once per play: resolve() removes the first matching id from state.specials.player and fails with special_not_owned if the player does not hold it (caller WarEngine remains responsible for phase/ownership legality).
- Effects must respect the engine's legal domains — e.g. rank_boost clamps the boosted rank at RANK_MAX (14) so an Ace cannot exceed the legal 2..14 rank range.

## Synced commit
_None._
