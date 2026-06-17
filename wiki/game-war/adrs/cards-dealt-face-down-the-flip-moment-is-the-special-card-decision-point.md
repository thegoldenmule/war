# ADR-12: Cards dealt face-down: the flip moment is the Special-Card decision point

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** design

## Context
Classic War is a game of *pure chance with zero player agency*: each round both players simply flip their top card and the higher rank wins. The outcome is fully determined by the shuffle, so the player makes no decisions and has no moment of authorship over a round. That is fine for a children's card game, but it gives us nothing to build a hypercasual loop around — no tension beat, and critically *no monetization surface*. We want a single, repeatable moment where the player exercises agency, feels the swing of a round turn in their favor, and where a collectible power-up can be meaningfully spent. The constraint is that any such agency must resolve inside the deterministic rules engine so the client's optimistic play stays byte-for-byte hash-identical to the authoritative validator.

## Decision
Deal the round cards FACE-DOWN rather than face-up, and insert a decision beat before the reveal. During that beat the player may play a collectible Special Card (a Balatro-style power-up), recorded on the engine state as state.pending_special. The reveal then becomes a dramatic flip of the face-down cards, with any played Special Card resolving as part of that flip. This requires a new "selected" phase in the round state machine, sitting before the existing "flipped" phase: deal face-down -> selected (optional Special Card chosen, pending_special set) -> flipped (cards revealed and Special Card effect resolved) -> resolve winner. Special Cards must resolve entirely inside the deterministic engine so client and validator stay hash-identical.

## Consequences
Creates genuine player agency in a game that previously had none: each round now has a real decision point (play a Special Card or hold it) instead of a pure coin flip, giving the player authorship over the round's outcome.

Establishes the core monetization and collection hook: the face-down beat is the natural surface where collectible Special Cards are spent, directly connecting the gacha/shop meta layer to the moment-to-moment loop.

Adds engine and presentation complexity: the round state machine gains a new "selected" phase before "flipped" (with state.pending_special), and every Special Card effect must be implemented deterministically inside the rules engine so the optimistic client reconciles byte-for-byte against the authoritative validator.

## Relations
_None._
