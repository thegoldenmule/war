# CLAUDE.md — working notes for the War Godot client

Godot 4.6 (GDScript) client for **War** (a hypercasual vs-CPU spin on classic War, with a
Balatro-style Special Card hook). See [`README.md`](README.md) for the overview and
[`ARCHITECTURE.md`](ARCHITECTURE.md) for the architecture, phase status, and the per-subsystem
source-of-truth map.

This directory is the **Godot project root**, so `res://` maps here: `res://logic/` = `logic/`,
`res://game/` = `game/`, `res://ui/` = `ui/`, `res://scenes/` = `scenes/`, `res://net/` = `net/`.

## Prime directive: determinism parity

`logic/` is the **byte-for-byte deterministic twin** of the TypeScript engine in
`../validator/src/logic/`: it computes the **same 64-hex state hashes** as the TS engine and the
validator service. Treat the parity tests as load-bearing.

- **Never change `logic/` behavior without re-running the parity tests.** If a golden hash
  changes, you broke compatibility — figure out why before committing.
- The TS package under `../validator/src/logic/` is the **source of truth** for golden vectors;
  generate oracles from its real dist, never hand-write expected hashes.
- When authoring/extending logic, mirror the TS exactly — iteration order, RNG draw order/count,
  and which fields are present in state. The two engines must never diverge.

The contract both sides implement (do not deviate):

- **State:** `{ version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot, rng:{seq},
  specials:{player,cpu}, pending_special, war_depth }`. `phase ∈ { dealt, selected, flipped, war,
  player_win, cpu_win }`. `Card = { rank:2..14, suit, face_up }`. Deck index `0` = top.
- **Engine:** `WarEngine.apply(state, action) -> { ok, state, events, error }` — pure, returns a
  NEW state, never mutates across the hash boundary.
- **Actions:** `new_game{seed}`, `start_round`, `play_special{id}`, `flip`, `resolve`, `ack_war`.
- **Hash:** canonical JSON (sorted keys / 2-space indent / null keys omitted / integer-valued
  numbers without a decimal point) → 8-lane rolling hash (IV/SHIFTS per the contract, lanes
  `%08x` concatenated = 64 lowercase hex). `hash_value(v) = hash_string(canonical_stringify(v))`.

## Repo map

```
logic/   pure rules engine (no Node/scene deps). class_name War* + static funcs.
          constants.gd (WarConstants), rng.gd (WarRng), hasher.gd (WarHasher),
          engine.gd (WarEngine), validation.gd (WarValidation),
          special_cards.gd (WarSpecialCards), actions.gd (WarActions)
game/    match_controller.gd (WarMatch): owns state, drives the engine, sends validations.
          mcp_game_api.gd (WarDebug autoload): deterministic-state debug + LLM control surface.
net/     hermes_client.gd: Hermes protobuf envelope over WebSocketPeer.
          proto/ holds godobuf-generated bindings (regenerate via ../tools/gen-protos.sh).
scenes/  playable scene(s).
ui/      boot.tscn/.gd (main scene), game_state.gd (GameState autoload),
          router/app_router.gd (UiRouter autoload), screens/, shell/.
tests/   McpTestSuite parity tests; tests/golden/ holds vectors + their generators.
tools/   verify_*.gd headless parity verifiers + smokes.
assets/  card faces/backs + casual card-game art (placeholder; see assets/README.md).
addons/  vendored editor_tool_kit — DO NOT modify or add anything under here.
```

## Editing + testing loop

Write `.gd` files (Write tool or editor), then — if the editor is open via the `godot-ai` MCP —
**`filesystem_manage reimport`** the changed paths so the editor sees them.

Run parity tests two ways:

```bash
# Headless (no editor) — one per logic module / integration:
/Applications/Godot.app/Contents/MacOS/Godot --headless --path game \
    --script res://tools/verify_engine.gd        # prints "VERIFY <name>: PASS" or "VERIFY <name>: FAIL <reason>"

# Editor suite (McpTestSuite) — via the godot-ai MCP:  test_run
```

Verifiers (`res://tools/verify_*.gd`) are `extends SceneTree`; `func _init()` runs the checks,
prints exactly one `VERIFY <name>: PASS/FAIL <reason>` line, then `quit()`. Plan one per logic
module: `verify_hasher`, `verify_rng`, `verify_engine`, `verify_validation`,
`verify_special_cards`, plus the validator client.

**Always run the relevant verifier(s) after touching `logic/`.** When adding logic, generate an
oracle from the real TS dist (`../validator/src/logic/dist`), dump expected canonical JSON +
hashes into `tests/golden/`, and assert them — never hand-write expected values.

## GDScript gotchas (mirror the Moveborne port's hard-won lessons)

- `str(float)` caps at ~14 significant digits and won't round-trip. Use the hasher's
  shortest-round-trip float formatter for any hashed float; keep integral state values as `int`.
- `%g` / `%.17g` are **not** valid in GDScript `%` formatting — use `%s` / `str()`.
- `Engine` is a reserved native class name — don't use it as an identifier. Reference the engine
  script as e.g. `WarEngineS := preload("res://logic/engine.gd")` where a local alias is needed.
- `class_name` globals do **not** register from `reimport` alone — tests/scenes that must run
  before a full editor scan should `preload("res://logic/x.gd")`. A full editor scan registers
  the `War*` globals.
- `McpTestSuite`: every `test_*` must make ≥1 assertion or it auto-fails; name throwaway nodes
  `_McpTest*`.
- Headless scripts: `extends SceneTree`, do work in `_init()`/`_initialize()` and `quit(code)`.
  Anything needing the tree (e.g. `HTTPRequest.request()`) must run after the tree is ready —
  defer with `call_deferred`. There is no `timeout` on macOS; use `--quit-after N`.
- JSON parsing yields int or float ambiguously; the canonical serializer must handle
  integer-valued floats, and the engine should `int()`-cast reads — keep that robustness for
  hash parity with the TS side.
- `Dictionary`/`Array` are reference types like JS objects/arrays. `WarEngine.apply` must not
  mutate the input state across the hash boundary — duplicate before mutating, and mirror exactly
  what the TS engine copies vs mutates.

## Running things

- **Game:** open `game/` in Godot 4.6 and Play (main scene `res://ui/boot.tscn`), or via the
  `godot-ai` MCP `project_run` + `editor_screenshot`.
- **Drive by game concepts:** use the `WarDebug` autoload (`game/mcp_game_api.gd`) — the
  deterministic-state debug + LLM control surface (inspect state, hash, apply actions).
- **Validator:** `../tools/run_validator.sh` (`:5555`) wraps the self-contained `../validator/`
  (its `@war/logic` dep is the committed prebuilt dist). In-game press **`V`** to connect over the
  local Hermes-envelope endpoint (`ws://localhost:5555/hermes/ws?token=<player-id>`).
- **Protos:** regenerate the godobuf bindings in `net/proto/` with `../tools/gen-protos.sh`
  whenever a `.proto` under `../validator/protos/` changes (`--skip-gdscript` for the JS
  descriptor only).
- **Editor tooling:** `addons/editor_tool_kit/` is vendored — use it, never modify it.

## Conventions

- **Git: commit directly to `main`.** Never create a feature branch and never ask to.
- Logic classes are `class_name War<Thing>` with static functions on `RefCounted`; no Node/scene
  references in `logic/`.
- Do NOT hand-write `.gd.uid` or `.import` files — Godot regenerates them. Commit the `.gd.uid`
  files alongside their scripts (stable references) once Godot has generated them.
- Keep `ARCHITECTURE.md` and the project memory up to date as phases progress.
- Don't add features the engine can't back deterministically; if unsure whether a change
  preserves parity, prove it with a golden vector before committing.
