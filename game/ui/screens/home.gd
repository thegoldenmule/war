extends Control
## Home — the lobby screen (res://ui/screens/home.tscn). Mounted by UiRouter as
## the first screen after boot.
##
## Responsibilities:
##   • Big PLAY button → UiRouter.goto("table") (start a match).
##   • Currency display (gems), bound to GameState.gems_changed.
##   • Placeholder tiles for Shop / Daily / Leaderboard (the meta-progression and
##     monetization surfaces). # TODO(skeleton): wire these to real screens.
##
## Occult-arcade styling: violet accent (#b400ff, hover #d24bff) on near-black
## (#13111c), green (#44ff88) for selection emphasis, white for peak emphasis —
## mirroring the editor_tool_kit palette. The whole layout is built in _ready()
## so the .tscn stays at the minimal valid format; only the root + script live in
## the scene file.
##
## HARD WALL: pure presentation. Reads GameState (meta state) and drives UiRouter;
## never touches deterministic match state.

# ── Palette (mirrors addons/editor_tool_kit/tool_palette.gd) ──────────────────-
const VIOLET := Color("b400ff")
const VIOLET_HOVER := Color("d24bff")
const VIOLET_DEEP := Color("43005d")
const GREEN_SEL := Color("44ff88")
const BG := Color("13111c")
const PANEL_BG := Color(0.078, 0.078, 0.110)
const PANEL_HI := Color(0.137, 0.125, 0.227)
const TEXT := Color(0.925, 0.925, 0.957)
const TEXT_DIM := Color(0.55, 0.5, 0.6)
const EMPHASIS := Color(1, 1, 1)

## Label that shows the current gem total; refreshed on gems_changed.
var _gems_label: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	# Keep the wallet HUD live for the lifetime of this screen.
	GameState.gems_changed.connect(_on_gems_changed)
	_refresh_gems()


# ── Layout ──────────────────────────────────────────────────────────────────--

func _build_ui() -> void:
	# Near-black backdrop spanning the whole screen.
	var backdrop := ColorRect.new()
	backdrop.color = BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	# Centered vertical column with comfortable margins.
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 36)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 20)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(col)

	# ── Currency HUD (top) ───────────────────────────────────────────────────
	var hud := HBoxContainer.new()
	hud.alignment = BoxContainer.ALIGNMENT_END
	_gems_label = Label.new()
	_gems_label.add_theme_color_override("font_color", GREEN_SEL)
	_gems_label.add_theme_font_size_override("font_size", 22)
	hud.add_child(_gems_label)
	col.add_child(hud)

	# ── Title ──────────────────────────────────────────────────────────────---
	var title := Label.new()
	title.text = "WAR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", EMPHASIS)
	title.add_theme_font_size_override("font_size", 72)
	col.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "an occult game of flips"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", TEXT_DIM)
	subtitle.add_theme_font_size_override("font_size", 18)
	col.add_child(subtitle)

	col.add_child(_spacer(24))

	# ── PLAY (primary action) ─────────────────────────────────────────────────
	var play := _make_button("PLAY", true)
	play.custom_minimum_size = Vector2(0, 76)
	play.pressed.connect(_on_play_pressed)
	col.add_child(play)

	col.add_child(_spacer(8))

	# ── Meta tiles (placeholders) ──────────────────────────────────────────────
	var tiles := HBoxContainer.new()
	tiles.alignment = BoxContainer.ALIGNMENT_CENTER
	tiles.add_theme_constant_override("separation", 12)
	for tile_name in ["SHOP", "DAILY", "LEADERS"]:
		var b := _make_button(tile_name, false)
		b.custom_minimum_size = Vector2(150, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = true # TODO(skeleton): enable when these screens exist.
		b.pressed.connect(_on_placeholder_pressed.bind(tile_name))
		tiles.add_child(b)
	col.add_child(tiles)


## A fixed-height invisible spacer used between sections.
func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s


## Build an occult-arcade styled button. `primary` gives it the bold violet fill
## (hover → brighter violet); secondary tiles get a dimmer panel fill.
func _make_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var fill := VIOLET if primary else PANEL_BG
	var hover := VIOLET_HOVER if primary else PANEL_HI
	b.add_theme_stylebox_override("normal", _box(fill, VIOLET))
	b.add_theme_stylebox_override("hover", _box(hover, VIOLET_HOVER))
	b.add_theme_stylebox_override("pressed", _box(VIOLET_DEEP, VIOLET_HOVER))
	b.add_theme_stylebox_override("disabled", _box(PANEL_BG.darkened(0.3), VIOLET_DEEP))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), VIOLET_HOVER))
	b.add_theme_color_override("font_color", EMPHASIS if primary else TEXT)
	b.add_theme_color_override("font_hover_color", EMPHASIS)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_font_size_override("font_size", 24 if primary else 18)
	return b


## Rounded, bordered StyleBoxFlat in the occult-arcade idiom.
func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


# ── Signals ─────────────────────────────────────────────────────────────────--

func _on_play_pressed() -> void:
	# Top-level jump to the table; the table screen starts a fresh match.
	UiRouter.goto("table")


func _on_placeholder_pressed(which: String) -> void:
	# TODO(skeleton): push("shop"/"daily"/"leaderboard") once those screens land.
	print("[Home] '%s' tapped (placeholder)" % which)


func _on_gems_changed(_amount: int) -> void:
	_refresh_gems()


func _refresh_gems() -> void:
	if _gems_label != null:
		_gems_label.text = "◈ %d" % GameState.gems
