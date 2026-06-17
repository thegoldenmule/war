# Assets

Art and visual resources for the War client. **Placeholder** — the pipeline is sketched here and
filled in behind `# TODO(skeleton):` markers as Phase 2 (playable single-player) lands.

## What lives here

- **Card faces** — 52 standard cards (ranks 2..14 × clubs/diamonds/hearts/spades). One per
  rank+suit, drawn in the occult-arcade style.
- **Card backs** — the face-down back shown during the deal and the flip moment (the moment a
  Special Card is played before the reveal).
- **Special Card art** — collectible power-up faces (peek, steal-tie, rank-boost, …), the
  Balatro-style hook / monetization surface.
- **UI chrome / icons** — table, pot, WAR-stake, currency, and meta-shell furniture.

## Style

Occult-arcade: violet accent `#b400ff` (hover `#d24bff`) on near-black `#13111c`, green `#44ff88`
for selection, white for peak emphasis. Mirror the `editor_tool_kit` palette wherever UI is
drawn. Portrait orientation (720×1560), GL Compatibility renderer — keep textures lightweight and
hypercasual-readable at phone size.

## Conventions

- Reference assets from GDScript/scenes by `res://assets/...` paths.
- Source/master files (large PSDs, etc.) are workspace-ignored; commit only the exported,
  game-ready resources Godot imports.
- Do NOT hand-write `.import` files — Godot regenerates them on import.

# TODO(skeleton): finalize directory structure (cards/, backs/, specials/, ui/), naming scheme,
# atlas/sheet layout, and the import presets once art exists.
