extends SceneTree
## VERIFY table_wiring — the real table.tscn view wired to the Round Director.
##
## Guards the view-layer regression the Core Play Loop fixed: table.gd used to call
## a non-existent WarMatch.start_new_game (silent no-deal) and mapped phase 'dealt'
## -> flip (engine-illegal). Now it owns a WarRoundDirector, renders from view_state,
## and drives buttons/overlays SOLELY from beat(locked). This verifier instantiates
## the actual scene and asserts:
##   - a fresh deal renders a non-empty 'dealt' state (52 cards across the six pile/card
##     slots) and settles at the DEAL_PROMPT, so the silent no-deal cannot recur;
##   - at the DEAL_PROMPT the current-card slots are EMPTY, the primary button reads
##     FLIP CARD + is enabled, USE SPECIAL is disabled, and the skip-catcher is hidden;
##   - pressing FLIP CARD draws on the click (start_round -> 'selected') and the locked
##     DRAWING beat shows the skip-catcher + disables the button;
##   - injecting a terminal state shows the VICTORY result overlay (and conserves 52).
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_table_wiring.gd

const Director := preload("res://ui/round_director.gd")
const PileModel := preload("res://ui/pile_model.gd")
const TABLE_SCENE := "res://ui/screens/table.tscn"


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY table_wiring: PASS")
	else:
		print("VERIFY table_wiring: FAIL %s" % reason)
	quit()


func _run() -> String:
	var B = Director.Beat
	var packed := load(TABLE_SCENE) as PackedScene
	if packed == null:
		return "could not load %s" % TABLE_SCENE
	var t := packed.instantiate()
	get_root().add_child(t)
	await process_frame   # table._ready: build UI + start the Director
	await process_frame   # Director._ready (deferred): deal

	if t._director == null or t._director._match == null:
		_retire(t)
		return "table did not create a Director with a live WarMatch"

	# Reach the DEAL_PROMPT — the draw decision, reached right after the deal.
	var guard := 0
	while int(t._beat_name) != int(B.DEAL_PROMPT) and guard < 5000:
		await process_frame
		if int(t._beat_name) == int(B.GAME_OVER):
			_retire(t)
			return "reached GAME_OVER before any DEAL_PROMPT (deal never happened?)"
		if t._skip_catcher.visible:
			t._director.request_skip()
		guard += 1
	if int(t._beat_name) != int(B.DEAL_PROMPT):
		_retire(t)
		return "never reached the DEAL_PROMPT (start_new_game / deal regression?)"

	# Three piles per player exist and are distinct Panels; the fly layer sits ABOVE
	# the table but BELOW the overlays + skip-catcher.
	for s in [t._cpu_draw, t._cpu_card, t._cpu_win, t._player_draw, t._player_card, t._player_win]:
		if not (s is Panel):
			_retire(t)
			return "a pile/card slot is missing or not a Panel"
	if t._fly == null or not (t._fly is Control) or t._fly.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_retire(t)
		return "fly layer missing or not a mouse-transparent Control"
	if not (t._fly.get_index() < t._war_overlay.get_index() \
			and t._war_overlay.get_index() < t._result_overlay.get_index() \
			and t._result_overlay.get_index() < t._skip_catcher.get_index()):
		_retire(t)
		return "z-order wrong: fly layer must sit below overlays, which sit below the skip-catcher"

	# A non-empty deal rendered: 52 cards on the table, and the draw piles show counts.
	var st := t._director._match.get_state() as Dictionary
	var total := (st.get("player_deck", []) as Array).size() + (st.get("cpu_deck", []) as Array).size() \
		+ (st.get("player_pot", []) as Array).size() + (st.get("cpu_pot", []) as Array).size()
	if total != 52:
		_retire(t)
		return "table is not showing a full 52-card deal (got %d)" % total
	if not String(t._player_draw_cap.text).begins_with("DRAW"):
		_retire(t)
		return "player draw-pile caption did not render ('%s')" % t._player_draw_cap.text
	# At the DEAL_PROMPT the current-card slots are EMPTY — nothing is drawn until the tap.
	if not (st.get("player_pot", []) as Array).is_empty() or not (st.get("cpu_pot", []) as Array).is_empty():
		_retire(t)
		return "a card is already staged at DEAL_PROMPT (the draw should happen on the tap)"

	# Button gating at the draw decision.
	if t._action_button.disabled:
		_retire(t)
		return "primary button is disabled at the DEAL_PROMPT"
	if String(t._action_button.text) != "FLIP CARD":
		_retire(t)
		return "primary button label is '%s', expected 'FLIP CARD'" % t._action_button.text
	if not t._special_button.disabled:
		_retire(t)
		return "USE SPECIAL is enabled with no owned specials (basic loop should disable it)"
	if t._skip_catcher.visible:
		_retire(t)
		return "skip-catcher is visible at the DEAL_PROMPT (unlocked beat should not catch taps)"

	# Pressing FLIP CARD draws a card on the click: request_deal_and_flip -> start_round
	# -> phase 'selected', and the DRAWING (draw-in) transient is now showing (locked).
	var phase_before := String(t._director._match.get_state().get("phase", ""))
	t._on_action_pressed()
	var phase_after := String(t._director._match.get_state().get("phase", ""))
	if phase_before != "dealt":
		_retire(t)
		return "engine phase at DEAL_PROMPT was '%s', expected 'dealt'" % phase_before
	if phase_after != "selected":
		_retire(t)
		return "pressing FLIP at DEAL_PROMPT did not draw (phase '%s' -> '%s', expected -> selected)" % [phase_before, phase_after]
	if int(t._beat_name) != int(B.DRAWING):
		_retire(t)
		return "after the draw tap the beat is %d, expected DRAWING (the draw-in)" % t._beat_name
	# The DRAWING beat is locked: the skip-catcher catches taps and the button is disabled.
	if not t._skip_catcher.visible:
		_retire(t)
		return "skip-catcher is hidden on the locked DRAWING beat"
	if not t._action_button.disabled:
		_retire(t)
		return "primary button is enabled on the locked DRAWING beat"

	# Win->draw recycle through the real _on_beat: a SATURATING award flips the win pile
	# to the draw pile (won -> 0, the caption reads DRAW <full> / WIN 0) and queues a
	# recycle sweep. Seed the cosmetic accumulator one short of the deck, then award one.
	t._fly.clear()
	var rec_pdeck := (t._director._match.get_state().get("player_deck", []) as Array).size()
	if rec_pdeck < 1:
		_retire(t)
		return "no player draw deck to exercise the recycle"
	t._won = {"player": maxi(0, rec_pdeck - 1), "cpu": 0}
	t._on_beat(B.ROUND_RESULT, [{"type": "award", "winner": "player", "cards": 1}], false)
	if int(t._won["player"]) != 0:
		_retire(t)
		return "a saturating award did not recycle the win pile (won.player=%d, expected 0)" % t._won["player"]
	if String(t._player_win_cap.text) != "WIN 0":
		_retire(t)
		return "after a recycle the win caption is '%s', expected 'WIN 0' (win pile flipped to draw)" % t._player_win_cap.text
	if String(t._player_draw_cap.text) != "DRAW %d" % rec_pdeck:
		_retire(t)
		return "after a recycle the draw caption is '%s', expected 'DRAW %d'" % [t._player_draw_cap.text, rec_pdeck]
	if t._fly.get_child_count() == 0:
		_retire(t)
		return "the recycle did not queue a win->draw sweep flight"

	# Fly-layer: TWO simultaneous flights (the draw-in / win-sweep case) each get their
	# OWN tween — reusing one tween fails with "Can't append to a Tween that has started".
	# Clear first (prior beats queued flights), then use explicit rects so flights are
	# created regardless of headless layout timing.
	t._fly.clear()
	t._fly.fly_back(Rect2(Vector2(10, 10), Vector2(128, 180)), Rect2(Vector2(300, 300), Vector2(128, 180)), 0.5)
	t._fly.fly_back(Rect2(Vector2(20, 20), Vector2(128, 180)), Rect2(Vector2(400, 400), Vector2(128, 180)), 0.5, 0.05)
	if t._fly.get_child_count() != 2:
		_retire(t)
		return "two fly_back calls did not create two flight nodes (got %d)" % t._fly.get_child_count()
	if t._fly._tweens.size() != 2:
		_retire(t)
		return "two flights did not get two independent tweens (got %d) — append-to-started-tween regression" % t._fly._tweens.size()
	# A fresh authoritative render tears down every flight + tween (snap-safety).
	t._on_view_state(t._director._match.get_state())
	if t._fly.get_child_count() != 0 or t._fly._tweens.size() != 0:
		_retire(t)
		return "fly layer was not cleared on a fresh view_state (stranded flight/tween)"

	# Terminal overlay: inject a terminal authoritative state (a real match for this seed
	# can run thousands of rounds — far too slow to drive through the full UI scene). The
	# overlay is a pure function of the GAME_OVER beat + terminal state, so a reconcile to
	# a player_win state exercises exactly the rendering path under test.
	t._director._match._reconcile_from_json(JSON.stringify(_player_win_state()))
	await process_frame
	if int(t._beat_name) != int(B.GAME_OVER):
		_retire(t)
		return "injecting a terminal state did not reach the GAME_OVER beat (got %d)" % t._beat_name
	if not t._result_overlay.visible:
		_retire(t)
		return "result overlay is not visible at GAME_OVER"
	if t._skip_catcher.visible:
		_retire(t)
		return "skip-catcher is visible at GAME_OVER (would block PLAY AGAIN / CONTINUE)"
	if String(t._result_label.text) != "VICTORY":
		_retire(t)
		return "result overlay text is '%s', expected 'VICTORY' for player_win" % t._result_label.text

	# Conservation at game over: the winner holds all 52 (draw+win), the loser holds 0.
	var fp := (t._director._match.get_state().get("player_deck", []) as Array).size()
	var fc := (t._director._match.get_state().get("cpu_deck", []) as Array).size()
	var piles := PileModel.counts(t._won, fp, fc)
	if int(piles["cpu"]["draw"]) + int(piles["cpu"]["win"]) != 0:
		_retire(t)
		return "loser (cpu) pile is not empty at game over"
	if int(piles["player"]["draw"]) + int(piles["player"]["win"]) != 52:
		_retire(t)
		return "winner (player) pile does not hold all 52 at game over"

	_retire(t)
	return ""


## A terminal player_win state (player holds all 52, CPU drained) for the overlay test.
func _player_win_state() -> Dictionary:
	var deck: Array = []
	for suit in ["clubs", "diamonds", "hearts", "spades"]:
		for r in range(2, 15):
			deck.append({"rank": r, "suit": suit, "face_up": false})
	return {
		"version": 1, "seed": "verify-table-term", "phase": "player_win",
		"player_deck": deck, "cpu_deck": [],
		"player_pot": [], "cpu_pot": [],
		"rng": {"seq": 0}, "specials": {"player": [], "cpu": []},
		"pending_special": null, "war_depth": 0,
	}


func _retire(t) -> void:
	if t._director != null:
		t._director._arm(null)
	t.queue_free()
