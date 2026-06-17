# War — Godot Client

The **Godot 4.6 (GDScript)** client for **War**, a hypercasual single-player (vs CPU) spin
on the classic card game. Each round both sides flip their top card; the higher rank takes
the pot to the bottom of its deck; ties trigger a **WAR** (stake 3 face-down + 1 face-up, the
higher face-up takes the pot, repeat on another tie). The game ends when one side holds all
52 cards.

The twist — and the monetization surface — is the **flip moment**: cards deal **face-down**,
and before the reveal you may play a collectible **Special Card** (peek, steal-tie,
rank-boost, …). Special effects are validator-authoritative and resolve inside the
deterministic engine.

The headline property: the GDScript rules engine in [`logic/`](logic/) is **byte-for-byte
deterministically equivalent** to the TypeScript engine in `../validator/src/logic/`. Both
compute identical 64-hex state hashes, so the client can play **optimistically** against the
authoritative validator and reconcile on hash mismatch.

> Architecture, phase status, and the per-subsystem source-of-truth map live in
> [`ARCHITECTURE.md`](ARCHITECTURE.md). Godot/GDScript working notes and the parity-verifier
> loop live in [`CLAUDE.md`](CLAUDE.md).

## Requirements

- **Godot 4.6.x** (GL Compatibility renderer, portrait 720×1560).
- **[Bun](https://bun.sh) 1.3+** — only needed to run the `../validator/` for online play.
- The `editor_tool_kit` addon is **already vendored** under `addons/` (editor automation /
  in-editor tooling base). Do not modify anything under `addons/`.

## Quick start

Open the project (this `game/` directory — it is the Godot project root, so `res://` maps
here) in Godot 4.6 and press **Play**. The main scene is **`res://ui/boot.tscn`**. The game
runs fully offline; no backend required.

### Controls

> The skeleton wires the deterministic core; input bindings are filled in behind
> `# TODO(skeleton):` markers as the playable scene lands.

| Input | Action |
|---|---|
| Tap / click "Flip" | Reveal both top cards and resolve the round |
| Tap a Special Card before flipping | Play it around the flip moment (`play_special`) |
| Continue / "Ack" | Acknowledge and continue a WAR (`ack_war`) |
| New Game | Deal a fresh 52-card match from a new seed (`new_game`) |
| `V` | Connect to the local validator (online validation) |

Occult-arcade palette: violet accent `#b400ff` (hover `#d24bff`) on near-black `#13111c`,
green `#44ff88` for selection, white for peak emphasis.

## Online play against the validator (optional)

`../validator/` re-runs the same rules engine and confirms every action. Run it locally
(no Snapser gateway needed — the client self-stamps the `User-Id` the validator binds to):

```bash
../tools/run_validator.sh        # serves the validator on http://localhost:5555
```

Then press **`V`** in-game. The client connects over the Snapser Hermes WebSocket envelope at
`ws://localhost:5555/hermes/ws?token=<player-id>` (the same codepath used in production); on a
hash mismatch the client snaps to the validator's authoritative state.

## Project layout

```
logic/      Pure deterministic rules engine (no scene/Node deps). The parity core.
  constants.gd        WarConstants — deck/ranks/suits, Special Card catalog, scalars
  rng.gd              WarRng — deterministic seeded RNG; cursor serialized in state.rng
  hasher.gd           WarHasher — canonical JSON + 8-lane rolling state hash (64 hex)
  engine.gd           WarEngine.apply(state, action) -> { ok, state, events, error }
  validation.gd       WarValidation — legality checks per action/phase
  special_cards.gd    WarSpecialCards — Special Card effect resolution (deterministic)
  actions.gd          WarActions — action constructors / schema helpers
game/
  match_controller.gd WarMatch — owns game state, drives the engine, sends validations
  mcp_game_api.gd     WarDebug — deterministic-state debug + LLM control surface (autoload)
net/
  hermes_client.gd    Hermes protobuf envelope over WebSocketPeer
  proto/              godobuf-generated bindings (regenerate via ../tools/gen-protos.sh)
scenes/               playable scene(s)
ui/
  boot.tscn / boot.gd main scene + boot
  game_state.gd       GameState autoload (currency / profile / settings mirror)
  router/             UiRouter autoload — screen/scene routing for the meta shell
  screens/, shell/    meta-shell screens + chrome
tests/                McpTestSuite parity tests + tests/golden/ (vectors from the TS dist)
tools/                headless verifiers (verify_*.gd) and smokes
assets/               card faces/backs + occult-arcade art (see assets/README.md)
addons/               vendored editor_tool_kit (do not modify)
```

Pinned class names (GDScript `class_name`, `War` prefix for logic): `WarConstants`, `WarRng`,
`WarHasher`, `WarEngine`, `WarValidation`, `WarSpecialCards`, `WarActions` (logic);
`WarMatch`, `WarDebug` (runtime). Autoloads (declared in `project.godot`): `WarDebug`,
`GameState`, `UiRouter`.

## Architecture — the hard wall

A hard wall separates **deterministic logic** from **presentation**:

```
input → action → logic/ (pure) → new state + hash → scenes/ + ui/ render
                                → net/ validator confirms
```

- `logic/` is pure GDScript: state is a `Dictionary` matching the synchronized state schema
  (same shape as the TS side); decks/pots are `Array`s of card `Dictionary`s, index `0` = top.
  `class_name War*` static utilities on `RefCounted`, headless-loadable, zero `Node` deps.
- `WarEngine.apply(state, action)` is **pure**: it returns a NEW state and never mutates the
  input across the hash boundary. The TS engine mirrors this exactly.
- The client plays **optimistically** (applies each action locally for instant feedback) and,
  when online, sends the predicted state hash to the validator. A matching hash ACKs on the
  fast path; a mismatch returns the authoritative state the client snaps to.

## Testing

Two complementary harnesses, both checking parity against vectors generated from the real TS
`@war/logic` dist (`../validator/src/logic/dist`):

- **Editor suites** (`McpTestSuite` in `res://tests/test_*.gd`) — run via the `godot-ai` MCP
  `test_run`.
- **Headless verifiers** (`res://tools/verify_*.gd`) — no editor needed:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path game \
      --script res://tools/verify_engine.gd        # prints VERIFY <name>: PASS/FAIL
  ```

  One per logic module (hasher, rng, engine, validation, special_cards) plus the validator
  client. See [`CLAUDE.md`](CLAUDE.md) for the full loop.

## License / ownership

War is owned by The Golden Mule. The authoritative rules engine is mirrored across this
`logic/` directory and `../validator/src/logic/`.
