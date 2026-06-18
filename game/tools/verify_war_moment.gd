extends SceneTree
## VERIFY war_moment — the Act-of-War SCREENS on the real table.tscn view (presentation
## only; the engine's war rules are already parity-locked and untouched).
##
## Asserts the two mock states drive off the existing WAR_* beats with no Director change:
##   - injecting a shallow 'war' state settles at WAR_PROMPT showing the "IT'S WAR!" modal:
##     the war overlay + prompt panel are visible, the reveal panel is hidden, DECLARE WAR
##     is live, the bottom action row is dimmed, and the DEFERRED BET row is built-but-hidden;
##   - the WAR_BANNER lead-in shows the same prompt with DECLARE WAR disabled (locked);
##   - the WAR_REVEALING beat shows the "I DECLARE WAR!" reveal: prompt hidden, reveal
##     visible, each side laid out as WAR_STAKE face-down backs + 1 face-up decider painted
##     from the war_decide event's ranks (winner green / loser red), skip-catcher up so a
##     tap-anywhere continues;
##   - pressing DECLARE WAR at a shallow WAR_PROMPT submits ack_war and advances the engine.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_war_moment.gd

const Director := preload("res://ui/round_director.gd")
const TABLE_SCENE := "res://ui/screens/table.tscn"


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY war_moment: PASS")
	else:
		print("VERIFY war_moment: FAIL %s" % reason)
	quit()


func _run() -> String:
	var B = Director.Beat
	var packed := load(TABLE_SCENE) as PackedScene
	if packed == null:
		return "could not load %s" % TABLE_SCENE
	var t := packed.instantiate()
	get_root().add_child(t)
	await process_frame   # _ready: build + start director
	await process_frame   # director deferred deal

	# Settle on a stable resting beat before injecting (mirrors the table_wiring setup).
	var guard := 0
	while int(t._beat_name) != int(B.DEAL_PROMPT) and guard < 5000:
		await process_frame
		if int(t._beat_name) == int(B.GAME_OVER):
			break
		if t._skip_catcher.visible:
			t._director.request_skip()
		guard += 1

	# ── 1. A shallow war settles at WAR_PROMPT → the "IT'S WAR!" modal ──────────
	t._director._match._reconcile_from_json(JSON.stringify(_war_state()))
	await process_frame
	if int(t._beat_name) != int(B.WAR_PROMPT):
		_retire(t)
		return "injected war state did not settle at WAR_PROMPT (got beat %d)" % t._beat_name
	if not t._war_overlay.visible:
		_retire(t)
		return "war overlay is not visible at WAR_PROMPT"
	if not t._war_prompt_panel.visible:
		_retire(t)
		return "IT'S WAR prompt panel is not visible at WAR_PROMPT"
	if t._war_reveal_panel.visible:
		_retire(t)
		return "reveal panel is visible at WAR_PROMPT (should be the prompt only)"
	if t._war_declare_button.disabled:
		_retire(t)
		return "DECLARE WAR is disabled at a shallow (awaited) WAR_PROMPT"
	if not t._action_button.disabled:
		_retire(t)
		return "bottom action row is live at WAR_PROMPT (the modal owns DECLARE WAR; it should dim)"
	# Deferred BET row is built but hidden + disabled (the clean economy hook).
	if t._war_bet_button.visible or not t._war_bet_button.disabled:
		_retire(t)
		return "deferred BET row should be built-but-hidden and disabled this pass"

	# ── 2. WAR_BANNER lead-in: same prompt, DECLARE WAR disabled (locked) ───────
	t._on_beat(B.WAR_BANNER, [], true)
	if not (t._war_overlay.visible and t._war_prompt_panel.visible):
		_retire(t)
		return "WAR_BANNER lead-in did not show the IT'S WAR prompt"
	if not t._war_declare_button.disabled:
		_retire(t)
		return "DECLARE WAR is enabled during the locked WAR_BANNER lead-in"

	# ── 3. WAR_REVEALING: the "I DECLARE WAR!" stake reveal from war_decide ─────
	# K(13) beats 7 → YOU win this decider (player=13), CPU loses (cpu=7).
	t._on_beat(B.WAR_REVEALING, [{"type": "war_decide", "depth": 2, "player": 13, "cpu": 7}], true)
	if t._war_prompt_panel.visible or not t._war_reveal_panel.visible:
		_retire(t)
		return "WAR_REVEALING did not swap to the reveal panel"
	if not t._skip_catcher.visible:
		_retire(t)
		return "skip-catcher hidden during the locked reveal (tap-anywhere-to-continue broken)"
	var need := int(WarConstants.WAR_STAKE) + 1   # 3 backs + 1 decider
	if t._war_reveal_cpu_row.get_child_count() != need or t._war_reveal_you_row.get_child_count() != need:
		_retire(t)
		return "reveal rows not laid out as %d cards (cpu=%d, you=%d)" % \
			[need, t._war_reveal_cpu_row.get_child_count(), t._war_reveal_you_row.get_child_count()]
	# The decider is the LAST child of each row; YOU's should read "K" (rank 13).
	var you_dec: Panel = t._war_reveal_you_row.get_child(need - 1)
	if String((you_dec.get_child(0) as Label).text) != "K":
		_retire(t)
		return "YOU decider label is '%s', expected 'K' (rank 13)" % (you_dec.get_child(0) as Label).text

	# ── 4. DECLARE WAR resolves the engine AND the reveal HOLDS (gated; no auto-advance) ──
	t._director._match._reconcile_from_json(JSON.stringify(_war_state()))
	await process_frame
	if int(t._beat_name) != int(B.WAR_PROMPT):
		_retire(t)
		return "re-injected war state did not return to WAR_PROMPT (got %d)" % t._beat_name
	t._on_declare_war_pressed()
	# YOU's decider (14) beats CPU's (5) → the engine resolves the war to 'dealt'...
	if String(t._director._match.get_state().get("phase", "")) != "dealt":
		_retire(t)
		return "DECLARE WAR did not resolve the war in the engine (expected phase 'dealt')"
	# ...but the Director HOLDS the reveal: it sits at WAR_REVEALING with NO armed timer, so
	# the staked cards stay up until the player taps CONTINUE (the no-auto-advance fix).
	if int(t._beat_name) != int(B.WAR_REVEALING):
		_retire(t)
		return "the reveal did not hold at WAR_REVEALING after DECLARE WAR (got beat %d)" % t._beat_name
	if t._director._pending != null:
		_retire(t)
		return "the WAR reveal armed an auto-timer (it must AWAIT the player's CONTINUE)"
	if not t._war_reveal_panel.visible:
		_retire(t)
		return "reveal panel not visible while the reveal is held"
	# CONTINUE advances past the held reveal.
	t._on_war_continue_pressed()
	if int(t._beat_name) == int(B.WAR_REVEALING):
		_retire(t)
		return "CONTINUE did not advance past the held WAR reveal"

	_retire(t)
	return ""


## A shallow (depth 1) war state: each side holds the tie card in its pot and a deck whose
## 4th card (the decider) is decisive — YOU's A(14) beats CPU's 5, so a single ack_war ends
## the war in YOU's favour and returns to 'dealt' (neither deck empties).
func _war_state() -> Dictionary:
	return {
		"version": 1, "seed": "verify-war", "phase": "war",
		"player_deck": _cards([10, 9, 8, 14, 7, 6]),   # decider = index 3 = 14 (A)
		"cpu_deck": _cards([2, 3, 4, 5, 6, 7]),        # decider = index 3 = 5
		"player_pot": [{"rank": 7, "suit": "clubs", "face_up": true}],
		"cpu_pot": [{"rank": 7, "suit": "hearts", "face_up": true}],
		"rng": {"seq": 0}, "specials": {"player": [], "cpu": []},
		"pending_special": null, "war_depth": 1,
	}


func _cards(ranks: Array) -> Array:
	var out: Array = []
	for r in ranks:
		out.append({"rank": int(r), "suit": "spades", "face_up": false})
	return out


func _retire(t) -> void:
	if t._director != null:
		t._director._arm(null)
	t.queue_free()
