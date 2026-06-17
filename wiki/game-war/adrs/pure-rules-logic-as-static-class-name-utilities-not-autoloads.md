# ADR-4: Pure rules logic as static class_name utilities, not autoloads

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** client/logic

## Context
The rules engine sits behind a *hard wall* from presentation and must satisfy two non-negotiable constraints. First, it has to load and run under `godot --headless` — there is no scene tree, no rendering, and no engine lifecycle to lean on — so that golden-vector verifiers can drive it in CI and confirm it stays byte-for-byte *hash-identical* to the TypeScript engine. Second, it must be *trivially testable*: a verifier should be able to construct a state, apply a move, and assert on the result without standing up any global context. Godot's idiomatic answer to shared services is the *autoload singleton*, but autoloads register against the scene tree, are instantiated at engine boot, and naturally accumulate *hidden mutable state* across calls. State that lives in a singleton is implicit input to every function that touches it: it is hard to reset between golden vectors, easy to leak between test cases, and a constant source of nondeterminism — exactly the failure mode a deterministic, hash-stable engine cannot tolerate.

## Decision
Implement game/logic as static functions on class_name RefCounted types (WarEngine, WarHasher, WarRng, ...) rather than as autoload singletons that hold state. The types carry no instance fields used as engine state; all game state is passed in explicitly and a new state is returned, e.g. through WarEngine.apply(state, move). Nothing in the logic layer registers as an autoload or reaches into the scene tree.

## Consequences
No hidden global state: every input to the engine is an explicit argument and every result is an explicit return value, so behavior is a pure function of its inputs — the precondition for determinism and byte-for-byte hash-identity with the TypeScript engine.

Golden-vector verifiers become easy to write: a test constructs a state, calls a static function, and asserts on the returned state and rolling hash, with no autoload to bootstrap, no scene tree to spin up, and nothing to reset or tear down between cases.

State is threaded explicitly through apply() and returned anew rather than mutated in place, so callers (the optimistic client and the authoritative validator alike) own and pass the state, keeping the logic layer free of lifecycle coupling and runnable under godot --headless.

## Relations
_None._
