extends SceneTree
## VERIFY table_layout — the gameplay screen's LAYOUT GATE, checked as geometry, not
## pixels (per wiki-mirror/design/mobile-first-ui-layout-best-practices.md: drive the
## screen headless and assert each control's get_global_rect() fits the reference surface
## and no band overlaps another). Headless renders to the project's 720x1560 surface with
## the safe-area insets at 0, so any overflow here is a width/height-budget bug.
##
## Asserts, on a freshly-dealt table:
##   - every chrome/board/action control sits within (0,0)-(720,1560);
##   - the bands stack without overlap: top bar → ad banner → board → status → actions,
##     and the action row stays above the bottom edge;
##   - the central FLIP cards dominate — each big card is far larger than a count badge,
##     and the two big cards together claim a majority of the surface height;
##   - the player row (two badges + big card) fits the width without overflow.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_table_layout.gd

const Director := preload("res://ui/round_director.gd")
const TABLE_SCENE := "res://ui/screens/table.tscn"

const EPS := 1.0   # sub-pixel slack for container rounding


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY table_layout: PASS")
	else:
		print("VERIFY table_layout: FAIL %s" % reason)
	quit()


func _run() -> String:
	var B = Director.Beat
	var packed := load(TABLE_SCENE) as PackedScene
	if packed == null:
		return "could not load %s" % TABLE_SCENE
	# Pin the surface to the reference 720x1560 (the headless window otherwise defaults
	# to a square, hiding the WIDTH budget — the doc's most common overflow). aspect=expand
	# gives other devices more/less height, so 720 wide is the width to fit.
	get_root().size = Vector2i(720, 1560)
	var t := packed.instantiate()
	get_root().add_child(t)
	await process_frame   # _ready: build + start director
	await process_frame   # director deferred deal
	# Settle on the DEAL_PROMPT so the table is in a stable, fully-laid-out resting state.
	var guard := 0
	while int(t._beat_name) != int(B.DEAL_PROMPT) and guard < 5000:
		await process_frame
		if int(t._beat_name) == int(B.GAME_OVER):
			break
		if t._skip_catcher.visible:
			t._director.request_skip()
		guard += 1
	# A couple more frames so container layout fully resolves before we read rects.
	for _i in range(4):
		await process_frame

	var surface := Rect2(Vector2.ZERO, t.get_viewport().get_visible_rect().size)
	if surface.size.x <= 0.0 or surface.size.y <= 0.0:
		_retire(t)
		return "degenerate surface %s" % surface.size

	# ── Every control fits within the surface ──────────────────────────────────
	var named := {
		"top_bar": t._top_bar, "ad_banner": t._ad_banner,
		"cpu_card": t._cpu_card, "cpu_draw": t._cpu_draw,
		"player_card": t._player_card, "player_draw": t._player_draw,
		"player_win": t._player_win,
		"status": t._phase_label, "special_btn": t._special_button,
		"flip_btn": t._action_button,
	}
	for label in named:
		var r: Rect2 = (named[label] as Control).get_global_rect()
		if r.position.x < -EPS or r.position.y < -EPS \
				or r.end.x > surface.size.x + EPS or r.end.y > surface.size.y + EPS:
			_retire(t)
			return "%s rect %s exceeds the %s surface" % [label, r, surface.size]

	# ── Bands stack top→bottom without overlap ─────────────────────────────────
	var top_bar_r: Rect2 = t._top_bar.get_global_rect()
	var ad_r: Rect2 = t._ad_banner.get_global_rect()
	var cpu_card_r: Rect2 = t._cpu_card.get_global_rect()
	var player_card_r: Rect2 = t._player_card.get_global_rect()
	var status_r: Rect2 = t._phase_label.get_global_rect()
	var flip_r: Rect2 = t._action_button.get_global_rect()
	if top_bar_r.position.y > EPS:
		_retire(t)
		return "top bar does not start at the top edge (y=%.1f)" % top_bar_r.position.y
	if ad_r.position.y < top_bar_r.end.y - EPS:
		_retire(t)
		return "ad banner overlaps the top bar (ad.y=%.1f < bar.bottom=%.1f)" % [ad_r.position.y, top_bar_r.end.y]
	if cpu_card_r.position.y < ad_r.end.y - EPS:
		_retire(t)
		return "board overlaps the ad banner (cpu card y=%.1f < ad.bottom=%.1f)" % [cpu_card_r.position.y, ad_r.end.y]
	if player_card_r.position.y < cpu_card_r.end.y - EPS:
		_retire(t)
		return "the two big cards overlap vertically (player y=%.1f < cpu.bottom=%.1f)" % [player_card_r.position.y, cpu_card_r.end.y]
	if status_r.position.y < player_card_r.end.y - EPS:
		_retire(t)
		return "status line overlaps the board (status y=%.1f < player card bottom=%.1f)" % [status_r.position.y, player_card_r.end.y]
	if flip_r.position.y < status_r.end.y - EPS:
		_retire(t)
		return "action row overlaps the status line (flip y=%.1f < status.bottom=%.1f)" % [flip_r.position.y, status_r.end.y]
	if flip_r.end.y > surface.size.y + EPS:
		_retire(t)
		return "action row runs off the bottom edge (flip.bottom=%.1f > %.1f)" % [flip_r.end.y, surface.size.y]

	# ── The central flip cards dominate the real estate ────────────────────────
	var draw_r: Rect2 = t._player_draw.get_global_rect()
	if cpu_card_r.get_area() < draw_r.get_area() * 3.0:
		_retire(t)
		return "the CPU flip card (%s) is not clearly bigger than a count badge (%s)" % [cpu_card_r.size, draw_r.size]
	var big_height := cpu_card_r.size.y + player_card_r.size.y
	if big_height < surface.size.y * 0.45:
		_retire(t)
		return "the two flip cards claim only %.0f px of %.0f — not a majority of the height" % [big_height, surface.size.y]

	# ── Player row fits the width (badge | big card | badge) ───────────────────
	var win_r: Rect2 = t._player_win.get_global_rect()
	if draw_r.position.x < -EPS or win_r.end.x > surface.size.x + EPS:
		_retire(t)
		return "player row overflows the width (draw.x=%.1f, win.end.x=%.1f, surface=%.1f)" % [draw_r.position.x, win_r.end.x, surface.size.x]
	if not (draw_r.end.x <= player_card_r.position.x + EPS and player_card_r.end.x <= win_r.position.x + EPS):
		_retire(t)
		return "player row order is wrong: expected draw | card | win, got x-ranges %s %s %s" % [draw_r, player_card_r, win_r]

	_retire(t)
	return ""


func _retire(t) -> void:
	if t._director != null:
		t._director._arm(null)
	t.queue_free()
