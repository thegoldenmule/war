# @war/validator

Authoritative server-side validation service for **War** — the hypercasual,
single-player-vs-CPU card game built in Godot 4.6. Written in TypeScript on
[Bun](https://bun.sh) with [Hono](https://hono.dev), `@grpc/grpc-js`, and an MCP
debug surface.

The validator is a thin **authoritative shell** around `@war/logic`, the shared
deterministic rules engine. It never re-implements rules; it re-runs the same
engine the client runs and compares state hashes.

## What it does

When a client takes a turn it applies the action locally for instant feedback
(optimistic) and sends the **predicted state hash** to the validator. The
validator:

1. loads the authoritative state for the match,
2. re-applies the action through `@war/logic.apply`,
3. recomputes the determinism hash, and
4. answers:
   - **fast path** — predicted hash matches → client keeps its optimistic state;
   - **reconcile** — action was legal but the hash diverged → client **snaps**
     to the returned authoritative state JSON;
   - **reject** — action was illegal → client keeps the prior state.

Because `@war/logic` (TypeScript) is **byte-for-byte deterministic-parity** with
`game/logic/` (GDScript) — identical canonical JSON, identical hash — a correct
client always lands on the fast path.

## Running

```sh
bun install          # from the workspace root (resolves @war/logic)
cp .env.example .env  # adjust ports/secret if needed
bun run dev           # bun --watch index.ts
# or
bun run start         # bun index.ts
bun run type-check    # tsc --noEmit
```

Defaults (see `.env.example`):

| Var                       | Default | Meaning                                  |
| ------------------------- | ------- | ---------------------------------------- |
| `PORT`                    | `5555`  | HTTP (health/status/match/MCP/Hermes WS) |
| `GRPC_PORT`               | `8081`  | gRPC `war.validator.v1.ValidatorService` |
| `VALIDATOR_SHARED_SECRET` | _empty_ | empty ⇒ local trusted-token mode         |

Deployed, the gateway maps HTTP to `:8080`; gRPC stays `:8081`.

## Endpoints

| Surface  | Address                              | Purpose                              |
| -------- | ------------------------------------ | ------------------------------------ |
| HTTP     | `GET /health`                        | liveness                             |
| HTTP     | `GET /api/status`                    | identity, ports, match count, uptime |
| HTTP     | `GET /api/matches`                   | match history (summaries)            |
| HTTP     | `GET /api/matches/:id`               | one match summary                    |
| HTTP     | `GET /api/matches/:id/state`         | authoritative canonical state JSON   |
| HTTP     | `POST /mcp`                          | MCP debug (JSON-RPC 2.0)             |
| WS       | `/hermes/ws?token=<player-id>`       | Hermes-envelope client path          |
| gRPC     | `war.validator.v1.ValidatorService`  | `InitMatch` / `ValidateAction` / `CompleteMatch` |

### MCP tools (`POST /mcp`)

`list_matches`, `get_match_state`, `simulate_action` (dry-run, no persist),
`clear_match`.

## Auth model

- **Local:** the `?token=<player-id>` query param on `/hermes/ws` is the
  self-stamped player id. No secret required (`VALIDATOR_SHARED_SECRET` empty ⇒
  `isLocal`). This gives the Godot client **one codepath** for dev and prod.
- **Deployed:** Snapser's gateway stamps a verified `User-Id` header bound to
  the player; the validator treats that id as authoritative. The same id binds
  every match (see `store/match-store.ts`) so a player can only act on their own
  matches. `VALIDATOR_SHARED_SECRET` gates production verification.

## Wire format (the hash domain)

Game **state** and **actions** travel as **canonical-JSON strings** inside proto
`string` fields and WS payloads — never as structured proto messages. The
determinism hash is computed over that exact canonical string, so re-modeling it
would break GDScript↔TS parity. Always serialize with `@war/logic`'s canonical
stringifier (`canonicalStringify`), never `JSON.stringify`, when emitting
state/action across the boundary.

## Layout

```
config.ts            env load + validation
types.ts             MatchRecord, ValidateResult, …
logic.ts             the @war/logic adapter (rules-authority boundary)
store/match-store.ts in-memory authoritative store (player-bound)
service.ts           ValidatorService — the ONE place rules are enforced
proto.ts             proto descriptor loading + hash-domain rule
grpc.ts              @grpc/grpc-js binding
hermes-ws.ts         local Hermes-envelope WebSocket endpoint
mcp.ts               MCP debug server
routes/health.ts     /health, /api/status
routes/match.ts      /api/matches history
index.ts             entry: Hono app + Bun WS + gRPC
```

## Skeleton status

Real route/handler/service structure and a working in-memory store + reconcile
flow. Transport wiring that needs generated proto code is marked
`// TODO(skeleton):` — specifically the gRPC proto descriptor
(`validator/protos/war/validator/v1/validator.proto`) and the Hermes envelope
codec (`validator/protos/hermes/hermes_envelope.proto`). HTTP/WS/MCP come up
regardless; gRPC binds once the descriptor lands.
