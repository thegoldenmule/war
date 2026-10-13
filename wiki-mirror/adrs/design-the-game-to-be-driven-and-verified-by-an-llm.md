# Design the game to be driven and verified by an LLM

**Status:** accepted

## Metadata
- **Number:** ADR-38
- **Date:** 2026-06-17
- **Scope:** tooling

## Context
We want an LLM agent to be able to *play, inspect, and verify* War **headlessly** — without the Godot editor, a human, or any rendered UI in the loop. The game is built on a hard wall between a pure deterministic rules engine and presentation, and that engine is hash-identical between the GDScript client (`game/logic`) and the TypeScript validator (`validator/src/logic`). To exercise that contract, an agent needs to start matches, submit actions (including the face-down *flip moment* of playing a Special Card before the reveal), read back the resulting state and its 8-lane rolling state hash, and assert parity between client and authoritative validator. Today that surface is implicit — buried in scene code, signals, and editor-driven flows — so automated play and verification are awkward and brittle. The forces in tension are: presentation churn (the UI will change constantly) versus the need for a *stable, programmatic entry point*; and the desire for cheap, repeatable headless testing versus the cost of building and maintaining that control surface.

## Decision
Expose a first-class control surface that lets an LLM agent drive and verify the game headlessly, with no editor dependency. This comprises: a WarDebug autoload that scripts the game loop (start a match, submit actions including Special-Card plays, query current state and the 8-lane state hash); headless verifiers that run the deterministic engine end-to-end and assert client/validator parity; and the validator MCP, through which an agent reaches the authoritative TypeScript validator to confirm hashes match. Together these form a stable scripting API treated as a supported product surface, not an internal debug afterthought.

## Consequences
A stable scripting API becomes a first-class requirement: the WarDebug autoload, headless verifiers, and validator MCP signatures are versioned and maintained as a public contract, and breaking them is a deliberate, reviewed change rather than incidental.

Testing and automation become cheap: matches can be started, played, and verified for client/validator hash parity from scripts and CI without launching the editor or rendering UI, making regression detection and agent-driven play routine.

UI and presentation work must keep the control API intact: any change to scenes, signals, or flows has to preserve the headless entry points, adding a constraint on how presentation is allowed to evolve.

## Relations
_None._
