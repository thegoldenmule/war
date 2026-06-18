class_name WarTopBar
extends PanelContainer
## WarTopBar — the persistent top banner (the white chrome band in the gameplay mockup):
## stacked currency readouts on the left, a centered title, and a shop + hamburger-menu
## button pair on the right. A reusable shell component (WarPalette only, reads GameState
## for the live wallet — never touches deterministic match state, the hard wall holds).
##
## Wiring contract: the host screen connects `shop_pressed` / `menu_pressed`. The shop and
## the second (star) currency are skeleton placeholders. # TODO(skeleton): wire the shop
## button to the real store screen; back the star currency with Snapser inventory.
##
## Glyphs are monochrome placeholders from the font's proven-rendering set (the suit /
## ✦ / ◈ glyphs the card visuals already use). # TODO(art): replace with icon textures.

signal shop_pressed
signal menu_pressed

const GEM_GLYPH := "◈"
const STAR_GLYPH := "★"
const SHOP_GLYPH := "$"
const MENU_GLYPH := "≡"
const ICON_SIZE := Vector2(60, 60)

var _gem_label: Label = null
var _star_label: Label = null
var _title_label: Label = null


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP  # the band is opaque chrome; eat taps on it
	add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.INK_DIM, 1, 0))

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 18)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	pad.add_child(row)

	# ── Currencies (left) — gem + star stacked ──────────────────────────────────
	var wallet := VBoxContainer.new()
	wallet.add_theme_constant_override("separation", 2)
	wallet.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gem_label = _currency_label()
	_star_label = _currency_label()
	wallet.add_child(_gem_label)
	wallet.add_child(_star_label)
	row.add_child(wallet)

	# ── Title (center, takes the slack so it stays centered) ────────────────────
	_title_label = Label.new()
	_title_label.text = "WAR"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", WarPalette.INK)
	_title_label.add_theme_font_size_override("font_size", 34)
	row.add_child(_title_label)

	# ── Shop + hamburger (right) ────────────────────────────────────────────────
	var shop := _icon_button(SHOP_GLYPH, false)
	shop.pressed.connect(func(): shop_pressed.emit())
	row.add_child(shop)
	var menu := _icon_button(MENU_GLYPH, true)
	menu.pressed.connect(func(): menu_pressed.emit())
	row.add_child(menu)

	# Bind to the live wallet and paint the initial values.
	GameState.gems_changed.connect(_on_gems_changed)
	GameState.stars_changed.connect(_on_stars_changed)
	_refresh_gems()
	_refresh_stars()


## Set the centered title (so other screens can reuse the bar with their own label).
func set_title(text: String) -> void:
	if _title_label != null:
		_title_label.text = text


# ── Builders ───────────────────────────────────────────────────────────────────

func _currency_label() -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", WarPalette.INK)
	l.add_theme_font_size_override("font_size", 22)
	return l


func _icon_button(glyph: String, primary: bool) -> Button:
	var b := WarPalette.button(glyph, primary, 28)
	b.custom_minimum_size = ICON_SIZE
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


# ── Wallet binding ───────────────────────────────────────────────────────────--

func _on_gems_changed(_amount: int) -> void:
	_refresh_gems()


func _on_stars_changed(_amount: int) -> void:
	_refresh_stars()


func _refresh_gems() -> void:
	if _gem_label != null:
		_gem_label.text = "%s %s" % [GEM_GLYPH, _abbrev(GameState.gems)]


func _refresh_stars() -> void:
	if _star_label != null:
		_star_label.text = "%s %s" % [STAR_GLYPH, _abbrev(GameState.stars)]


## Compact currency formatting (1.5 K / 2.3 M) as in the mockup; plain below 1000.
static func _abbrev(n: int) -> String:
	if n >= 1_000_000:
		return "%s M" % _trim(float(n) / 1_000_000.0)
	if n >= 1_000:
		return "%s K" % _trim(float(n) / 1_000.0)
	return str(n)


## One decimal, trailing ".0" dropped (1.0 -> "1", 1.5 -> "1.5").
static func _trim(v: float) -> String:
	var s := "%.1f" % v
	if s.ends_with(".0"):
		return s.substr(0, s.length() - 2)
	return s
