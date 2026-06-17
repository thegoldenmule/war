# Assets

Art and visual resources for the War client. **Placeholder** — the pipeline is sketched here and
filled in behind `# TODO(skeleton):` markers as Phase 2 (playable single-player) lands.

## What lives here

- **Card faces** — 52 standard cards (ranks 2..14 × clubs/diamonds/hearts/spades). One per
  rank+suit, drawn in the reference casual card-game style.
- **Card backs** — the face-down back shown during the deal and the flip moment (the moment a
  Special Card is played before the reveal).
- **Special Card art** — collectible power-up faces (peek, steal-tie, rank-boost, …), the
  Balatro-style hook / monetization surface.
- **UI chrome / icons** — table, pot, WAR-stake, currency, and meta-shell furniture.

## Style

Casual card-game look from the reference prototype (`~/projects/thirdparty/War/docs`): a neutral
gray table `#9e9e9e`, steel-blue card backs `#5b7fb0`, off-white faces `#f4f4f4` with black
ink/borders `#1a1a1a`, an orange accent `#ee7e2d` for the primary action, and green/red
(`#3fa34d`/`#c0392b`) win-loss outlines, with white modal banners. The single source of truth is
`ui/ui_palette.gd` (`WarPalette`) — match it wherever UI is drawn. This is the GAME look, distinct
from the vendored `editor_tool_kit`'s violet *editor* theme. Portrait (720×1560), GL Compatibility
renderer — keep textures lightweight and hypercasual-readable at phone size.

## Conventions

- Reference assets from GDScript/scenes by `res://assets/...` paths.
- Source/master files (large PSDs, etc.) are workspace-ignored; commit only the exported,
  game-ready resources Godot imports.
- Do NOT hand-write `.import` files — Godot regenerates them on import.

# TODO(skeleton): finalize directory structure (cards/, backs/, specials/, ui/), naming scheme,
# atlas/sheet layout, and the import presets once art exists.
