class_name WarAdBanner
extends PanelContainer
## WarAdBanner — the PERSISTENT AD BANNER strip (placeholder). A fixed-height band that
## sits below the top bar; in the shipped game this hosts a mediation SDK banner view.
## Here it is a pure presentation placeholder so screens can budget the real estate it
## will occupy. # TODO(skeleton): mount the real ad surface (e.g. AdMob/LevelPlay).
##
## Reusable shell component (WarPalette only, no match state — the hard wall holds).

## Reserved height of the banner band, in logical px (a standard 320x50-style strip,
## scaled to War's 720-wide surface). Screens budget the board around this.
const MIN_HEIGHT := 96


func _ready() -> void:
	custom_minimum_size = Vector2(0, MIN_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP  # eat taps so the board behind never gets them
	add_theme_stylebox_override("panel", WarPalette.box(WarPalette.BANNER, WarPalette.INK_DIM, 1, 0))

	var label := Label.new()
	label.text = "PERSISTENT AD BANNER"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", WarPalette.INK)
	label.add_theme_font_size_override("font_size", 20)
	add_child(label)
