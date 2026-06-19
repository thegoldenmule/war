# ADR-11: Adopt the shared editor_tool_kit framework (vendored-but-sourced)

**Status:** accepted

## Metadata
- **Date:** 2026-06-17
- **Scope:** tooling

## Context
We are building several *in-editor authoring tools* — a card editor, a catalog editor, and more to come — that each need the same plumbing: persistence of their working state, window/panel *layout*, consistent *theming* with the rest of the editor, and optional *MCP access* for agent-driven authoring. Reimplementing this plumbing per tool produces boilerplate, drift between tools, and an inconsistent author experience. We want a shared foundation so each new tool is just its domain logic plus a view, not yet another bespoke shell.

## Decision
Vendor the editor_tool_kit addon into the project and build every authoring tool against it, where a tool is modeled as a ToolService (headless logic + persistence) plus a view (presentation). Source the addon from github.com/thegoldenmule/godot-addons and keep it current via an in-editor self-update panel; the addon version is the ship signal that tells us which revision is in use. Treat the vendored copy as read-only — all changes land upstream and flow back down through the self-update panel.

## Consequences
Tools become headless-testable: because logic lives in a ToolService separate from its view, behavior can be exercised without the editor UI.

Tools are visually consistent: shared theming, layout, and persistence give every authoring tool the same look and feel with no per-tool boilerplate.

The vendored copy is read-only and edits must land upstream at github.com/thegoldenmule/godot-addons; usage and integration details live in the editor_tool_kit section of the Godot Addons wiki.

## Relations
_None._
