# Editor Tool Framework

**Status:** current

## Kind
package

## Summary
The vendored `editor_tool_kit` (`game/addons/editor_tool_kit`) is a set of shared, *editor-only* base classes for building in-editor authoring tools: an `EditorToolPlugin` composition root, a headless-testable `ToolService` core, an atomic `ContentStore`, `EditorToolUi` builders, an optional `BridgeServer`, and a shared occult-arcade `EditorToolPalette` + `EditorToolTheme`. A consuming tool (e.g. a card/catalog editor) is just a *service + a view* on these bases, inheriting persistence, layout, status, styling, and optional MCP/CLI access for free.

## Purpose
It exists to make every in-editor authoring tool look and behave identically with almost no per-tool boilerplate: the *framework* enforces a header (title, version, self-reload button), cascades one theme to every dock, and keeps each tool's logic in a `Node`-free, `Control`-free service so it is verifiable under `godot --headless` without an editor. It is *vendored* into this project (a fresh clone works offline) but *sourced* from `github.com/thegoldenmule/godot-editor-tk`, so the kit ships its own in-editor self-update panel — built on its own bases, so it dogfoods what it distributes.

## Design notes
The kit is mostly a framework: enabling it keeps the class_name globals (EditorToolPlugin, ToolService, ContentStore, EditorToolUi, BridgeServer, EditorToolPalette, EditorToolTheme) registered for the tools that subclass them. Register a consuming tool in project.godot [editor_plugins] and commit the .gd.uid files. The enforced header gives every tool a title (left) plus version and a self-reload button (right) for free; the reload button disable-then-enables the plugin.

EditorToolUi (static) provides pure construction helpers with no state: split_root, tool_header (the enforced title/version/reload bar the plugin mounts), label_wrap, form_row, button, button_bar, spin, status_label, section (a violet-bordered captioned group frame), and restyle_selected. EditorToolPalette defines one violet accent (#b400ff, hover #d24bff) on near-black, green #44ff88 for selection, and white for peak emphasis; it is owned by the tool kit and never loads a host project's theme, so the kit and host UI stay visually aligned yet fully decoupled. Per-control overrides still win locally over the cascade. EditorToolTheme.build() returns a plain Theme Resource with full state coverage, so it is constructible and assertable under godot --headless.

BridgeServer is an optional localhost HTTP base (TCPServer poll loop, Content-Length framing, async dispatch, headless skip) for an MCP/CLI shim; a subclass overrides _resolve_port() and _route(method, path, query, body) -> {code, payload}. It is opt-in per tool.

Self-update: the Editor Tool Kit bottom-panel tab checks the source repo and pulls a newer copy in place, mirroring how the godot-ai plugin distributes itself. update_service.gd (a ToolService) owns the version check + download with static, headless-testable parse_remote_version / is_newer helpers; update_panel.gd is the view; update_reload_runner.gd disables the plugin, extracts the archive's addons/editor_tool_kit/ subtree (atomic .tmp + rename per file with rollback on failure), waits for a filesystem scan, then re-enables the plugin. Limits: the install overwrites and adds files but never prunes (a file removed upstream lingers until deleted by hand), and an update clobbers local edits to the vendored copy, so the repo is the source of truth. Only Godot >= 4.4 supports the in-editor reload (the project ships 4.6). The kit's own architecture is documented in the separate Godot Editor TK wiki workspace.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- `game/addons/editor_tool_kit/README.md`
- class `EditorToolPlugin` in `game/addons/editor_tool_kit/editor_tool_plugin.gd`
- class `ToolService` in `game/addons/editor_tool_kit/tool_service.gd`
- class `ContentStore` in `game/addons/editor_tool_kit/content_store.gd`
- class `EditorToolUi` in `game/addons/editor_tool_kit/editor_tool_ui.gd`
- class `BridgeServer` in `game/addons/editor_tool_kit/bridge_server.gd`
- class `EditorToolPalette` in `game/addons/editor_tool_kit/tool_palette.gd`
- class `EditorToolTheme` in `game/addons/editor_tool_kit/tool_theme.gd`
- function `parse_remote_version` in `game/addons/editor_tool_kit/update_service.gd`
- `game/addons/editor_tool_kit/update_reload_runner.gd`

## Data model
A tool is three small files, each subclassing a base. `plugin.gd` extends `EditorToolPlugin` and overrides only `_config()`, which returns a Dictionary declaring the pieces (`panel` tab title, `service`, `dock`, optional `bridge`, cosmetic `service_name`/`dock_name`); the plugin constructs `service` then optional `bridge` then `dock` (injecting the service into bridge and dock), mounts the dock beneath the enforced header in the bottom panel, and reverses it all in `_exit_tree`. `<tool>_service.gd` extends `ToolService` (a `Node`) and owns the tool's state and change signals, returning the `{ok, error?}` contract via `ok(data)` / `err(msg, code)` and tracking `mark_dirty()` / `is_dirty()`. `dock.gd` is a `Control` with an injected `service` property, built with `EditorToolUi` builders, re-rendering on the service's change signal. `ContentStore` (static, `RefCounted`) handles persistence: `load_json(path)`, atomic N-target `save_all(targets, validate, scan)` (validate-then-write-all then rescan), and `bump_then(struct, key, do_save, when)` (version bump that rolls back if the save fails); the canonical serializer stays per-tool because field order is domain-specific.

## Usage
_None._

## Invariants & constraints
- A `ToolService` carries NO `Control` / `EditorInterface` references, so the tool's logic loads and runs under `godot --headless` — which is what makes it verifiable without the editor.
- There is no per-dock styling code: `EditorToolPlugin` assigns the one `EditorToolTheme` to the panel root and it cascades to every descendant via Godot's `Control.theme`, so a new tool inherits the occult-arcade look for free; `EditorToolPalette` is the single source of truth for colors + metrics.
- The version shown in the enforced header is read from the tool's own `plugin.cfg`; the self-update ship signal is `plugin.cfg`'s `version` on the source repo's default branch, checked raw at `raw.githubusercontent.com/.../addons/editor_tool_kit/plugin.cfg` and compared as dotted versions.
- Docks bind service signals with method callables (not lambdas) so a hot-reload or late async signal cannot fire into a freed view; the self-update reload runner is parented OUTSIDE the plugin so it survives `set_plugin_enabled(false)`.

## Synced commit
_None._
