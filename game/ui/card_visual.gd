class_name WarCardVisual
extends RefCounted
##
## WarCardVisual — the single source of truth for how a card-shaped slot is built
## and painted (face, face-down back, empty). Shared by the table's static slots
## and the fly layer's ephemeral flying cards so a card in flight is pixel-identical
## to the slot it leaves and the slot it lands on. Pure presentation, WarPalette only.

## Card footprint — shrunk from 140x196 so three (draw | current | win) fit per row.
const SLOT_SIZE := Vector2(128, 180)
const FONT_SIZE := 36


## A bordered card slot Panel with a centered Label child (child 0). Painted by the
## paint_* helpers below.
static func make_slot() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = SLOT_SIZE
	var l := Label.new()
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_color", WarPalette.INK)
	p.add_child(l)
	p.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL, WarPalette.INK_DIM))
	return p


## Empty slot: a dim "—" placeholder.
static func paint_empty(slot: Panel, label: Label) -> void:
	label.text = "—"
	label.add_theme_color_override("font_color", WarPalette.INK_DIM)
	slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL, WarPalette.INK_DIM))


## Face-down back: the steel-blue card back. `glyph` defaults to the suit-spade-ish
## ✦; pass a count string to show a pile depth instead.
static func paint_back(slot: Panel, label: Label, glyph := "✦") -> void:
	label.text = glyph
	label.add_theme_color_override("font_color", WarPalette.ON_DARK)
	slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_BACK, WarPalette.CARD_BACK_BORDER))


## Face-up: rank + suit glyph on an off-white face (red suits tinted).
static func paint_face(slot: Panel, label: Label, card: Dictionary) -> void:
	var rank := int(card.get("rank", 0))
	var suit := String(card.get("suit", ""))
	var glyph := String(WarPalette.SUIT_GLYPH.get(suit, "?"))
	var rank_txt := String(WarPalette.RANK_LABEL.get(rank, str(rank)))
	label.text = "%s\n%s" % [rank_txt, glyph]
	var red := (suit == "hearts" or suit == "diamonds")
	label.add_theme_color_override("font_color", WarPalette.RED_SUIT if red else WarPalette.INK)
	slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_FACE, WarPalette.INK))


## A standalone face-down card visual sized to `size`, for the fly layer to tween.
static func make_flying_back(size: Vector2) -> Panel:
	var p := make_slot()
	p.custom_minimum_size = size
	p.size = size
	paint_back(p, p.get_child(0) as Label)
	return p
