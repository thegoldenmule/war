# gRPC over Snapser Hermes as the validator transport

**Status:** accepted

## Metadata
- **Number:** ADR-7
- **Date:** 2026-06-17
- **Scope:** transport

## Context
We need a *realtime*, gateway-authenticated path from the client to the authoritative validator. The validator is reached over gRPC, but the client must also run as a **web export**, where the browser cannot set the custom WebSocket upgrade headers that a raw gRPC or gateway connection would normally require for authentication. We therefore need a single transport that satisfies all of: low-latency realtime delivery, authentication enforced at the gateway in production, and compatibility with web exports that cannot attach upgrade headers — while keeping the client to one codepath across local development and production rather than forking transport logic per environment.

## Decision
Expose the validator as gRPC reached through the Snapser Hermes WebSocket. Requests are wrapped in the snap-api-proxy protobuf envelope and the player token is carried in the WebSocket query string (token=<player-id>) rather than in upgrade headers, so the connection works from web exports. The identical envelope is emulated locally on ws://localhost:5555/hermes/ws, so the client uses one transport codepath for both local development and production.

## Consequences
The client has a single transport codepath for both local development and production, since the local emulator on :5555 speaks the identical snap-api-proxy envelope as Hermes in prod.

The client is coupled to the snap-api-proxy protobuf envelope: changes to the envelope schema require coordinated updates on both the client and the emulator, and the envelope must be kept in lockstep with what Hermes expects.

Authentication is delegated to the Snapser gateway in production (token in the query string), so the validator itself does not implement auth; the local emulator must stand in for that gateway behavior during development.

## Relations
_None._
