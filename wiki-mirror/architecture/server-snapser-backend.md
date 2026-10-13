# Server (Snapser Backend)

**Status:** current

## Kind
service

## Summary
The **Snapser platform backend**: anonymous auth, **Inventory** (Gems + owned Special Cards), **Leaderboards**, **Remote Config** (the Special-Card catalog), and the **Hermes gateway** that proxies client traffic to the validator BYOSnap. It is mostly *platform configuration* rather than bespoke code.

## Purpose
Provides the *server-authoritative* spine for the meta layer so the client never grants currency or cards to itself. Anonymous auth mints the `player_id` the validator binds actions to; Inventory holds the player's Gems and Special-Card collection; Remote Config serves the live Special-Card catalog the client and validator both read; Leaderboards rank players; and the Hermes gateway is the single front door that authenticates every request (stamping a trusted `User-Id`) and forwards gameplay validation to the validator BYOSnap.

## Design notes
This page documents platform configuration, not a bespoke service in this repo. The concrete Snapser artifact that lives here is the validator BYOSnap profile (snapser-byosnap-profile.json), which declares the gRPC ValidatorService, the Hermes snap-api-proxy transport binding, the gateway-stamped-user-id auth model, and env such as CARD_CATALOG_PATH. Auth, Inventory, Leaderboards, and Remote Config are stock Snapser snaps configured in the Snapser console rather than implemented in code.

Anonymous auth on the client side is a thin identity provider (game/net/snapser_auth.gd, WarSnapserAuth). In REMOTE mode it performs an anonymous login against the Snapser auth snap and caches {session_token, user_id, expires_at}; in LOCAL mode it synthesizes a device-stable player id and uses it as both the player id and the token, so the transport has one codepath in both environments.

The Hermes gateway proxies to the validator BYOSnap via the snap-api-proxy message type. The client opens one persistent WebSocket and multiplexes request/response over Hermes ClientMessage/ServerMessage envelopes; the inner snap-api-proxy payload names a validator method and carries its args. Locally the validator serves the identical envelope at ws://localhost:5555/hermes/ws so no environment branching is needed beyond the base URL and token. See the Validator and Realtime Gateway (Hermes) pages for the server side.

Meta features that depend on this backend (daily login bonus, daily challenges, shop and IAP, gacha pulls, XP and levels, seasonal events and battlepass) all reduce to authoritative Inventory mutations plus Remote Config reads. The economic and progression design for these lives in the Meta & Monetization Layer design document.

## Components
_No components._

## Dependencies
- **depends-on** → [Validator](architecture:mqiff2bc-00bx-2cojm9) — Hermes proxies client traffic to the validator BYOSnap (InitMatch / ValidateAction / CompleteMatch).
- **depends-on** → [Realtime Gateway (Hermes)](architecture:mqifg9io-00cj-1nzngt) — The Realtime Gateway (Hermes) is the snap-api-proxy front door this backend exposes.

## Code references
- `validator/snapser-byosnap-profile.json`
- `validator/content/card_catalog.json`
- `validator/content/card_catalog.schema.json`
- class `WarSnapserAuth` in `game/net/snapser_auth.gd`
- class `WarHermesClient` in `game/net/hermes_client.gd`
- function `resolvePlayerId` in `validator/src/validator/hermes-ws.ts`

## Data model
State lives in managed Snapser services, not in this repo. **Inventory** stores per-player Gem balance and owned Special-Card ids. **Remote Config** hosts the Special-Card *catalog* — versioned card definitions (`id`, `name`, `when`, `rarity`, `desc`), authored locally in `validator/content/card_catalog.json` and mirrored to Snapser; the validator also loads it from `CARD_CATALOG_PATH`. **Leaderboards** keep ranked score tables. **Auth** mints a session token bound to `player_id`; locally there is no real auth, so the `?token=<player-id>` query param is the self-stamped identity. None of these hold the *match* state — that is owned by the validator BYOSnap and rides as canonical-JSON strings through Hermes.

## Usage
_None._

## Invariants & constraints
- Currency (Gems) and Special-Card grants are server-authoritative: only Snapser-managed Inventory mutates balances and collections; the client may predict but never self-grants.
- Identity is gateway-stamped: in production the Snapser gateway authenticates the session token and stamps a trusted `User-Id` header bound to `player_id`; the client never sets `User-Id` itself (locally the `?token=` query param is the self-stamped equivalent).
- The Special-Card catalog has a single source of truth: card definitions are authored once (validator/content/card_catalog.json) and served via Remote Config, so the client, validator, and shop all read identical card data.
- Hermes is the only client-facing entry point to gameplay: all validator RPCs (InitMatch / ValidateAction / CompleteMatch) are reached through the gateway's snap-api-proxy envelope, never by the client talking to the BYOSnap directly.

## Synced commit
_None._
