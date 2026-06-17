# War — Validator

The authoritative server-side validation service for **War**, a hypercasual
single-player (vs CPU) spin on the classic card game. The validator is the
referee: it re-applies every player action through a deterministic rules engine
that is **byte-for-byte equivalent** to the Godot/GDScript client engine, and
either ACKs the client's optimistic prediction or returns the authoritative
state to snap to.

This is a Bun workspace. The deterministic logic (`src/logic`) and the service
shell (`src/validator`) are separate packages so the logic can be unit-tested
and shipped as the parity half of `../game/logic`.

---

## Layout

```
validator/
  package.json                  Bun workspace root (this file's package)
  Dockerfile                    BYOSnap image (build context = this dir)
  snapser-byosnap-profile.json  BYOSnap deploy profile (http :8080, grpc :8081)
  .env.example                  environment template (copy to .env)
  content/
    card_catalog.json           canonical Special Cards catalog (also baked into client)
    card_catalog.schema.json    JSON Schema for the catalog
  protos/
    war/validator/v1/
      validator.proto           ValidatorService { InitMatch, ValidateAction, CompleteMatch }
      validator_messages.proto  request/response messages (carry canonical-JSON strings)
    hermes/
      hermes_envelope.proto     Snapser Hermes ClientMessage/ServerMessage envelope
  src/
    logic/                      deterministic engine (TS parity of game/logic) — owned separately
    validator/                  HTTP + gRPC + Hermes WS service shell — owned separately
```

> The Godot client lives at `../game` (its project root, so `res://` maps there).
> The TS engine in `src/logic` mirrors `../game/logic/*.gd` exactly.

---

## Run

```bash
# from validator/
bun install            # install + link the workspace (src/validator -> src/logic)

bun run dev            # start the validator (HTTP :5555 local, Hermes WS, MCP)
bun run start          # production start
bun run build          # build the deterministic logic package
bun run test           # run the parity / engine tests in src/logic
bun run type-check     # typecheck both packages
```

Local ports:

| Surface          | Local              | Deployed (BYOSnap)        |
| ---------------- | ------------------ | ------------------------- |
| HTTP / health    | `:5555` `/health`  | `:8080` `/health`         |
| gRPC             | `:8081`            | `:8081`                   |
| Hermes WebSocket | `ws://localhost:5555/hermes/ws?token=<player-id>` | gateway-fronted |
| MCP              | `POST /mcp`        | `POST /mcp`               |

The deployed base path is `/v1/byosnap-validator` (added by the Snapser
gateway). `/health` is served **unprefixed** for the container health probe.

---

## Wire protocol

The gRPC service is `war.validator.v1.ValidatorService`:

| RPC              | Purpose                                                        |
| ---------------- | -------------------------------------------------------------- |
| `InitMatch`      | Deal the deterministic deck from a seed; return initial state. |
| `ValidateAction` | Re-apply one action; ACK matching predicted hash or reconcile. |
| `CompleteMatch`  | Finalize a terminal match (`player_win` / `cpu_win`).          |

The client reaches these RPCs over the **Snapser Hermes WebSocket envelope**
(`protos/hermes/hermes_envelope.proto`) using the `snap-api-proxy` message type,
which wraps a method name + serialized request bytes. Locally the validator
serves that identical envelope at `ws://localhost:5555/hermes/ws?token=<player-id>`
so the client has **one codepath** for local and deployed.

### Optimistic + reconcile

1. Client applies an action locally for instant feedback.
2. Client sends `{ state_json, action_json, predicted_hash }` to `ValidateAction`.
3. Validator re-applies the action through the authoritative engine.
4. **Match** → `ack = true`, client keeps its optimistic state.
   **Mismatch** → `ack = false` + `authoritative_state_json`, client snaps to it.

---

## Regenerate bindings from protos

Proto-generated bindings are **not** committed; regenerate them after editing
any `.proto`:

```bash
bun run gen:proto        # delegates to tools/gen-protos.sh
# or directly:
bash ../tools/gen-protos.sh
```

`tools/gen-protos.sh` (repo `tools/`) compiles everything under
`validator/protos/` into the per-package `gen/` directories. The generator is
the single source of truth for bindings — do not hand-edit generated code.

---

## The hash domain (do not violate)

Game **state** and **actions** are never modelled as proto fields. They travel
as **canonical-JSON strings** inside the `*_json` string fields of the validator
messages. This is deliberate: the determinism hash is computed over byte-
identical JSON on both sides.

- **`canonical_stringify(value)`** — JSON identical to
  `json-stable-stringify(value, { space: 2 })`: keys sorted lexicographically at
  every depth, 2-space indent, arrays in order, dict keys whose value is `null`
  omitted, integer-valued numbers printed without a decimal point, other floats
  printed as the shortest round-tripping decimal.
- **`hash_string(s)`** — 8-lane rolling hash over the UTF-8 bytes of `s`
  (IV/SHIFTS per the shared contract), each lane formatted `%08x` and
  concatenated → 64 lowercase hex chars.
- **`hash_value(v) = hash_string(canonical_stringify(v))`**; the state hash is
  `hash_value(state)`.

> Re-modelling state/actions as proto messages would fork the hash domain and
> silently break parity. Keep them as JSON strings.

---

## Determinism parity rule

`src/logic` (TypeScript) and `../game/logic/*.gd` (GDScript) are **byte-for-byte
equivalent**: identical canonical JSON, identical state hash, identical RNG
cursor advance. Their behavior must never diverge. The shared state schema:

```jsonc
{
  "version": 1,
  "seed": "string",
  "phase": "dealt|selected|flipped|war|player_win|cpu_win",
  "player_deck": [ /* Card */ ], "cpu_deck": [ /* Card */ ],
  "player_pot": [ /* Card */ ],  "cpu_pot":  [ /* Card */ ],
  "rng": { "seq": 0 },
  "specials": { "player": ["id"], "cpu": ["id"] },
  "pending_special": null,       // omitted from canonical JSON when null
  "war_depth": 0
}
// Card = { rank: 2..14, suit: "clubs|diamonds|hearts|spades", face_up: bool }
// deck index 0 = top
```

Engine entry (both sides): `apply(state, action) -> { ok, state, events, error }`
— pure; returns a NEW state, never mutating the input across the hash boundary.

---

## Auth model

- **Deployed:** the Snapser gateway stamps an authenticated `User-Id` header,
  bound to `player_id`. The validator trusts that header for identity.
- **Local:** the `?token=<player-id>` query param on the Hermes WebSocket is the
  self-stamped player id — the same `player_id` flows into every RPC.

This keeps a single client codepath: locally you self-stamp via `?token=`,
deployed the gateway stamps `User-Id` for you.

---

## Content

`content/card_catalog.json` is the canonical Special Cards catalog (validated by
`content/card_catalog.schema.json`). The validator loads it at boot for
authoritative effect resolution, and a copy is baked into the client. Card `id`s
are the stable keys used in `state.specials.{player,cpu}` and the
`play_special{ id }` action.
