# UI & Meta Shell

**Status:** current

## Kind
component

## Summary
The meta shell that wraps the game: the *boot* main scene, the *UiRouter* autoload that swaps screens (home <-> table), the *GameState* autoload that holds cross-screen meta state (Gems, profile, settings mirror), and the screens themselves (lobby, game table, and disabled placeholders for shop / daily / leaderboard) with a currency bar. It is pure presentation and lives entirely on the player's side of the hard wall.

## Purpose
It exists to give the game a navigable front end and a place to keep meta-progression state that outlives any single match, *without* ever touching deterministic rules. The router owns screen lifecycle so screens never instantiate each other; GameState owns currency and profile so the currency bar and meta surfaces read one source of truth; the home lobby is the launch point into a match and the future entry to the monetization surfaces (shop, daily, leaderboard). Keeping all of this in a thin presentation layer is what lets the deterministic engine stay isolated and hash-identical to the validator.

## Design notes
Current implementation status (skeleton): the screens game/ui/screens/home.gd and game/ui/screens/table.gd exist and are functional, but the three autoload/boot scripts named in the brief — ui/boot.gd, ui/router/app_router.gd, ui/game_state.gd — are registered as the main scene and autoloads in project.godot yet have not been written to disk yet (the ui/router and ui/shell directories are still empty). The screens already program against the intended API: home.gd calls UiRouter.goto("table"), binds to GameState.gems and GameState.gems_changed, and renders disabled SHOP / DAILY / LEADERS placeholder tiles; table.gd calls UiRouter.goto("home") and GameState.record_match_played() on exit. scenes/main.gd is a separate debug entry that calls UiRouter.ensure_stage(self) then UiRouter.goto("table").

Styling: every screen builds its layout in _ready() and shares an occult-arcade palette (violet accent b400ff, hover d24bff, deep 43005d, green selection 44ff88 on near-black 13111c) that mirrors the vendored addons/editor_tool_kit palette. The .tscn files stay minimal (root node plus script) and the UI tree is constructed in code.

Rendering model on the table screen is strictly one-way: input drives a WarMatch action, WarEngine.apply produces a new state plus hash, WarMatch emits state_changed(state), and the screen re-renders from that state dictionary. The screen holds no authoritative state of its own and loads the controller lazily, degrading to a schematic empty table if WarMatch is unavailable.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- `game/ui/boot.gd`
- class `UiRouter` in `game/ui/router/app_router.gd`
- class `GameState` in `game/ui/game_state.gd`
- `game/ui/screens/home.gd`
- `game/ui/screens/table.gd`
- `game/scenes/main.gd`
- constant `autoload` in `game/project.godot`

## Data model
GameState is the meta-state store (an autoload), distinct from the hashed match state owned by WarMatch. It holds at least *gems* (soft-currency integer), a profile, and a mirror of user settings, and it emits *gems_changed(amount)* so the currency bar can stay live; screens also call lifecycle hooks such as *record_match_played()*. The router keeps a single mounted *stage* node and a notion of the current screen keyed by name ("home", "table"); *goto(name)* tears down the current screen and mounts the next. None of this meta state is canonical-JSON-serialized or hashed — only the match state crosses the validator boundary.

## Usage
_None._

## Invariants & constraints
- The UI shell is pure presentation: boot, the router, GameState, and screens NEVER re-implement rules or read/mutate deterministic match state directly — the table screen touches a running match only through WarMatch / the WarDebug autoload.
- Screen navigation goes exclusively through UiRouter.goto(name); screens do not instantiate or free one another. The router owns the single mounted stage and the current-screen lifecycle.
- GameState is the single source of truth for meta state (Gems, profile, settings mirror); the currency bar and any meta surface read it and react to its signals (e.g. gems_changed) rather than caching their own copy.
- The real entry point is res://ui/boot.tscn (set as the main scene in project.godot); scenes/main.gd is a debug-only direct-to-table shortcut that still drives the router and never bypasses it.

## Synced commit
_None._
