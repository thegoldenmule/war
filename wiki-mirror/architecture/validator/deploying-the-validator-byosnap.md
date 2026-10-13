# Deploying the Validator (BYOSnap)

**Status:** current

## Kind
component

## Summary
The deployment surface that packages the **War** validator as a Snapser *BYOSnap* (Bring Your Own Snap): a container image plus a deploy profile that tell Snapser how to build, run, health-check, and route the authoritative validation service.

## Purpose
It exists to get the deterministic-parity validator running behind the Snapser gateway as a managed snap. The Dockerfile produces a runnable image of the Bun workspace (resolving the `workspace:*` link from `src/validator` to `src/logic`), and the BYOSnap profile declares the contract Snapser needs to operate it: which ports to expose, where the health probe lives, the gRPC service identity, and the gateway base path under which client traffic is forwarded.

## Design notes
Deploy flow: publish -> sync -> manifest refresh. Publish builds and uploads the BYOSnap container image (built with context validator/ per the Dockerfile header). Sync registers the snapser-byosnap-profile.json with Snapser so the gateway learns the base path, ports, health probe, gRPC service identity, and env. The manifest refresh then makes the snap live behind the gateway under /v1/byosnap-validator.

Local vs deployed differ only at the edge. Locally the validator serves HTTP and the Hermes WebSocket on :5555 (ws://localhost:5555/hermes/ws?token=<player-id>, with ?token the self-stamped player id) while gRPC stays on :8081; deployed, HTTP/health move to :8080 and the Snapser gateway fronts the Hermes traffic and stamps an authenticated User-Id header bound to player_id. The client keeps one codepath across both because traffic always arrives as the same Hermes snap-api-proxy envelope.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- `validator/Dockerfile`
- `validator/snapser-byosnap-profile.json`

## Data model
The deploy is described by two artifacts. The *Dockerfile* is a three-stage Bun build — a `deps` stage that copies the workspace manifests and runs `bun install --frozen-lockfile` so `workspace:*` resolves, a `build` stage that copies sources and runs `bun run build` to produce the deterministic logic package, and a `runtime` stage that carries the resolved workspace forward, sets `NODE_ENV=production` plus `HTTP_PORT=8080` / `GRPC_PORT=8081`, exposes both ports, and starts `bun run start` from `src/validator`. The *snapser-byosnap-profile.json* declares `name` `byosnap-validator`, `runtime` `bun`, `base_path` `/v1/byosnap-validator`, the http (`8080`) and grpc (`8081`) ports, a `health` block pointing at `/health` on `8080`, the gRPC package/service `war.validator.v1.ValidatorService` with its `InitMatch` / `ValidateAction` / `CompleteMatch` methods, the Hermes `snap-api-proxy` transport, the gateway-stamped `User-Id` auth model, and the runtime env (`HTTP_PORT`, `GRPC_PORT`, `STATE_VERSION`, `CARD_CATALOG_PATH`).

## Usage
_None._

## Invariants & constraints
- The Docker build context MUST be the validator/ directory (build from repo root with `docker build -f validator/Dockerfile validator/`) so the workspace:* dep linking src/validator -> src/logic resolves; building from a narrower context breaks the install.
- The /health endpoint is served UNPREFIXED on the HTTP port (:8080) — the gateway base path /v1/byosnap-validator is NOT applied to the health probe, so the container HEALTHCHECK and the profile health.path both hit /health directly.
- The container listens on :8080 for HTTP/health and Hermes WS and on :8081 for the gRPC ValidatorService; both ports are EXPOSEd in the image and declared in the profile ports block, and the env (HTTP_PORT/GRPC_PORT) must agree with them.
- The gateway forwards the base path /v1/byosnap-validator UNSTRIPPED to the container, so the service routes (other than the unprefixed /health) must be mounted under that prefix to match the forwarded path.

## Synced commit
_None._
