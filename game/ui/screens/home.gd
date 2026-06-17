extends Control
## Home — the lobby screen (res://ui/screens/home.tscn). Mounted by UiRouter as the
## first screen after boot.
##
## Responsibilities:
##   • Big PLAY button → UiRouter.goto("table") (start a match).
##   • Currency display (gems), bound to GameState.gems_changed.
##   • Disabled placeholder tiles for Shop / Daily / Leaderboard (the meta-progression
##     and monetization surfaces). # TODO(skeleton): wire these to real screens.
##
## Visual style is the shared WarPalette (the reference look: neutral gray field,
## off-white panels, black ink, orange accent). The whole layout is built in _ready()
## so the .tscn stays minimal (root + script only).
##
## HARD WALL: pure presentation. Reads GameState (meta state) and drives UiRouter;
## never touches deterministic match state.

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
	# Neutral gray table backdrop spanning the whole screen.
	var backdrop := ColorRect.new()
	backdrop.color = WarPalette.BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 36)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 20)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(col)

	# ── Currency HUD (top) ───────────────────────────────────────────────────--
	var hud := HBoxContainer.new()
	hud.alignment = BoxContainer.ALIGNMENT_END
	_gems_label = Label.new()
	_gems_label.add_theme_color_override("font_color", WarPalette.INK)
	_gems_label.add_theme_font_size_override("font_size", 22)
	hud.add_child(_gems_label)
	col.add_child(hud)

	# ── Title ──────────────────────────────────────────────────────────────---
	var title := Label.new()
	title.text = "WAR"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", WarPalette.INK)
	title.add_theme_font_size_override("font_size", 80)
	col.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "a card game of flips & wars"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", WarPalette.INK_DIM)
	subtitle.add_theme_font_size_override("font_size", 18)
	col.add_child(subtitle)

	col.add_child(_spacer(24))

	# ── PLAY (primary action — the orange CTA) ─────────────────────────────────
	var play := WarPalette.button("PLAY", true, 28)
	play.custom_minimum_size = Vector2(0, 76)
	play.pressed.connect(_on_play_pressed)
	col.add_child(play)

	col.add_child(_spacer(8))

	# ── Meta tiles (light placeholders, disabled) ──────────────────────────────
	var tiles := HBoxContainer.new()
	tiles.alignment = BoxContainer.ALIGNMENT_CENTER
	tiles.add_theme_constant_override("separation", 12)
	for tile_name in ["SHOP", "DAILY", "LEADERS"]:
		var b := WarPalette.button(tile_name, false, 18)
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
