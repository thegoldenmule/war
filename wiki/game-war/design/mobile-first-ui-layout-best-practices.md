# Mobile-First UI Layout — Best Practices

**Status:** active

## Body
**Moveborne is mobile-first and portrait-only.** Every screen must be designed, built, and verified against the reference surface below before it is committed. Features have repeatedly shipped that overflow the screen or overlap the persistent chrome (Story Mode is the canonical offender). This page is the standing rule set that prevents that — treat it as a gate, not a suggestion.

## The reference surface — 360 × 780 logical px

The project renders to a 720 × 1560 viewport at `stretch/scale = 2.0`, so the **logical design surface every Control lays out against is 360 × 780**. Design at 360 × 780; the renderer scales it up. These are the committed display settings (`game/project.godot`):

| Setting | Value |
| --- | --- |
| `window/size/viewport_width` | 720 |
| `window/size/viewport_height` | 1560 |
| `window/stretch/mode` | `canvas_items` |
| `window/stretch/aspect` | `expand` |
| `window/stretch/scale` | 2.0 |
| `window/handheld/orientation` | `portrait` |
| **Logical design surface** | **360 × 780** |

**aspect = expand** means taller/shorter devices give you _more or less height than 780_ (and oddly-wide ones more width). 780 is therefore the **shortest height you must fit in**, not a fixed canvas — never assume extra vertical room. Design to fit 780; let surplus height breathe.

## The chrome budget — what is actually usable

The app shell paints persistent chrome on its own CanvasLayers that sits _on top of_ every screen. A screen does not own the full 360 × 780 — it owns the content host between the bands. Budget against this, not the raw viewport:

| Region | Logical size | Owner |
| --- | --- | --- |
| Top currency band | ~44 px tall (+ top safe inset) | `currency_bar.gd`, own CanvasLayer |
| Bottom nav bar | ~96 px tall (+ bottom safe inset) | `app_shell.gd`, own CanvasLayer (layer 5) |
| **Usable content host** | **~360 × 640** | `_content` in `app_shell.gd` |

So a typical tab screen has roughly **360 wide × 640 tall** of safe drawing area, and less on devices with notches or gesture bars. **Anything that assumes 780 of usable height will overlap the nav bar.**

## Two screen archetypes — hosted vs. takeover

Not every screen lives inside the content host, and the two kinds have **different layout contracts** — confusing them is the recurring source of edge collisions:

- **Hosted tab screens** (Home, Leaderboard, Settings, Collection, Guilds) — instanced into the shell's `_content` host, which is already inset for the chrome bands _and_ the device safe area. They get the safe region for free: fill it (ideally via `WarScreenScaffold`) and never re-add chrome offsets.
- **Full-screen takeovers** (the match/gameplay scene, the Story map) — pushed by the UiRouter, which _hides_ the nav + currency bands. They own the raw viewport edge-to-edge, so the shell's safe-area handling is gone with the bands. A takeover must inset its own header/footer for **both** the top notch and the bottom home indicator itself (see the safe-area rule).

The bug pattern: a takeover that assumes the shell still protects its edges puts its back button under the notch and its primary action button under the home indicator. _Both_ current takeovers have a version of this — the match scene insets the top but not the bottom; the Story map insets neither.

## The rules

1. **Design to 360 × 780, build to the content host.** Lay every screen out so it fits within ~360 × 640 of usable space at the reference surface. If it does not fit, it must scroll (next rule) — it may never extend under the nav bar or currency band.
2. **Any list, feed, or grid that can grow goes in a **`ScrollContainer`. Level lists, missions, leaderboards, inventory — if item count is data-driven, assume it overflows 640 px and make it scroll. A fixed VBox of N data rows is a bug waiting for the (N+1)th row. (This also applies to modal panels whose item set can grow — an avatar grid, a reward list.)
3. **Lay out with containers, not absolute positions.** Prefer `VBoxContainer`/`HBoxContainer`/`CenterContainer`/`MarginContainer` + anchors + `size_flags`. Hardcoded `position`/`offset` pixel values are the single biggest source of overflow and overlap — they do not adapt when height changes or content grows. (A bespoke game HUD that sizes everything off the live viewport, like the match scene, is the rare justified exception — but it still must respect the safe area.)
4. **Never hardcode the chrome insets.** Do not bake the ~44 px top / ~96 px bottom gutters into a hosted screen. Lay out inside the content host the shell hands you. When the band heights change, every screen that copied the numbers breaks silently.
5. **Respect the safe area — both edges.** Hosted screens inherit it from the content host. Full-screen takeovers do not: they must apply the _top_ inset (notch/status bar) to their header and the _bottom_ inset (home indicator/gesture bar) to their footer themselves, via `DisplayServer.get_display_safe_area()` (physical→logical converted). Full-bleed art may extend under insets; interactive controls and text must not. The physical→logical inset math currently lives in three copies (`app_shell.gd`, `currency_bar.gd`, `main.gd`) — factor a shared helper when you next touch it. On desktop/editor both insets resolve to 0, so overflow only shows on device (see Verifying).
6. **Mind the width, not just the height.** 360 logical px is narrow and the brand font (Grammara) is wide — long titles and labels overflow horizontally before they overflow vertically (Leaderboard caps its title at 24 px for exactly this reason; Home shrinks the PvP label). Cap font sizes, set `clip_text` / `autowrap_mode`, and verify with the longest _real_ string, not a short placeholder.

## Use the existing primitives — do not reinvent

- `WarScreenScaffold` (`game/ui/screen_scaffold.gd`) — a `MarginContainer` that gives a screen a responsive frame: a constant `SIDE_PAD = 24` on phones, and on wide displays it centers content and caps it at `MAX_CONTENT_WIDTH = 480` so it never stretches edge-to-edge on a tablet. Settings and Leaderboard use it; new list/form screens should too.
- _The shell content host_ — parent screens under `_content`; it is already sized to the gap between the bands. Do not parent screen content directly to a CanvasLayer at full viewport size.
- `ScrollContainer` + `VBoxContainer` (`size_flags_vertical = EXPAND_FILL` on the inner box) — the standard pattern for any growable list. See `story_map.gd`'s `_level_list`.

## Anti-patterns (learned from Story Mode)

Story Map (`game/ui/screens/story_map.gd`) is the worked example of what to avoid. It positions its body with hardcoded gutters — `body_pos = (24, 122)` and `body_size = (vp.x - 48, vp.y - 122 - 96)` — and stacks 15 fixed-height level rows (~865 px of content) into a region that is only ~562 px tall at the reference surface. Concretely:

- **No safe-area handling**: as a full-screen takeover it owns the raw viewport (the bands, and their insets, are hidden) yet never re-applies them — the `‹ Home` button (y=14) and title (y=16) sit under a top notch, and the Play button (bottom −20) under the home indicator.
- **Hardcoded top/bottom gutters** (122 / 96) bake the header/footer heights into magic numbers that drift the moment either changes.
- **No fit check**: the body rect consumes whatever space is there with no assertion the content fits; on the 780 surface it overflows by ~300 px.
- **Mixed absolute + scroll**: a full-size `TextureRect` map, an overlay dot layer, and a `ScrollContainer` all pinned to the same hand-computed rect — fragile and easy to overlap.

**The fix pattern:** wrap the body in a padded frame, put the header in a top region and the growable body in a `ScrollContainer` that fills the remaining space via container expansion (not a computed pixel rect), and — because it's a takeover — apply the top and bottom safe insets itself rather than relying on the (now-hidden) shell.

## Pre-commit checklist

- Screen fits within ~360 × 640 of usable content at the 360 × 780 reference surface, with no element under the nav bar or currency band.
- Every data-driven list/grid is inside a `ScrollContainer`; verified with more items than fit on one screen.
- No hardcoded chrome-inset offsets; layout uses containers + anchors + `size_flags`, not absolute pixel positions for content flow.
- Interactive controls and text stay inside the safe area; only full-bleed art extends under insets.
- Verified visually at 360 × 780 (see below) — not just in a maximized editor window.

## Verifying

Check fit at the real surface, not a desktop-sized window. Run the game and confirm at 360 × 780, or drive the screen headless via the WarUi semantic UI driver (UI Control API (WarUi)). Because `aspect = expand` changes the height per device, also sanity-check a taller and a shorter aspect — a screen that only fits at exactly 780 will overflow on shorter phones.

The reliable check is to read **geometry, not pixels**: drive to the screen with WarUi (`editor_manage game_eval` → `await WarUi.goto(...)`), then dump each control's `get_global_rect()` and assert none exceeds `(0,0)–(360,780)` or overlaps a sibling. A framebuffer screenshot can mislead — the game window doesn't redraw while unfocused, so it shows a stale frame — and because safe-area insets are 0 in the editor/desktop, **any overflow you see on the default surface is a width/height-budget bug, never a safe-area one**. (Worked example: the story map's world-selector row had a 260px-min label that, with its two arrows, summed to 368px and pushed the › button off a 360px screen — caught instantly by dumping rects, invisible to arithmetic.)

## References
_None._

## Child pages
_None._
