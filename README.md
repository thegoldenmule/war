# War

A multi-component workspace for **War** — a hypercasual single-player (vs CPU) spin on
the classic card game. You flip the top card each round, higher rank takes the pot, ties
trigger a **WAR**; the twist is the **flip moment**: cards deal face-down and, before the
reveal, you may play a collectible **Special Card** (peek, steal-tie, rank-boost, …). That
Balatro-style hook is the monetization surface. Built in **Godot 4.6 (GDScript)** with an
**authoritative server-side validation service**.

## Components

The top-level directories are **independent projects**, each with its own toolchain:

| Dir | Project | Toolchain |
|---|---|---|
| `game/` | The Godot 4.6 (GDScript) client + the pure deterministic rules engine (`game/logic/`) | Godot 4.6.x |
| `validator/` | Authoritative move-validation service; deployable as a Snapser BYOSnap | Bun + Hono + gRPC (protos in `validator/protos/`) |
| `tools/` | Workspace scripts: run the validator, export the client, regenerate protobuf bindings | Bash + Bun + Godot |
| `wiki/` | **Emitted mirror** of the *Game: War* architecture wiki (read-only on disk) | served via the `wiki` MCP |

## The one idea everything rests on

**Determinism parity.** `game/logic/*.gd` (GDScript) and `validator/src/logic/` (TypeScript)
are **byte-for-byte equivalent**: identical canonical JSON, identical 64-hex state hash for
the same state. That parity is what lets the Godot client play **optimistically** against the
validator — the client applies each action locally for instant feedback and sends its
predicted state hash; a matching hash ACKs the fast path, a mismatch returns the authoritative
state the client snaps to.

The operational consequence: **never change `game/logic/` behavior without re-running the
parity tests.** A changed golden hash means you broke compatibility — figure out why before
committing. The TS package under `validator/src/logic/` is the source of truth for golden
vectors.

The other architectural rule is the **hard wall**: pure deterministic logic (`game/logic/`,
no `Node`/scene deps) is fully separated from presentation (`game/scenes/`, `game/ui/`):

```
input → action → logic/ (pure) → new state + hash → render
                                → net/ validator confirms
```

## Key docs

| To understand… | Read |
|---|---|
| The Godot client: overview, requirements, quick start, controls, layout, hard-wall diagram | [`game/README.md`](game/README.md) |
| Architecture, phase status, per-subsystem source-of-truth map, the parity-test loop | [`game/ARCHITECTURE.md`](game/ARCHITECTURE.md) |
| Godot/GDScript working notes, the headless parity-verifier loop, gotchas | [`game/CLAUDE.md`](game/CLAUDE.md) |
| Guidance for Claude Code working anywhere in this repo | [`CLAUDE.md`](CLAUDE.md) |
| The emitted architecture wiki (ADRs + subsystem docs) | [`wiki/README.md`](wiki/README.md) |
| Workspace tooling (run validator, export builds, regenerate protos) | [`tools/`](tools/) |

## Quick start

```bash
# 1. Run the validator (HTTP + Hermes WS + MCP on :5555, gRPC on :8081):
tools/run_validator.sh

# 2. Open game/ in Godot 4.6 and press Play (main scene: res://ui/boot.tscn).
#    The game runs fully offline; press V in-game to connect to the local validator.
```

## License / ownership

War is owned by The Golden Mule. Game design and the authoritative rules live in this
workspace; the deterministic engine is mirrored across `game/logic/` and `validator/src/logic/`.
