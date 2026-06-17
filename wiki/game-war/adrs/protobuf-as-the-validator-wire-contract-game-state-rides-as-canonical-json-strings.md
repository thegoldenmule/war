# ADR-6: Protobuf as the validator wire contract; game state rides as canonical-JSON strings

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** wire

## Context
The wire format between the client, the authoritative validator, and the determinism hash must be *stable* and *SDK-friendly* — generated bindings, versioned messages, a clean RPC envelope — without re-modelling the hash domain. The determinism guarantee rests on the GDScript and TypeScript engines being byte-for-byte hash-identical, and that hash is computed over one *exact* canonical-JSON representation of game state and actions. If protobuf were to re-model that state as typed message fields, we would have two competing serializations of the same domain: the protobuf wire shape and the canonical JSON the hash is taken over. Any drift between them — field ordering, default handling, number formatting, optional-vs-absent — would silently break hash agreement and the optimistic-play/reconcile loop. We need protobuf's transport and tooling benefits without letting it become a second source of truth for the hashed state.

## Decision
Protobuf defines only the RPC envelope (the messages and service in validator/protos): request/response wrappers, identifiers, status/error codes, and the like. Game state and actions do NOT get re-modelled as protobuf fields — they travel as canonical-JSON STRING fields carried inside those messages. The determinism hash is computed over that exact JSON string, so the wire never owns a second representation of the hashed domain. Language bindings are generated from the committed protos.

## Consequences
Protos never re-model game state or actions: they stay a thin envelope, so the hash domain has exactly one owner (the canonical JSON) and protobuf cannot drift into a competing serialization that would silently break hash agreement.

There is one canonical-JSON representation shared across the client, the validator, and the determinism hash — the same string is transmitted, validated, and hashed end to end, keeping the optimistic-play/reconcile loop sound.

Bindings are generated from the committed protos, so the wire contract is versioned and SDK-friendly; the tradeoff is that state/action payloads are opaque strings on the wire (no protobuf type-checking of their contents — validation lives in the engine, not the transport).

## Relations
_None._
