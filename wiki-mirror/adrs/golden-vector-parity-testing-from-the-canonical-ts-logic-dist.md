# Golden-vector parity testing from the canonical TS logic dist

**Status:** accepted

## Metadata
- **Number:** ADR-5
- **Date:** 2026-06-17
- **Scope:** testing

## Context
The whole architecture rests on a *parity* claim: the GDScript rules engine in `game/logic` and the TypeScript engine in `validator/src/logic` must be **byte-for-byte hash-identical** — same canonical JSON, same 8-lane rolling state hash — so the optimistic client and the authoritative validator agree. That claim only has value if it is *proven*, and the obvious failure mode is proving it against ourselves: if we hand-write the expected state hashes, we are asserting what we *think* the hash should be, not what the canonical logic actually produces. A typo, a misremembered lane order, or a copied-then-stale value silently bakes a wrong expectation into the suite, and a hand-written hash can be quietly 'fixed' to match a regression instead of catching it. We need a single, mechanical source of truth for the expected vectors that is independent of the GDScript side under test.

## Decision
Generate golden state-hash vectors directly from the canonical TypeScript logic (validator/src/logic) and treat those vectors as the authoritative expectations. The GDScript engine must reproduce them: headless verifiers (tools/verify_*.gd) and the in-editor McpTestSuite replay the same scripted inputs through game/logic and assert the resulting 8-lane state hash matches the TS-generated golden vector exactly. The TS side is the source of truth for vectors; expected hashes are never authored by hand.

## Consequences
Expected hashes are never hand-written. The only legitimate way to produce or update a golden vector is to regenerate it from the canonical TS logic; any expectation that did not come out of that generator is invalid by construction.

A changed golden hash is a signal, not a chore. If a vector's hash moves, it means GDScript and TS no longer agree on canonical JSON or the rolling hash — i.e. a broken-compatibility regression — and must be investigated, not blindly re-baselined to make the suite green.

The TypeScript logic is the designated source of truth for parity vectors, so its build/dist must be runnable in CI to produce vectors, and both the headless verifiers (tools/verify_*.gd) and the editor McpTestSuite consume the same generated vector set rather than maintaining divergent expectations.

## Relations
_None._
