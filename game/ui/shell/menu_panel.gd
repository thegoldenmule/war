class_name WarMenuPanel
extends Control
## WarMenuPanel — the hamburger dropdown (the right-side overlay in the gameplay mockup):
## a grid of placeholder option icons over an EXIT GAME action. A full-rect overlay so a
## tap anywhere outside the panel dismisses it. Reusable shell component (WarPalette only,
## no match state — the hard wall holds).
##
## The host opens/closes it (typically from WarTopBar.menu_pressed) and connects
## `exit_pressed`. The six grid options are skeleton placeholders (disabled). # TODO:
## wire settings/social/etc. to their screens as they land. # TODO(art): icon textures.

signal exit_pressed

## Placeholder option glyphs (settings, favorites, rate, achievements, support, locale).
const OPTION_GLYPHS := ["⚙", "♥", "★", "◆", "▮", "◍"]
const PANEL_WIDTH := 240
const RIGHT_MARGIN := 18
const ICON_SIZE := Vector2(86, 72)

## Logical-px offset from the top edge the panel drops to — the host sets this to clear
## the top bar (safe inset + bar height) before opening.
var top_inset: float = 64.0

var _panel: PanelContainer = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # invisible when closed; clicks pass through
	visible = false

	# Tap-catcher: a full-rect flat button that closes the menu on any outside tap.
	var catcher := Button.new()
	catcher.flat = true
	catcher.focus_mode = Control.FOCUS_NONE
	catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.pressed.connect(close)
	add_child(catcher)

	# The dropdown panel, anchored to the top-right corner and growing left + down.
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.grow_vertical = Control.GROW_DIRECTION_END
	_panel.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.INK, 3))
	add_child(_panel)

	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_%s" % side, 12)
	_panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	pad.add_child(col)

	# 2-column grid of disabled placeholder options.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for glyph in OPTION_GLYPHS:
		var b := WarPalette.button(glyph, false, 28)
		b.custom_minimum_size = ICON_SIZE
		b.disabled = true  # TODO(skeleton): enable + route as each surface lands.
		grid.add_child(b)
	col.add_child(grid)

	# EXIT GAME — the one live action: leave the match back to the lobby.
	var exit := WarPalette.button("EXIT GAME", true, 20)
	exit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit.pressed.connect(func():
		close()
		exit_pressed.emit())
	col.add_child(exit)

	_reposition()


func open() -> void:
	_reposition()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP


func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func is_open() -> bool:
	return visible


func _reposition() -> void:
	if _panel == null:
		return
	_panel.offset_top = top_inset
	_panel.offset_bottom = top_inset
	_panel.offset_right = -RIGHT_MARGIN
	_panel.offset_left = -(RIGHT_MARGIN + PANEL_WIDTH)
