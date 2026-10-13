# Authenticate BYOSnap requests by trusting the gateway-stamped User-Id

**Status:** accepted

## Metadata
- **Number:** ADR-9
- **Date:** 2026-06-17
- **Scope:** auth

## Context
The validator needs to bind each match to its owner so that one player cannot read or mutate another player's match state. We do *not* want to re-implement authentication inside the snap: minting, validating, and rotating credentials is exactly the responsibility the Snapser platform already owns. As a BYOSnap behind the Snapser gateway, every authenticated request arrives with a gateway-validated `User-Id` header — the gateway is the trust boundary that has already verified the caller's identity. Locally, however, there is no gateway in front of the validator: requests come straight over the Hermes WebSocket (`ws://localhost:5555/hermes/ws?token=<player-id>`), so identity must come from somewhere the dev and test harness controls. We need one binding rule that works both behind the gateway in production and in the gateway-less local/test setup.

## Decision
Trust the Snapser gateway-validated User-Id and bind every RPC to that player_id as the match owner. The validator does not verify any signature itself; it reads the identity the gateway has already stamped and authorizes the call against the owning player_id. Locally, where no gateway sits in front of the snap, the ?token= query param IS the self-stamped player id and is used as that same identity. API-key / internal callers (no end-user identity) pass through unbound, not tied to any player_id.

## Consequences
No signature or token-verification scheme lives inside the snap; the Snapser gateway is the sole auth boundary, and the validator's job is reduced to reading the stamped User-Id and binding the match to that player_id.

Local development and tests self-stamp identity via the ?token= query param, giving an identical owner-binding code path with and without a real gateway, so the same authorization logic is exercised everywhere.

API-key / internal callers carry no end-user identity and are therefore unbound (not tied to any player_id); such calls must not be allowed to reach owner-scoped RPCs without a separate explicit check.

## Relations
_None._
