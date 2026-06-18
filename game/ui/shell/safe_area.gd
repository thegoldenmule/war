class_name WarSafeArea
extends RefCounted
## WarSafeArea — the single source of truth for converting the device safe area
## (notch / status bar / home indicator / gesture bar) into LOGICAL inset px for the
## current window. Implements rule 5 of the mobile-first layout gate
## (wiki/game-war/design/mobile-first-ui-layout-best-practices.md): a full-screen
## TAKEOVER (the match scene, a story map) owns the raw viewport edge-to-edge — the
## shell's safe-area handling is gone with the hidden bands — so it must inset its own
## header for the top notch and its own footer for the bottom home indicator itself.
##
## Why a helper: the doc notes Moveborne smeared this physical->logical math across
## three files that then drift. We keep it factored here from day one.
##
## `DisplayServer.get_display_safe_area()` reports PHYSICAL screen px; the GUI lays out
## in LOGICAL px (the project's stretched canvas — 720x1560 for War, stretch/scale=1).
## We scale by (logical viewport size / physical window size) per axis so the insets
## land in the same space the Controls use. On desktop / the editor the safe area is the
## whole window, so every inset resolves to 0 and layout is unaffected there.

const ZERO := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}


## Logical-px insets {top, bottom, left, right} for the window `node` lives in. Pass any
## node already inside the tree (it reaches the viewport + window through it).
##
## get_display_safe_area() and window_get_position()/_size() are all in PHYSICAL SCREEN
## px (a common origin), so the inset on each edge is how far the window rect sticks out
## past the safe rect — clamped to >= 0. On desktop the window sits wholly inside the safe
## area, so every edge clamps to 0 (the doc's "desktop resolves to 0"); on mobile the
## window fills the screen, so the status bar / home indicator fall out as the insets.
static func insets(node: Node) -> Dictionary:
	if node == null or not node.is_inside_tree():
		return ZERO.duplicate()
	var vp := node.get_viewport()
	if vp == null:
		return ZERO.duplicate()

	var safe := DisplayServer.get_display_safe_area()       # screen px
	var win_pos: Vector2i = DisplayServer.window_get_position()
	var win: Vector2i = DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		return ZERO.duplicate()

	# How far each window edge protrudes past the safe rect, in physical px (>= 0).
	var left_px := maxf(0.0, float(safe.position.x - win_pos.x))
	var top_px := maxf(0.0, float(safe.position.y - win_pos.y))
	var right_px := maxf(0.0, float((win_pos.x + win.x) - (safe.position.x + safe.size.x)))
	var bottom_px := maxf(0.0, float((win_pos.y + win.y) - (safe.position.y + safe.size.y)))

	# Physical -> logical (GUI) px: visible_rect honors stretch + aspect=expand per device.
	var logical: Vector2 = vp.get_visible_rect().size
	var sx := logical.x / float(win.x)
	var sy := logical.y / float(win.y)

	return {
		"left": left_px * sx,
		"top": top_px * sy,
		"right": right_px * sx,
		"bottom": bottom_px * sy,
	}
