# Adopt Snapser as the online backend

**Status:** accepted

## Metadata
- **Number:** ADR-8
- **Date:** 2026-06-17
- **Scope:** backend

## Context
The meta layer around the core War loop needs a substantial set of online services — *anonymous authentication*, *inventory and currency* (Gems, the Special-Card collection), *leaderboards*, *remote configuration* for live tuning, and a *realtime* channel to reach the authoritative validator. Building and operating a bespoke server for all of this from scratch would be a significant up-front and ongoing cost, pulling effort away from the game itself and slowing down live-ops iteration. At the same time, the architecture demands a *server-authoritative* boundary: currency and item grants must be issued by a trusted backend (never the client), and the deterministic validator must run server-side and be reachable from the client over a realtime transport. We need a backend platform that provides these building blocks off the shelf while still letting us deploy our own validator container into the same fabric.

## Decision
Adopt Snapser as the online backend. Use its managed services for the meta layer: anonymous auth, Inventory (Gems and the Special-Card collection), Leaderboards, Remote Config, and Hermes for realtime. Deploy the deterministic TypeScript validator as a BYOSnap (bring-your-own containerized snap) so it runs inside the Snapser fabric and is reachable from the client over gRPC via the Hermes WebSocket.

## Consequences
Faster live-ops: managed auth, inventory/currency, leaderboards, and remote config are available out of the box, so engineering effort stays on the game rather than on building and operating backend infrastructure.

Currency and item grants become server-authoritative: Gems and Special-Card awards are issued by Snapser Inventory on the trusted backend, never minted by the client, closing off a major class of exploits.

Accepts a platform dependency: we are coupled to Snapser's availability, pricing, and feature set, and the validator must ship as a containerized BYOSnap built and deployed to the Snapser fabric.

## Relations
_None._
