# War — Architecture & Working Plan

The working plan, architecture, and phase status for the **War** Godot client and its
deterministic rules engine. This is the new-game analog of a port plan: rather than porting an
existing engine, both engines (`game/logic/` GDScript and `../validator/src/logic/` TS) are
authored to the same **shared contract** and held in **byte-for-byte parity**.

See [`README.md`](README.md) for the overview and [`CLAUDE.md`](CLAUDE.md) for GDScript working
notes + the parity-verifier loop.

## The game in one paragraph

Standard 52-card deck (ranks 2..14, suits clubs/diamonds/hearts/spades). A deterministic shuffle
seeded from the match seed deals 26 to the player and 26 to the CPU. Each round both flip their
top card; higher rank wins both cards to the bottom of the winner's deck. Cards deal
**face-down**, and before the reveal the player may play a collectible **Special Card** (the
Balatro-style hook). A tie triggers a **WAR**: each stakes 3 face-down + 1 face-up; the higher
face-up takes the pot; another tie repeats (`war_depth++`); a player who cannot complete a war
loses. The game ends when one side holds all 52 cards (`phase = player_win | cpu_win`).

## The hard wall

```
input → action → logic/ (pure) → new state + hash → scenes/ + ui/ render
                                → net/ validator confirms (optimistic + reconcile)
```

- **`logic/`** is pure GDScript — `class_name War*` static utilities on `RefCounted`, zero
  `Node`/scene/`EditorInterface` deps, headless-loadable. It is the only place game rules live.
- **Presentation** (`scenes/`, `ui/`) reads state and renders; it never re-implements rules.
  The **Round Director** (`ui/round_director.gd`, `WarRoundDirector`) is the presentation-tier
  *play sequencer* between the view and `WarMatch`: it paces the engine's legal transitions into
  timed *beats*, auto-advancing the mechanical actions (`start_round`, `resolve`) and pausing for
  the player only at the flip moment and the WAR ack (deep runaway wars auto-advance). It owns no
  hashed state — only a cosmetic beat, one armed timer, and the last apply's buffered events — and
  only chooses WHICH legal action to submit and WHEN, so the validator re-runs an identical action
  stream and every determinism/reconcile guarantee carries over unchanged.
- **`net/`** carries actions/state to the validator as canonical-JSON strings and reconciles.

## State & action contract (the hash domain)

The synchronized, hashed state — identical shape in GDScript (`Dictionary`) and TS (object):

```
{
  version:int, seed:string, phase:string,
  player_deck:Card[], cpu_deck:Card[],
  player_pot:Card[],  cpu_pot:Card[],
  rng:{ seq:int },
  specials:{ player:string[], cpu:string[] },
  pending_special:string|null,
  war_depth:int
}
phase ∈ { dealt, selected, flipped, war, player_win, cpu_win }
Card  = { rank:int(2..14), suit:"clubs"|"diamonds"|"hearts"|"spades", face_up:bool }
Deck index 0 = top.
```

Actions (unified player/CPU input): `{ type, ...args }` — `new_game{seed}`, `start_round`,
`play_special{id}`, `flip`, `resolve`, `ack_war`.

Engine entry: **`WarEngine.apply(state, action) -> { ok, state, events, error }`** — pure,
returns a NEW state, never mutates across the hash boundary. The TS engine mirrors this exactly.

## Determinism primitives

- **Canonical JSON** (`WarHasher`): keys sorted lexicographically at every depth, 2-space
  indent, arrays in order, dict keys whose value is `null` omitted, integer-valued numbers print
  with no decimal point, other floats print as the shortest round-tripping decimal. Equivalent
  to `json-stable-stringify(x, {space: 2})`.
- **State hash** (`WarHasher`): 8-lane rolling hash over the canonical-JSON UTF-8 bytes
  (IV/SHIFTS per the contract; `toInt32` wraps to signed 32-bit; each lane `%08x` concatenated =
  64 lowercase hex). `hash_value(v) = hash_string(canonical_stringify(v))`.
- **RNG** (`WarRng`): deterministic, seeded from the match seed; the serialized cursor is
  `state.rng.seq` so the hash stays reproducible. The algorithm is identical in GDScript and TS
  and documented in both.

These three MUST be byte-identical on both sides — they are the parity contract.

## Phases & status

| Phase | What | State |
|---|---|---|
| 0 | **Determinism primitives** — canonical JSON, 8-lane hash, seeded RNG; golden parity vs the TS dist | 🟡 skeleton — interfaces + algorithm in place, fill behind `# TODO(skeleton):` |
| 1 | **Full deterministic engine** — deal, flip, resolve, WAR, Special Cards, win detection | 🟡 skeleton — `WarEngine.apply` contract stubbed, rules deferred |
| 2 | **Playable single-player** — boot/menu shell, table scene, flip/war/special UI, vs-CPU loop | 🟡 Core Play Loop **Phase A** built (offline): Round Director beats + tempo, auto-staging/resolve, WAR escalation, tap-to-skip, deep-war auto-ack, view-only table, PLAY AGAIN. Headless-verified (`verify_round_director`, `verify_play_loop`). |
| 3 | **Validator integration** — Hermes WS envelope, optimistic apply + hash reconcile | ⬜ Core Play Loop **Phase B** planned: generate godobuf bindings, thread `match_id`/`player_id`, server-assigned seed at InitMatch, reconcile-reply alignment, CompleteMatch on terminal. |
| 4 | **Meta / monetization** — Special Card collection, economy, the flip-moment storefront hook | ⬜ planned |

Legend: ✅ done · 🟡 in progress / skeleton · ⬜ planned.

## Per-subsystem source-of-truth map

| Subsystem | Source of truth | Notes |
|---|---|---|
| Game rules (deal/flip/resolve/WAR) | `logic/engine.gd` ⇄ `../validator/src/logic/` | Must stay byte-for-byte parity |
| Determinism (hash + canonical JSON) | `logic/hasher.gd` ⇄ TS hasher | The parity contract; never diverge |
| Seeded RNG | `logic/rng.gd` ⇄ TS rng | Same algorithm; cursor in `state.rng.seq` |
| Constants (deck, Special Card catalog) | `logic/constants.gd` ⇄ TS constants | `WarConstants` |
| Special Card effects | `logic/special_cards.gd` ⇄ TS | Validator-authoritative; resolved in-engine |
| Legality / validation | `logic/validation.gd` ⇄ TS | Per-action / per-phase checks |
| Action schema | `logic/actions.gd` ⇄ TS | Unified player/CPU input |
| Match runtime | `game/match_controller.gd` (`WarMatch`) | Owns state, drives the engine, sends validations |
| Play sequencing (beats/tempo/pacing) | `ui/round_director.gd` (`WarRoundDirector`) | Presentation-tier; paces legal actions into beats; no hashed state |
| Table view | `ui/screens/table.gd` | Render-only; owns a Director, forwards intents; buttons driven solely by `beat(locked)` |
| Debug / LLM control | `game/mcp_game_api.gd` (`WarDebug` autoload) | Deterministic-state inspection surface |
| Wire protocol | `../validator/protos/` | gRPC + Hermes envelope; godobuf bindings in `net/proto/` |
| Golden vectors | `../validator/src/logic/dist` → `tests/golden/` | Vectors generated from the real TS dist |

## The parity-test loop

The engines diverging is the one failure mode that breaks everything. The loop that prevents it:

1. Author or change a rule **once** conceptually, then implement it on **both** sides
   (`logic/*.gd` and `../validator/src/logic/`), mirroring iteration order, RNG draw
   order/count, and which fields are present in state.
2. Generate an **oracle** from the real TS dist — feed seeds/action sequences through
   `@war/logic`, dump the resulting canonical JSON + 64-hex hashes into `tests/golden/`. Never
   hand-write expected hashes.
3. Assert those golden hashes in a headless verifier and/or an `McpTestSuite`:

   ```bash
   /Applications/Godot.app/Contents/MacOS/Godot --headless --path game \
       --script res://tools/verify_engine.gd        # prints VERIFY <name>: PASS/FAIL
   ```

4. **A changed golden hash = broken compatibility.** Find out why before committing. Never
   change `logic/` behavior without re-running the relevant verifier(s).

## Open questions / deferred (`# TODO(skeleton):`)

- Exact Special Card catalog (ids, effects, costs) and their deterministic resolution order.
- CPU policy for `play_special` / WAR decisions (must be deterministic and hashed if it draws RNG).
- Table-scene visual language for the flip moment and WAR staking.
- Storefront / economy surface (Phase 4) and how Special Card inventory enters `state.specials`.
