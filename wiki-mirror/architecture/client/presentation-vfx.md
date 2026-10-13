# Presentation & VFX

**Status:** current

## Kind
component

## Summary
The native Godot presentation layer for the game table: the two deck piles and their counts, the face-down/flip card-reveal slots, the dramatic WAR overlay ("I. DECLARE. WAR."), the game-over result overlay, and the casual card-game styling drawn from the reference prototype — a neutral *gray* table, steel-*blue* card backs, off-*white* faces with black ink, an *orange* accent for the primary action, and *green/red* win-loss outlines on revealed cards. It is a pure consumer of match state and produces none of its own.

## Purpose
To turn the synchronized, hashed game state into the visible, animated table the player interacts with, and to surface *the flip moment* — the pre-reveal window where a Special Card can be staged — which is the game's core hook and monetization surface. It keeps all rendering and VFX on the presentation side of the hard wall so that no rule logic ever leaks into the view, and conversely the view never authors authoritative state. `main.gd` is a developer/headless shortcut that boots straight onto the table (bypassing the lobby) by driving `UiRouter`; `table.gd` is the only screen that touches a running match, and only via the `WarMatch` controller, never the rules engine.

## Design notes
Data flow is strictly one-way: input goes to a WarMatch action, which runs WarEngine.apply (pure) to produce a new state plus hash, after which WarMatch emits state_changed(state) and the screen calls _render(state). The screen reaches WarMatch only through thin helper calls guarded by has_method/has_signal, and loads the controller lazily from res://game/match_controller.gd so a missing or in-progress controller degrades gracefully into a schematic empty table rather than crashing.

The palette is the casual card-game look from the reference prototype (the mockups under ~/projects/thirdparty/War/docs), centralized in WarPalette (game/ui/ui_palette.gd) as the single source of truth: a neutral gray table (9e9e9e), steel-blue card backs (5b7fb0) with a darker blue border, off-white card faces (f4f4f4) with near-black ink and borders (1a1a1a), an orange accent (ee7e2d) for the primary action button, light panels for secondary buttons, and green/red (3fa34d / c0392b) outlines that mark the winning and losing card after a flip. White panels carry the modal banners. This is the GAME look and is deliberately distinct from the vendored editor_tool_kit's violet editor theme. A card slot renders a steel-blue back when face-down (the flip moment) and a light face showing rank plus a suit glyph (red suits tinted) when revealed. Current gameplay rendering is intentionally schematic (counts, a single flip slot per side, and overlays) with TODO(skeleton) markers for the polish passes: the face-down/flip reveal animation, the WAR stake animation with war_depth pips and the 3-down/1-up reveal, and the Special-Card picker drawer that is the monetization surface.

The WAR overlay is shown whenever phase == war: a dim scrim behind a white banner carrying the war cry I. DECLARE. WAR. underlined by the orange accent. The result overlay covers phase player_win / cpu_win with a white banner reading VICTORY (green) or DEFEAT (red) and a continue-to-lobby button, mirroring the reference game-over mockup. Leaving the table records the played match via GameState.record_match_played() and routes home through UiRouter; main.gd offers a headless shortcut runnable as godot --headless --path game res://scenes/main.tscn.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `_render` in `game/ui/screens/table.gd`
- function `_on_state_changed` in `game/ui/screens/table.gd`
- function `_build_war_overlay` in `game/ui/screens/table.gd`
- function `_sync_actions` in `game/ui/screens/table.gd`
- `game/scenes/main.gd`

## Data model
The screen reads the synchronized game-state dictionary `{ version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot, rng:{seq}, specials:{player,cpu}, pending_special, war_depth }`, where `phase ∈ dealt | selected | flipped | war | player_win | cpu_win` and each `Card = { rank:2..14, suit, face_up }` with deck index `0` = top. It derives every visual from the most recently rendered `_state` dictionary and holds no authoritative state of its own. A flip slot shows the staked face-up pot card if present, else the top deck card, else a dash; `face_up=false` renders the arcane card back (the flip moment). The action buttons are computed from `phase`, `pending_special`, and `specials.player`: the *Play Special* button is legal only at `dealt` with an owned, unstaged special, and the single primary button cycles `FLIP → RESOLVE → DECLARE WAR` (ack) by phase.

## Usage
_None._

## Invariants & constraints
- Presentation reads state and writes none: the table reacts to WarMatch.state_changed and the lone render entry point _render(state) is the ONLY place match state is read. Input maps strictly to WarMatch actions (flip, resolve, ack_war, play_special, start_round); the screen never re-implements rules or mutates authoritative state.
- _render(state) is total and idempotent: an empty {} state renders a valid idle/empty table, so the screen loads and stays coherent even before a match exists or while WarMatch is being authored in parallel (schematic-degraded mode).
- The flip moment is the only window for staking a Special Card: the Play Special button is enabled solely in phase dealt, when no special is already pending and the player owns at least one — i.e. face-down, pre-reveal.
- scenes/main.gd is a debug-only entry point, NOT the project entry point (the real main scene is ui/boot.tscn); it stays pure bootstrap, driving UiRouter and never touching deterministic state.

## Synced commit
_None._
