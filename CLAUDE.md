# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this repo is

A multi-component workspace for **War** — a hypercasual single-player (vs CPU) spin on the
classic card game War, with a Balatro-style **Special Card** hook played around the
face-down "flip moment". A **Godot 4.6 (GDScript)** client plus a pure deterministic rules
engine, validated by an **authoritative server-side validation service**. The top-level
directories are **independent projects**, each with its own toolchain:

| Dir | Project | Toolchain |
|---|---|---|
| `game/` | The Godot 4.6 (GDScript) client + the pure rules engine (`game/logic/`) | Godot 4.6.x |
| `validator/` | Authoritative move-validation service (Snapser BYOSnap) | Bun + Hono + gRPC |
| `tools/` | Workspace scripts (run validator, export client, regenerate protos) | Bash + Bun + Godot |
| `wiki-mirror/` | Emitted mirror of the *Game: War* architecture wiki | served via the `wiki` MCP |

## The one idea everything rests on

**Determinism parity.** `game/logic/*.gd` (GDScript) and `validator/src/logic/` (TypeScript)
are **byte-for-byte equivalent**: identical canonical JSON, identical 64-hex state hash for
the same state. That parity is what lets the Godot client play optimistically against the
validator unchanged. The operational consequence: **never change `game/logic/` behavior
without re-running the parity tests** — a changed golden hash means you broke compatibility.
The TS package under `validator/src/logic/` is the source of truth for golden vectors.

The pinned contract (do not deviate — both engines must match these exactly):

- **State schema** (the hashed `Dictionary`/object, same shape both sides):
  `{ version:int, seed:string, phase:string, player_deck:Card[], cpu_deck:Card[],
  player_pot:Card[], cpu_pot:Card[], rng:{seq:int}, specials:{player:string[],cpu:string[]},
  pending_special:string|null, war_depth:int }`. `phase ∈ { dealt, selected, flipped, war,
  player_win, cpu_win }`. Deck index `0` = top. `Card = { rank:int(2..14), suit:..., face_up:bool }`.
- **Action schema** (unified player/CPU input): `{ type, ...args }`. Types: `new_game{seed}`,
  `start_round`, `play_special{id}`, `flip`, `resolve`, `ack_war`.
- **Engine entry:** `WarEngine.apply(state, action) -> { ok, state, events, error }` — pure,
  returns a NEW state, never mutates across the hash boundary. The TS engine mirrors this.
- **Hash:** `canonical_stringify` (keys sorted at every depth, 2-space indent, null-valued
  keys omitted, integer-valued numbers print with no decimal point) → `hash_string` (8-lane
  rolling hash, IV/SHIFTS per the contract, each lane `%08x` concatenated = 64 lowercase hex).
  `hash_value(v) = hash_string(canonical_stringify(v))`. Identical in GDScript and TS.
- **RNG:** deterministic, seeded from the match seed; the serialized cursor lives in
  `state.rng` (`{seq:int}`) so the hash is reproducible. Same algorithm both sides, documented
  in both.

Don't restate the architecture here — read the canonical pages:

| To understand… | Read |
|---|---|
| Overview, requirements, controls, project layout, hard-wall diagram | `game/README.md` |
| Architecture, phase status, per-subsystem source-of-truth map, parity-test loop | `game/ARCHITECTURE.md` |
| Godot/GDScript working notes + gotchas + the headless parity-verifier loop | `game/CLAUDE.md` |
| The validator wire (gRPC/Hermes/MCP), ports, history replay | `validator/` (+ its README) |
| Design rationale + subsystem docs (ADRs) | the *Game: War* wiki (see `wiki-mirror/README.md`) |

> The `wiki-mirror/` markdown is an **emitted mirror** of the *Game: War* workspace, served by the
> `wiki` MCP server (`https://hotseat.thegoldenmule.com/mcp`). **Edit wiki content through the
> MCP** (`mutatePage` / `mutatePageBatch`), never by hand: a live emitter regenerates the `.md`
> files + `.wiki-md-manifest.json` from the workspace on every change, so direct edits get
> overwritten. Read the files freely; treat them as read-only on disk.

## Commands

### Game (`game/` is the Godot project root, so `res://` maps there)

```bash
# Open game/ in Godot 4.6 and press Play (main scene: res://ui/boot.tscn). Runs fully offline.

# Headless parity verifiers — one per logic module. Print VERIFY <name>: PASS/FAIL:
/Applications/Godot.app/Contents/MacOS/Godot --headless --path game \
    --script res://tools/verify_engine.gd
# Plus verifiers for the hasher, rng, validation, special_cards, and the validator client.
```

Editor test suites (`McpTestSuite` in `res://tests/test_*.gd`) run via the `godot-ai` MCP
`test_run`, not the CLI. See `game/CLAUDE.md` for the full editing+testing loop and gotchas.

### Validator (`validator/`, Bun workspace)

```bash
cd validator
bun install            # installs deps + links the src/logic workspace
bun run dev            # hot-reload; HTTP + Hermes WS + MCP on :5555, gRPC on :8081
bun run build          # rebuild src/logic/dist from TS source (only when logic changes)
bun run test           # run the logic package's tests (golden vectors)
bun run type-check     # tsc --noEmit on src/logic + src/validator
```

`src/logic/dist` is **committed** so the service runs without a build step. Ports: validator
HTTP `:5555` local / `:8080` deployed; gRPC `:8081`; MCP at `POST /mcp`; health `GET /health`.

### Workspace tools (`tools/`)

```bash
tools/run_validator.sh           # one-shot: cd validator && bun install && bun run dev (:5555)
tools/build.sh <platform> ...    # Godot multi-platform export (presets live in game/)
tools/gen-protos.sh              # regenerate JS descriptor + godobuf GDScript bindings from protos
tools/gen-protos.sh --skip-gdscript   # JS descriptor + swagger only (no Godot needed)
```

## Online play (game ⇄ validator)

The validator re-runs the same rules engine and confirms every action. Locally, start
`tools/run_validator.sh` (serves `:5555`), then press **`V`** in-game to connect. The wire is
the **Snapser Hermes WebSocket envelope** (`ClientMessage`/`ServerMessage`, a `snap-api-proxy`
message type); locally the validator serves the identical envelope at
`ws://localhost:5555/hermes/ws?token=<player-id>`, so the client has ONE codepath. Game state
and actions travel as **canonical-JSON strings inside proto string fields** (the hash domain —
never re-model them as proto messages). Auth: the gateway stamps a `User-Id` bound to
`player_id`; locally the `?token=` query param is the self-stamped player id.

## MCP servers

`.mcp.json` registers:

- **`wiki`** (`https://hotseat.thegoldenmule.com/mcp`) — the structured *Game: War* architecture
  wiki / ADRs. Edit content here; the on-disk `wiki-mirror/` mirror regenerates.
- **`snapser`** (`npx @snapser/mcp-server-snapser`) — the Snapser platform.
- The **`godot-ai`** MCP (bundled under `game/addons/`) drives the Godot editor/game when open.
- The validator exposes an **MCP** at `:5555/mcp` for inspecting/debugging match state once it
  is running.

## Conventions

- **Git: commit directly to `main`.** Don't create feature branches and don't ask to.
- Keep `game/logic/` free of `Node`/scene deps; it is pure static `class_name War*` utilities
  on `RefCounted`, headless-loadable.
- **Prove any logic change preserves hashes** with a golden vector generated from the real TS
  dist before committing — never hand-write expected hashes (see `game/CLAUDE.md`).
- Do not touch `game/addons/` (`editor_tool_kit` is vendored), `.mcp.json`, or
  `hotseat.config.json`.
