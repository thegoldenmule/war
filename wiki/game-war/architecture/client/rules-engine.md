# Rules Engine

**Status:** current

## Kind
component

## Summary
**WarEngine** (`game/logic/engine.gd`) is the pure, deterministic phase machine at the heart of War. It builds and deals a match from a seed and executes every rule transition — `dealt -> selected -> flipped -> war -> player_win/cpu_win` — as pure functions over a synchronized state Dictionary, with **zero Node or scene dependencies**.

## Purpose
It encodes the *single source of truth* for the rules so the client can play optimistically while the validator re-checks authoritatively. Because `engine.gd` is the byte-for-byte deterministic twin of the TypeScript engine (`validator/src/logic`), both sides must produce the **same canonical JSON and the same 64-hex state hash** for any `(state, action)` pair; keeping the rules behind this hard wall is what makes hash-based reconciliation possible. It is intentionally headless-loadable so the same code runs in-editor, in headless verifiers, and on the server.

## Design notes
Phase transitions (the shared contract): from dealt, start_round stages the top card face-down on each side into the pots and moves to selected (the flip moment). From selected, a pre_flip play_special (e.g. peek) resolves in place, and flip reveals both staged cards; equal ranks escalate straight to war (war_depth = 1) while unequal ranks go to flipped. From flipped, a post_flip play_special (e.g. rank_boost, or arming steal_tie) is legal, and resolve compares the revealed cards, awards both pots to the higher rank, and returns to dealt. In a war, resolve is treated exactly like ack_war: each side stakes WAR_STAKE face-down plus 1 face-up decider, war_depth increments, and the higher decider takes the whole pot; another tie stays in war.

Awarding and win detection: _award_pots_to moves both pots (winner's pot first, then loser's, a fixed order for determinism) face-down to the bottom of the winner's deck and clears both pots. After every awarded round _check_win detects the terminal state where one side holds all 52 cards (the other empty), setting phase player_win or cpu_win. A war the loser cannot complete (fewer than WAR_STAKE+1 = 4 cards) is a forfeit that ends the match immediately; if both sides are short, the side with strictly more cards wins, ties on count resolving to cpu for determinism.

Special-card hook: pending_special carries an armed special id and is intentionally null after new_game and omitted from the hash by the canonical serializer. WarEngine._play_special delegates to WarSpecialCards.resolve; steal_tie, when armed, awards a tie to the player outright instead of triggering a war (checked at both flip and resolve).

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarEngine` in `game/logic/engine.gd`
- function `WarEngine.apply` in `game/logic/engine.gd`
- function `WarEngine.new_game` in `game/logic/engine.gd`
- constant `WarConstants` in `game/logic/constants.gd`
- class `WarActions` in `game/logic/actions.gd`
- class `WarValidation` in `game/logic/validation.gd`

## Data model
The synchronized, hashed state is a Dictionary: `{ version:int, seed:String, phase:String, player_deck:Card[], cpu_deck:Card[], player_pot:Card[], cpu_pot:Card[], rng:{seq:int}, specials:{player:String[], cpu:String[]}, pending_special:String|null, war_depth:int }`. A `Card` is `{ rank:int(2..14), suit:String, face_up:bool }` where 2..10 are pips and J=11, Q=12, K=13, A=14 (Ace high, plain integer compare, never wraps). **Deck index 0 is the TOP**; pots are append-ordered staging piles for the in-progress round. `new_game(seed)` builds the ordered 52-card deck (for each suit, for each rank), deterministically shuffles it via WarRng, and deals `DEAL_SIZE` (26) to each side, starting in phase `dealt`. `apply(state, action)` returns `{ ok, state, events, error }`: `events` is an ordered Array of small dicts describing what happened (for the UI to animate) and is part of the deterministic output but is NOT part of the hashed state. `war_depth` counts war escalations within a round (1 on the first tie, incremented on each subsequent tie); a war stakes `WAR_STAKE` (3) face-down cards plus 1 face-up decider per side.

## Usage
_None._

## Invariants & constraints
- Pure: apply() returns a NEW state and never mutates the input across the hash boundary — it deep-copies via state.duplicate(true) before any change, so callers may safely retain the prior state.
- Deterministic and hash-identical with the TypeScript engine: same canonical JSON, same 8-lane rolling 64-hex state hash, and same ordered events for the same (state, action). Iteration order (suits, ranks, the SPECIAL_CARDS catalog) and RNG draw order/count are load-bearing and must mirror TS exactly.
- No Node or scene dependencies — the engine is a static utility on RefCounted, headless-loadable and runnable identically in-editor, in headless verifiers, and on the validator.
- Every transition is phase-gated through WarValidation.check before execution; an illegal action returns { ok:false } with the unchanged input state, and only new_game is legal once a side has won (terminal player_win/cpu_win).

## Synced commit
_None._
