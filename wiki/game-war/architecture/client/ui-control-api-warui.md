# UI Control API (WarUi)

**Status:** current

## Kind
module

## Summary
`WarUi` is the UI/navigation analog of **WarDebug** — the menu-driving counterpart to WarDebug's gameplay-driving (WarDebug owns in-match board/cards; WarUi owns everything around the match). An autoload singleton (`WarUi`) driven via the godot-ai MCP `game_eval`, it gives explicit, named access to every screen and button plus **deterministic ordered sequences**: navigate to any screen by name, press any registered control by stable id, and run scripted step lists — all through the real router + screens, so transitions, fades, and screen builds happen exactly as they do for a player.

## Purpose
Gameplay was already drivable semantically (WarDebug), but the **menu/shell layer had no semantic driver** — reaching a screen or pressing a button meant reading pixel rects and clicking coordinates: slow, layout-dependent, and **not deterministic** (async tweens, generic/auto node names, duplicate names like the avatar picks). WarUi closes that gap. Two facts make it clean: the navigation layer (`UiRouter`) is an **async stack-FSM** whose push/pop await their lifecycle hooks + the cover/reveal fades, and `game_eval` itself awaits the eval coroutine — so `await WarUi.goto(...)` / `run([...])` return only once the destination is actually live. Control ids come from **WarUiReg** (registration as a byproduct of construction), so the catalog is self-maintaining.

## Design notes
```gdscript
# A scripted session (run via game_eval).
return WarUi.state()                 # {screen:"home", route:["shell"], ...}
return WarUi.actions()               # home.* + nav.*

# Open Settings, set the avatar + volume, rename:
return await WarUi.run([
    {"flow": "set_avatar", "params": {"id": "skull_avatar_05"}},
    {"set": "settings.music", "to": 0.4},
    {"text": "settings.name", "to": "Spectre"},
    "press:settings.save_name",
])

# Start a match and play (UI -> gameplay handoff):
return await WarUi.run(["goto:home", "flow:start_infinite", "swipe:up", "swipe:left"])
return WarDebug.inspect()            # WarDebug owns in-match board/cards

return await WarUi.goto("shell")     # leave (validator completion + router pop, awaited)
```

```gdscript
# Make a new control addressable — registration via WarUiReg, a byproduct of building it.
const Reg := preload("res://ui/mcp_ui_reg.gd")
Reg.screen(self, "settings")                       # mark a screen root (group + id)
var save  := Reg.button("save_name", parent, "Save")    # -> Button, registered
var music := Reg.slider("music", parent)                # -> HSlider
var hap   := Reg.check("haptics", parent, "Haptics")    # -> CheckButton
Reg.adopt(_story, "story")                         # adopt a .tscn / pre-built node
# It then appears in WarUi.actions() and is pressable by id — no hand-written set_meta.
```

Known edges. (1) press() does not await router transitions — it emits the control's signal and returns; a launcher's push or the match exit runs async, so use goto()/run() for awaited navigation (run settles after each press, which covers a launcher push). (2) One-frame visibility race: right after a modal opens, actions() may briefly omit its controls until it settles; press()/resolve() are unaffected (they ignore visibility), so sequences are reliable. (3) The driver resolves UiRouter / WarDebug via get_node_or_null("/root/...") (not the global identifier), so the script compiles and its pure surface (catalog/actions/press) runs even outside the full app — e.g. the headless verifier tools/verify_ui_driver.gd.

## Components
_No components._

## Dependencies
- **depends-on** → [Game Control API (WarDebug)](architecture:mqjwv82c-00l8-rn1hje) — Delegates in-match gameplay (swipe) to WarDebug, so one run() sequence can navigate and play.

## Code references
- file `WarUi (autoload)` in `game/game/mcp_ui_api.gd`
- class `WarUiReg` in `game/ui/mcp_ui_reg.gd`
- file `headless smoke` in `game/tools/verify_ui_driver.gd`

## Data model
`actions()` is the discovery surface: each entry is `{id, kind, enabled, visible, + value/on/text}`, with `kind ∈ button | toggle | slider | text | texture_button`, filtered to visible+in-tree unless `all`. `state()` returns `{busy, route:[…], route_depth, tab, screen, modal, match_ready}` — `screen` is `match` while a match is live else the active tab id; `modal` is `avatar` while the picker is open, else `""`.

**Registration (WarUiReg, `ui/mcp_ui_reg.gd`):** registration is a byproduct of construction — screens build their actionable controls through `WarUiReg` (or hand it an existing `.tscn` node via `adopt`), and each control is recorded on the **live tree** (an `mcp_id` meta + the `mcp_control` group, with the screen root grouped under `mcp_screen`). A control belongs to its **nearest** `mcp_screen` ancestor, so a modal nested under another screen (the avatar picker under Settings) forms its own screen. The driver walks that live tree, so the registry is self-cleaning (the freed match scene drops out) with no central state. Factories cover the actionable kinds only (Button / TextureButton / CheckButton / HSlider / LineEdit) and return the bare control so the screen keeps its own styling.

## Usage
Every call goes through the godot-ai MCP `game_eval`. Navigation is **async** — `game_eval` awaits the eval coroutine, so `await WarUi.goto(...)` returns only once the destination screen is live (the router transition + ~0.18s fades complete).

1. **Start the game** (`project_run`; main scene `ui/boot.tscn` → the shell). `WarUi` is live whenever the shell is mounted (`WarUi.is_ready()`).
2. **Call it** (use `await` for anything that navigates) — e.g. `return WarUi.state()`, `return WarUi.actions()`, `return await WarUi.goto("settings")`, `WarUi.press("settings.avatar")`, `return await WarUi.run([...])`. A worked sequence is in **Design notes**.
3. **See the result** with `editor_screenshot` (`source:"game"`).

### Reads (non-mutating)
| Method | Returns |
| --- | --- |
| `is_ready()` | bool — true when the shell is mounted |
| `state()` | `{busy, route:[…], route_depth, tab, screen, modal, match_ready}` — the one situational read |
| `screens()` | static catalog of `goto` targets (`tabs`, `modes`, `surfaces`) |
| `actions(all=false)` | **the discovery surface** for `press`: every pressable thing on the live screen, by id |
| `flows()` | **the named-flow catalog** for `flow`: `{name, params, summary, steps}` per flow |
| `help()` | command summary |

`actions()` returns, per control, `{id, kind, enabled, visible, + value/on/text}` with `kind ∈ button \| toggle \| slider \| text \| texture_button`, filtered to visible+in-tree unless `all`. **Never guess an id — read it from `actions()`.** Likewise, **never guess a flow — read it from `flows()`** (each entry carries its `params` and a `steps` preview).

### Navigation (awaited)
| Method | Returns |
| --- | --- |
| `goto(target)` | navigate to a screen by name; returns `state()` once it's live |

`target` is a tab (`collection`/`leaderboard`/`home`/`guilds`/`settings`), a mode (`story`/`infinite`), or a surface (`shell`/`back` to exit a match). `goto` pops a match first when needed, then selects the tab / launches the mode, awaiting throughout. Leaving a match runs the same validator-completion + router-pop path the in-match exit button does.

### Control invocation (not awaited — see Design notes)
| Method | Returns |
| --- | --- |
| `press(id, force=false)` | activate a button / texture-button / toggle |
| `toggle(id, on=true)` | set a CheckButton on/off |
| `set_value(id, v)` | set a slider (Range) value |
| `set_text(id, s, submit=false)` | set a LineEdit; `submit` fires `text_submitted` |

`press` resolves an id from the registry **regardless of visibility** and emits the control's real signal. It does **not** await router transitions — use `goto` (or a `run` step) to start/leave a match deterministically.

### Sequences & flows (awaited)
| Method | Returns |
| --- | --- |
| `run(steps, opts={})` | run an ordered list of steps; returns a per-step trace |
| `flow(name, params={})` | expand + run a named flow (see `flows()`); returns the `run` trace |

`run` stops on the first failed step unless `opts.continue_on_error`. Each trace entry is `{ok, step, result/sub, screen_after}`.

**Step forms** (strings for the common case, dicts when a value is needed):

| String | Dict | Effect |
| --- | --- | --- |
| `"goto:settings"` / `"tab:home"` / `"start:story"` | `{goto:"settings"}` | navigate (awaited) |
| `"exit"` | — | `goto("shell")` — leave a match |
| `"press:home.story"` | `{press:"home.story", force?}` | press, then settle |
| `"toggle:settings.haptics"` | `{toggle:"settings.haptics", on:false}` | set a toggle |
| — | `{set:"settings.music", to:0.3}` | slider value |
| — | `{text:"settings.name", to:"Spectre", submit?}` | text field |
| `"swipe:up"` | `{swipe:"up"}` | gameplay (delegates to WarDebug) |
| `"wait:0.5"` | `{wait:0.5}` | sleep N seconds |
| `"flow:start_story"` | `{flow:"set_avatar", params:{id:"skull_avatar_03"}}` | run a named flow |

**Named flows** (call `flows()` for the live catalog): `start_story`, `start_infinite`, `open_settings`, `open_leaderboard`, `exit_match`, `sign_out`, `set_avatar{id}`, `rename{name}`, `set_volume{music?, sfx?}`.

### Screen & id catalog
Ids are `"<screen>.<control>"`. The live set always comes from `actions()`; this is the map of what exists.

| Screen | Ids |
| --- | --- |
| `nav` (bottom bar) | `nav.collection` `nav.leaderboard` `nav.home` `nav.guilds` `nav.settings` |
| `home` | `home.story` `home.infinite` `home.pvp` (disabled) |
| `settings` | `settings.avatar` `settings.name` `settings.save_name` `settings.music` `settings.sfx` `settings.haptics` `settings.sign_out` |
| `avatar` (modal) | `avatar.skull_avatar_01` … `avatar.skull_avatar_12` |
| `leaderboard` | `leaderboard.daily` `leaderboard.weekly` `leaderboard.monthly` |
| `match` | `match.exit` |
| `collection` / `guilds` | placeholder screens — no controls yet |

## Invariants & constraints
- Control ids are recorded on the live tree by WarUiReg (an mcp_id meta + mcp_control group; screen root grouped mcp_screen) — self-cleaning, so the freed match scene drops out and there is no central registry to prune. New actionable controls register as a byproduct of construction, never a hand-written set_meta.
- Navigation is deterministic: UiRouter push/pop await their lifecycle hooks + cover/reveal fades and game_eval awaits the eval coroutine, so await goto()/run() return only once the destination screen is live — no screenshots-to-confirm, no sleep-and-hope.

## Synced commit
717bea1
