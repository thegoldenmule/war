# Game Control API (WarDebug)

**Status:** current

## Kind
module

## Summary
`WarDebug` is the game-semantic control layer for LLM/automation — the Godot analog of the TypeScript game's `window.__moveborne` debug API. An autoload singleton (`WarDebug`) driven via the godot-ai MCP `game_eval` command, it drives the running game **by game concepts** (swipe a direction, read the board, play a card with targeting) instead of pixel taps and scene-tree walks. Plays route through the real match scene, so the board, hand, and VFX animate exactly as they do for a human. Its UI/navigation counterpart is **WarUi** (the UI Control API) — `WarDebug` owns in-match board/cards; `WarUi` owns everything around the match.

## Purpose
Let an LLM (or any automation) play and inspect Moveborne the way a human does — for driving and verifying the game. `WarDebug` is a **thin facade**: all mutation routes through the live match scene (`scenes/main.gd`'s `mcp_*` methods), which reuse the exact targeting state machine the player uses, and all reads come off the live `WarMatch.state`. Nothing under `logic/` is touched, so **determinism parity is unaffected**. It mirrors the web build's `window.__moveborne` (`moveborne/src/game/components/match/Play.tsx`).

## Design notes
```gdscript
# get_state() returns the live WarMatch.state (game/game/match_controller.gd):
state = {
  board:  { tiles: [ tile, ... ],  size: int },     # row-major: idx = row*size + col
  hand:   { cards: [ card, ... ] },
  deck:   { remainingCards: int, nextCardIndex: int },
  score:  int,
  shards: int,                # 0-8; auto-draws a card at 8
  comboMultiplier: int,
  moveIndex: int,             # +1 per action (+2 when an auto-draw fires during a swipe)
  totems: { active: [ ... ] },
  randomSeeds: { "tile-gen":int, "shuffle":int, "effect-spawn":int, "totem-spawn":int, "card-draw":int },
  rngIndices:  { ... same 5 namespaces ... },
  # scenario-only: scenarioConfig, eventTriggerStates, globalEffects
}
```

```gdscript
# A scripted session (each line is one game_eval call).
WarDebug.load_scenario(3)
return WarDebug.inspect()                 # {scenario, move_index:0, board_size, ...}

return WarDebug.get_playable_cards()      # [{index, type, name, selection_mode}, ...]
WarDebug.swipe("up")
WarDebug.swipe("left")

# A targeted card: bomb -> awaiting_selection:tile -> supply a tile.
return WarDebug.play_card(0)              # {"status":"awaiting_selection","selection_mode":"tile"}
return WarDebug.select_tile(2, 1)         # {"status":"complete"}

return WarDebug.get_history_count()       # grows by 1 per committed move
return WarDebug.get_snapshot(2)           # state at moveIndex == 2
```

Known differences from the web build's window.__moveborne: snake_case (get_state) vs camelCase (getState); is_ready() is a method, not a property. moveborne's help() advertises a one-call playCard(cardIndex, row, col), but the real implementation — and WarDebug — is the two-step play_card(i) then select_tile/select_column. History lives in the facade (snapshot-on-changed), not the engine. WarDebug adds new_game / load_scenario / cancel, since scenarios and the intro are driven by the Godot scene.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarDebug` in `game/game/mcp_game_api.gd`
- function `mcp_swipe / mcp_play_card / mcp_select_target` in `game/scenes/main.gd`
- class `WarMatch` in `game/game/match_controller.gd`

## Data model
`get_state()` returns the live `WarMatch.state` (`game/game/match_controller.gd`); its full shape is shown in **Design notes**. `board.tiles` is a flat **row-major** Array (`idx = row*size + col`). **Tile** (`logic/engine.gd`): `{ isEmpty, value, row, col, status, meta, effect? }` — `value` is a power of two; `effect` is present on tiles with an active effect (lock / freeze / black_hole / …); empty cells have `isEmpty: true`. **Card**: `{ id, type, name?, isTotemCard?, spawnsTotem?:{id}, … }` — `type` is the power-card action string. `moveIndex` advances +1 per action (+2 on auto-draw); RNG state lives in `rngIndices` across 5 namespaces; `shards` 0–8 auto-draws a card at 8.

## Usage
Every call goes through the godot-ai MCP `game_eval` command, which runs a GDScript snippet inside the running game and returns the JSON-serialized result.

1. **Start the game** (`project_run`, or open `scenes/main.tscn` and Play) — `WarDebug` is live only while the game runs.
2. **Call it** with a snippet that `return`s a value — e.g. `return WarDebug.is_ready()`, `return WarDebug.get_state()`, `WarDebug.swipe("up")` (mutate, no return needed), then `return WarDebug.play_card(2)` (→ `awaiting_selection`) followed by `return WarDebug.select_tile(1, 3)` (→ `complete`). A full session is in **Design notes**.
3. **See the result** with `editor_screenshot` (`source:"game"`). When no match scene is live, methods return `{"ok": false, "reason": "not_ready"}`.

### Movement (mutating — routes through the UI, animates)
| Method | Returns |
| --- | --- |
| `up()` / `down()` / `left()` / `right()` | `{ok, moved, move_index}` |
| `swipe(direction)` | `{ok, moved, move_index}` — direction ∈ up/down/left/right |

`moved` is whether any tile shifted; the engine still advances (and may spawn a tile) on a non-moving swipe. Any in-progress card selection is cancelled first.

### Reads (non-mutating)
| Method | Returns |
| --- | --- |
| `get_state()` | full synchronized state Dictionary (see Data model) |
| `get_board()` | `{tiles:[…row-major…], size}` |
| `get_cards()` | `[{index, id, type, name}]` — the hand |
| `get_playable_cards()` | `[{index, type, name, selection_mode}]` — only currently-playable |
| `get_tile(row, col)` | tile Dictionary, or null if empty / out of range |
| `is_ready()` | bool — true when a match is live with a board |

### History
| Method | Returns |
| --- | --- |
| `get_history()` | Array of state snapshots, oldest first |
| `get_snapshot(move_index)` | snapshot whose `moveIndex == move_index`, or null |
| `get_history_count()` | int |

Snapshots are deep-copied on every committed move (it listens to `WarMatch.changed`); history resets when a new game/scenario starts.

### Cards (mutating — two-step targeting, through the UI)
| Method | Returns |
| --- | --- |
| `play_card(card_index)` | `{status, selection_mode?, message}` |
| `select_tile(row, col)` | `{status, …}` |
| `select_column(col)` | `{status, …}` |
| `select_card(card_index)` | alias of `play_card` |
| `cancel()` | `{ok}` — abort an in-progress selection |

`play_card` returns one of: `{status:"complete"}` (totem / no-target cards like shuffle, transform), `{status:"awaiting_selection", selection_mode:"tile"|"column"|"quadrant"|"two"}` (supply targets with `select_tile`/`select_column`), or `{status:"error", message}`.

### Lifecycle & utility
| Method | Returns |
| --- | --- |
| `new_game(seed=-1)` | `{ok, scenario, move_index}` — fresh Endless game (with intro) |
| `load_scenario(id, seed=-1)` | `{ok, scenario, board_size, move_index}` |
| `inspect()` | `{scenario, move_index, score, shards, combo_multiplier, cards, board_size, non_empty_tiles, history_count}` |
| `help()` | command list |

Pass an explicit `seed` for a reproducible match (the engine is deterministic).

### Power-card action & param reference
`play_card` + `select_*` build the engine params via `main.gd`'s `TARGET` map — the LLM never builds param dicts by hand. Taps each kind needs after `play_card`:

| Card `type` | `selection_mode` | Taps | Engine params |
| --- | --- | --- | --- |
| bomb / destroy / double / split / multiply / radiate | tile | 1 tile | `{tile:{row,col}}` |
| clear / lightning | column | 1 cell in column | `{column}` |
| vortex | quadrant | 1 cell = 2×2 top-left | `{row, column}` |
| swap | two | 2 tiles | `{tile1, tile2}` |
| clone / teleport | two | 2 tiles (target empty) | `{sourceTile, targetTile}` |
| shuffle / transform | none | 0 — plays at once | `{}` |
| _totem cards_ | totem | 0 — spawns a totem | via `spawn_totem` |

`time` / `magnet` have no engine action yet (reported as unplayable).

### Scenario ids (`load_scenario`)
`0`–`7` are built-in scenarios; `17` is "Fracture" (COMBO_BREAK ≥ 3 spawns the full-screen glitch global effect); `101` starts with a black-hole tile (consume-fly test).

## Invariants & constraints
- Parity-safe: WarDebug only calls already-tested WarMatch / main.gd paths and reads WarMatch.state; nothing under logic/ is touched, so determinism parity is unaffected.
- play_card is two-step: play_card(i) begins targeting and returns awaiting_selection; select_tile / select_column supply the targets — reusing the exact player targeting state machine, so plays animate the board, hand, and VFX normally.

## Synced commit
717bea1
