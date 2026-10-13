# Hard wall between deterministic logic and presentation

**Status:** accepted

## Metadata
- **Number:** ADR-31
- **Date:** 2026-06-17
- **Scope:** client

## Context
Determinism is the foundation of the game: the GDScript rules engine must stay *byte-for-byte hash-identical* to the TypeScript validator so the client can play optimistically and reconcile against the authoritative service. That guarantee is **fragile if rendering can mutate state** — once presentation code (nodes, scenes, tweens, signals, frame timing) is allowed to reach into the game state, ordering and frame-rate differences leak in, the rolling state hash diverges from the validator, and reconciliation breaks. The forces in tension are: keeping logic pure and portable enough to run headless on both the client and the server, versus the convenience of letting view code read and write game state directly.

## Decision
Enforce a strict one-directional boundary: input -> action -> logic(pure) -> new state + hash -> presentation renders. The game/logic layer carries zero Node or scene dependencies and is fully headless. Presentation may read the resulting state and hash to render, but it never mutates game state except by submitting an action message back through the pipeline.

## Consequences
Logic is headless-testable and portable: the same engine runs in the Godot client and the TypeScript validator, preserving the byte-for-byte hash identity that makes optimistic play and reconciliation possible.

Some duplication of view state is unavoidable, since presentation must hold its own render-facing copy derived from game state rather than mutating the authoritative state in place.

All input must be expressed as action messages; there is no path for UI code to poke state directly, which adds a small amount of boilerplate but keeps every state transition deterministic and replayable.

## Relations
_None._
