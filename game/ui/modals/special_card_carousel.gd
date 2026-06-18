class_name WarSpecialCarousel
extends Control
## WarSpecialCarousel — the full-screen "Using a Special Card" modal (the spec mock):
## a scrim over a centered card panel that flips through the player's available
## specials one at a time (name + description from the catalog), shows "N / total",
## and confirms with USE SPECIAL or dismisses with the corner ✕ / an outside tap.
##
## Pure presentation: a reusable shell component (WarPalette + the SPECIAL_CARDS
## catalog METADATA only) holding NO match state — the host passes in the already-
## filtered list of owned, currently-playable special ids and connects
## `special_selected` to dispatch the play through the Round Director. The hard wall
## holds: this never touches WarMatch / the engine and never mutates game state.
##
## Built reusable so the (deferred) war-time special window can mount the very same
## modal: the host decides WHICH ids are playable now (e.g. pre_flip at the flip
## moment); the carousel only browses + confirms.

## The chosen special's id (host plays it). Emitted once, then the modal closes.
signal special_selected(id: String)
## The modal was dismissed without a choice (✕ / outside tap).
signal closed

## The SPECIAL_CARDS catalog is the contract vocabulary (id -> {name, when, desc});
## reading its display metadata is presentation, not state (the hard wall holds).
const C := preload("res://logic/constants.gd")

const PANEL_SIZE := Vector2(380, 560)
const CARD_SIZE := Vector2(300, 320)

## The ids being browsed (host-supplied, already filtered to what is playable now).
var _ids: Array = []
var _index: int = 0

var _name_label: Label = null
var _desc_label: Label = null
var _index_label: Label = null
var _prev_btn: Button = null
var _next_btn: Button = null
var _use_btn: Button = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # invisible when closed; clicks pass through
	visible = false
	_build()


func _build() -> void:
	# Scrim: a full-rect dim that also dismisses on an outside tap (the corner ✕ is the
	# explicit close; tapping the dim is the forgiving mobile gesture). A flat-styled
	# Button gives both the visible dim AND the catch-to-close in one node.
	var dim := Button.new()
	dim.focus_mode = Control.FOCUS_NONE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	for s in ["normal", "hover", "pressed", "focus"]:
		dim.add_theme_stylebox_override(s, _scrim_box())
	dim.pressed.connect(_on_close)
	add_child(dim)

	# Centered card panel. Anchor to the surface centre + grow symmetrically rather than
	# PRESET_CENTER (which bakes offsets from the pre-layout size and drifts off-centre).
	var panel := Panel.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = PANEL_SIZE
	panel.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.INK, 3))
	add_child(panel)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_%s" % side, 18)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	pad.add_child(col)

	# Header: title + corner ✕.
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "USE SPECIAL"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", WarPalette.INK)
	title.add_theme_font_size_override("font_size", 26)
	header.add_child(title)
	var close_btn := WarPalette.button("✕", false, 24)
	close_btn.custom_minimum_size = Vector2(56, 56)
	close_btn.pressed.connect(_on_close)
	header.add_child(close_btn)
	col.add_child(header)

	# The big card: name (bold) over a wrapping description.
	var card := Panel.new()
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_FACE, WarPalette.INK, 3))
	var card_pad := MarginContainer.new()
	card_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		card_pad.add_theme_constant_override("margin_%s" % side, 22)
	card.add_child(card_pad)
	var card_col := VBoxContainer.new()
	card_col.add_theme_constant_override("separation", 16)
	card_pad.add_child(card_col)
	_name_label = Label.new()
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.add_theme_color_override("font_color", WarPalette.INK)
	_name_label.add_theme_font_size_override("font_size", 30)
	card_col.add_child(_name_label)
	_desc_label = Label.new()
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_desc_label.add_theme_color_override("font_color", WarPalette.INK_DIM)
	_desc_label.add_theme_font_size_override("font_size", 20)
	card_col.add_child(_desc_label)
	col.add_child(card)

	# Pager: ◀  N / total  ▶.
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 12)
	_prev_btn = WarPalette.button("◀", false, 28)
	_prev_btn.custom_minimum_size = Vector2(64, 56)
	_prev_btn.pressed.connect(_on_prev)
	nav.add_child(_prev_btn)
	_index_label = Label.new()
	_index_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_index_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_index_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_index_label.add_theme_color_override("font_color", WarPalette.INK)
	_index_label.add_theme_font_size_override("font_size", 22)
	nav.add_child(_index_label)
	_next_btn = WarPalette.button("▶", false, 28)
	_next_btn.custom_minimum_size = Vector2(64, 56)
	_next_btn.pressed.connect(_on_next)
	nav.add_child(_next_btn)
	col.add_child(nav)

	# Confirm.
	_use_btn = WarPalette.button("USE SPECIAL", true, 26)
	_use_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_use_btn.custom_minimum_size = Vector2(0, 72)
	_use_btn.pressed.connect(_on_use)
	col.add_child(_use_btn)


## Open the modal browsing `ids` (host-supplied, already filtered to playable-now).
## An empty list is a no-op close (nothing to show).
func show_owned(ids: Array) -> void:
	_ids = ids.duplicate()
	_index = 0
	if _ids.is_empty():
		close()
		return
	_refresh()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP


func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func is_open() -> bool:
	return visible


## Repaint the current card + pager from `_index`. Pager ends disable rather than
## wrap so "N / total" reads honestly.
func _refresh() -> void:
	if _ids.is_empty():
		return
	_index = clampi(_index, 0, _ids.size() - 1)
	var id := String(_ids[_index])
	var meta: Dictionary = C.SPECIAL_CARDS.get(id, {})
	_name_label.text = String(meta.get("name", id)).to_upper()
	_desc_label.text = String(meta.get("desc", ""))
	_index_label.text = "%d / %d" % [_index + 1, _ids.size()]
	_prev_btn.disabled = _index <= 0
	_next_btn.disabled = _index >= _ids.size() - 1


func _on_prev() -> void:
	if _index > 0:
		_index -= 1
		_refresh()


func _on_next() -> void:
	if _index < _ids.size() - 1:
		_index += 1
		_refresh()


func _on_use() -> void:
	if _ids.is_empty():
		return
	var id := String(_ids[_index])
	close()
	special_selected.emit(id)


func _on_close() -> void:
	close()
	closed.emit()


## A flat, borderless scrim stylebox in the modal-dim colour (no hover/press shift).
func _scrim_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = WarPalette.SCRIM
	return sb
