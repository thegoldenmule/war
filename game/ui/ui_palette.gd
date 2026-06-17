class_name WarPalette
extends RefCounted
## Shared visual palette + widget builders for the War client UI, derived from the
## reference prototype mockups (~/projects/thirdparty/War/docs): a casual, light card
## game — a neutral GRAY table, steel-BLUE card backs, off-WHITE card faces with
## BLACK ink and borders, an ORANGE accent for the primary action, and GREEN/RED
## win-loss outlines on revealed cards, with white modal banners.
##
## This is the GAME's runtime look. It is deliberately NOT the vendored
## editor_tool_kit's violet editor theme (that palette belongs to the in-editor
## tooling and stays separate). Single source of truth so re-skinning is one file.

# ── Table / backdrop ──────────────────────────────────────────────────────────
const BG := Color("9e9e9e")            # neutral gray field (the table)
const BANNER := Color("b5b5b5")        # ad/banner strip + secondary fills

# ── Cards ───────────────────────────────────────────────────────────────────--
const CARD_BACK := Color("5b7fb0")     # steel-blue face-down back
const CARD_BACK_BORDER := Color("3e5c86")
const CARD_FACE := Color("f4f4f4")     # off-white revealed face
const PANEL := Color("ececec")         # light UI panel / secondary button
const PANEL_HI := Color("ffffff")      # modal / raised panel

# ── Ink ─────────────────────────────────────────────────────────────────────--
const INK := Color("1a1a1a")           # near-black text + borders on light
const INK_DIM := Color("5a5a5a")       # secondary / disabled text
const ON_DARK := Color("ffffff")       # text on blue / orange / dim scrim

# ── Accent (orange) ───────────────────────────────────────────────────────────
const ACCENT := Color("ee7e2d")        # primary CTA / active menu
const ACCENT_HOVER := Color("f5963f")
const ACCENT_DEEP := Color("c8631d")

# ── Semantics ───────────────────────────────────────────────────────────────--
const WIN := Color("3fa34d")           # winning card outline / victory
const LOSE := Color("c0392b")          # losing card outline / defeat
const RED_SUIT := Color("c0392b")      # hearts / diamonds glyph tint
const SCRIM := Color(0.1, 0.1, 0.12, 0.78)  # dim behind modal overlays

# Shared card rendering helpers.
const SUIT_GLYPH := {"clubs": "♣", "diamonds": "♦", "hearts": "♥", "spades": "♠"}
const RANK_LABEL := {11: "J", 12: "Q", 13: "K", 14: "A"}


## A rounded, bordered StyleBoxFlat in the reference idiom (flat fill, black border).
static func box(bg: Color, border: Color, border_w: int = 2, radius: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## A styled button. `primary` = the orange CTA (white text); otherwise a light panel
## button with black ink + border — the reference's "FLIP CARD" / "USE SPECIAL" look.
static func button(text: String, primary: bool = false, font_size: int = 20) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	if primary:
		b.add_theme_stylebox_override("normal", box(ACCENT, ACCENT_DEEP))
		b.add_theme_stylebox_override("hover", box(ACCENT_HOVER, ACCENT_DEEP))
		b.add_theme_stylebox_override("pressed", box(ACCENT_DEEP, ACCENT_DEEP))
		b.add_theme_color_override("font_color", ON_DARK)
		b.add_theme_color_override("font_hover_color", ON_DARK)
	else:
		b.add_theme_stylebox_override("normal", box(PANEL, INK))
		b.add_theme_stylebox_override("hover", box(PANEL_HI, INK))
		b.add_theme_stylebox_override("pressed", box(BANNER, INK))
		b.add_theme_color_override("font_color", INK)
		b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_stylebox_override("disabled", box(BANNER, INK_DIM))
	b.add_theme_stylebox_override("focus", box(Color(0, 0, 0, 0), ACCENT))
	b.add_theme_color_override("font_disabled_color", INK_DIM)
	b.add_theme_font_size_override("font_size", font_size)
	return b
