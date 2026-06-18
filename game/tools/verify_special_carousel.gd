extends SceneTree
## VERIFY special_carousel — the "Using a Special Card" modal + its table wiring.
##
## Widget level (the reusable shell component in isolation):
##   - show_owned([...]) paints the first card (name from the SPECIAL_CARDS catalog) and
##     "1 / N"; the pager disables at each end; ◀/▶ move and repaint;
##   - USE SPECIAL emits special_selected with the CURRENT card's id and closes;
##   - the ✕ close emits `closed` without a selection.
##
## Table level (the wiring on the real view):
##   - _playable_specials() filters owned to the pre_flip window (the only special window
##     this pass) — post_flip cards are excluded;
##   - USE SPECIAL opens the carousel over those ids; with none playable it stays closed.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_special_carousel.gd

const Carousel := preload("res://ui/modals/special_card_carousel.gd")
const Director := preload("res://ui/round_director.gd")
const TABLE_SCENE := "res://ui/screens/table.tscn"


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY special_carousel: PASS")
	else:
		print("VERIFY special_carousel: FAIL %s" % reason)
	quit()


func _run() -> String:
	var widget_err := await _run_widget()
	if widget_err != "":
		return widget_err
	return await _run_table()


# ── Widget in isolation ────────────────────────────────────────────────────────
func _run_widget() -> String:
	var c := Carousel.new()
	get_root().add_child(c)
	await process_frame   # _ready: build

	var picked := [""]            # shared ref so the lambda can report the chosen id
	var closed := [false]
	c.special_selected.connect(func(id): picked[0] = id)
	c.closed.connect(func(): closed[0] = true)

	# Browse two specials: peek (pre_flip) then steal_tie (post_flip) — catalog names.
	c.show_owned(["peek", "steal_tie"])
	if not c.visible:
		c.queue_free(); return "carousel not visible after show_owned"
	if String(c._index_label.text) != "1 / 2":
		c.queue_free(); return "pager shows '%s', expected '1 / 2'" % c._index_label.text
	if String(c._name_label.text) != "SCRYING PEEK":
		c.queue_free(); return "first card name '%s', expected 'SCRYING PEEK'" % c._name_label.text
	if not c._prev_btn.disabled or c._next_btn.disabled:
		c.queue_free(); return "pager ends wrong at index 0 (prev should be disabled, next enabled)"

	c._on_next()
	if String(c._index_label.text) != "2 / 2" or String(c._name_label.text) != "TIE THIEF":
		c.queue_free(); return "after next: pager '%s' / name '%s', expected '2 / 2' / 'TIE THIEF'" % [c._index_label.text, c._name_label.text]
	if c._prev_btn.disabled or not c._next_btn.disabled:
		c.queue_free(); return "pager ends wrong at the last index (prev enabled, next disabled)"

	# USE SPECIAL emits the CURRENT id and closes.
	c._on_use()
	if picked[0] != "steal_tie":
		c.queue_free(); return "USE emitted '%s', expected the shown 'steal_tie'" % picked[0]
	if c.visible:
		c.queue_free(); return "carousel still visible after USE"

	# ✕ close emits `closed` with no selection.
	picked[0] = ""
	c.show_owned(["peek"])
	c._on_close()
	if not closed[0] or picked[0] != "":
		c.queue_free(); return "✕ close did not emit `closed` cleanly (closed=%s, picked='%s')" % [closed[0], picked[0]]
	c.queue_free()
	return ""


# ── Table wiring ───────────────────────────────────────────────────────────────
func _run_table() -> String:
	var B = Director.Beat
	var packed := load(TABLE_SCENE) as PackedScene
	if packed == null:
		return "could not load %s" % TABLE_SCENE
	var t := packed.instantiate()
	get_root().add_child(t)
	await process_frame
	await process_frame
	var guard := 0
	while int(t._beat_name) != int(B.DEAL_PROMPT) and guard < 5000:
		await process_frame
		if int(t._beat_name) == int(B.GAME_OVER):
			break
		if t._skip_catcher.visible:
			t._director.request_skip()
		guard += 1

	# _playable_specials filters owned to the pre_flip window (peek), dropping post_flip.
	t._state = {"specials": {"player": ["peek", "rank_boost", "steal_tie"], "cpu": []}}
	var playable: Array = t._playable_specials()
	if playable != ["peek"]:
		_retire(t); return "_playable_specials() = %s, expected ['peek'] (pre_flip only)" % str(playable)

	# USE SPECIAL opens the carousel over the playable card.
	t._on_special_pressed()
	if not t._special_modal.visible:
		_retire(t); return "USE SPECIAL did not open the carousel for a playable pre_flip special"
	if String(t._special_modal._name_label.text) != "SCRYING PEEK":
		_retire(t); return "carousel opened on '%s', expected 'SCRYING PEEK'" % t._special_modal._name_label.text
	t._special_modal.close()

	# With only post_flip specials owned, nothing is playable now → the carousel stays shut.
	t._state = {"specials": {"player": ["rank_boost", "steal_tie"], "cpu": []}}
	if not t._playable_specials().is_empty():
		_retire(t); return "_playable_specials() returned post_flip cards (should be empty at the flip window)"
	t._on_special_pressed()
	if t._special_modal.visible:
		_retire(t); return "carousel opened with no playable specials"

	_retire(t)
	return ""


func _retire(t) -> void:
	if t._director != null:
		t._director._arm(null)
	t.queue_free()
