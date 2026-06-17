# CLAUDE.md — @war/validator

Guidance for AI agents editing this package. Read before changing anything here.

## What this is

The **authoritative** server-side validator for the card game War. Bun + Hono +
`@grpc/grpc-js` + a local Hermes-envelope WebSocket + an MCP debug surface. It is
the server half of the optimistic-reconcile loop.

## The ONE rule: do not re-implement game rules here

`@war/logic` is the rules authority. This service **re-runs** that engine and
trusts its verdict. Never encode War's rules (deal, flip, war, special cards,
win conditions) in this package.

- All rule execution funnels through `logic.ts` → `@war/logic`.
- `service.ts` is the single place server-side enforcement happens, and it does
  so purely by calling `applyAction` + `stateHash` from `logic.ts`.
- If you need new behavior that depends on rules, add it to `@war/logic` and the
  GDScript engine (keep them in parity), not here.

## Determinism parity (the contract you must not break)

`@war/logic` (TS) and `game/logic/` (GDScript) are **byte-for-byte equivalent**:
identical canonical JSON, identical 64-hex state hash. The validator's whole
value proposition is that re-running the engine yields the SAME hash the client
predicted.

Consequences for code in this package:

- **State and actions are canonical-JSON STRINGS on the wire** (gRPC string
  fields, WS payloads). They are the hash domain. Do NOT model them as proto
  messages and do NOT round-trip them through `JSON.stringify` before hashing —
  use `canonicalStringify` from `logic.ts` (which delegates to `@war/logic`).
- When you persist a state, store its `stateJson` + `hash` together (see
  `MatchStore`). Reads should serve the cached canonical string.

## Auth model

- Local dev: `/hermes/ws?token=<player-id>` — the token is the self-stamped
  player id; trusted because `VALIDATOR_SHARED_SECRET` is empty (`config.isLocal`).
- Deployed: the gateway stamps a verified `User-Id`; the validator binds it to
  the player. Matches are player-bound in `MatchStore`; acting on another
  player's match is rejected (`PlayerBindingError`).

Keep these two paths behaviorally identical — the client must have ONE codepath.
`hermes-ws.ts` and `grpc.ts` route to the SAME `ValidatorService` methods.

## `@war/logic` adapter

Because `@war/logic` is authored in parallel, `logic.ts` resolves its exports
defensively (accepts a few plausible names for `apply` / `stateHash` /
`canonicalStringify` / `newGame`). Once `@war/logic` ships its `.d.ts`, replace
the `pick`-based lookups with direct typed imports and delete the fallbacks.
Expected surface: `apply(state, action) -> {ok, state, events, error}`,
`stateHash(state)`, `canonicalStringify(value)`, `newGame(seed)`.

## TODO(skeleton) markers

Transport details that need generated/committed proto code are stubbed:

- `proto.ts` / `grpc.ts`: bind once
  `validator/protos/war/validator/v1/validator.proto` exists. gRPC boot is
  best-effort so HTTP/WS/MCP come up without it.
- `hermes-ws.ts`: `decodeEnvelope` / `encodeEnvelope` currently accept a
  plain-JSON dev frame; swap to protobufjs encode/decode of the Hermes envelope
  (`protos/hermes/hermes_envelope.proto`) via `loadHermesRoot()`.

When you complete one, remove its `// TODO(skeleton):` and keep the service's
external behavior unchanged.

## Conventions

- TypeScript ESM, `.ts` extension imports (Bun + `allowImportingTsExtensions`).
- Strict TS; run `bun run type-check`.
- Keep `service.ts` transport-agnostic; transports adapt to it, not vice-versa.
- Errors: throw `ServiceError` (with a code) / `MatchNotFoundError` /
  `PlayerBindingError`; transports map them to gRPC status / HTTP codes.
