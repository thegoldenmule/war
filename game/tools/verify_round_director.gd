extends SceneTree
## VERIFY round_director — the PURE pacing logic of WarRoundDirector.
##
## Asserts the presentation-tier sequencer's hash-irrelevant pure functions in
## isolation (no tree, no timers, no WarMatch):
##   - beat_for_phase: the engine phase -> resting beat mapping (+ unknown -> BOOT);
##   - war_scale / _dur: the tempo algebra (depth decay, clamp, reveal tail);
##   - transient_chain: the ordered transient holds implied by an apply's events,
##     INCLUDING the WAR_REVEALING-before-ROUND_RESULT/WAR_BANNER chaining (the fix
##     for the engine bundling `war_decide` with `award`/`tie` in one apply);
##   - _is_decision_beat: which beats wait for the player (never auto-skipped).
##
## These are exactly the bits that must stay correct for the loop to pace right
## while remaining determinism-neutral (they change WHEN an auto-action fires,
## never WHICH). Run headless:
##   godot --headless --path game --script res://tools/verify_round_director.gd

const Director := preload("res://ui/round_director.gd")


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY round_director: PASS")
	else:
		print("VERIFY round_director: FAIL %s" % reason)
	quit()


func _run() -> String:
	# Smoke check: a broken preload would make every Director.* call a non-fatal
	# runtime error (and risk a false PASS), so prove the script loaded first.
	if Director == null:
		return "round_director.gd failed to preload"
	var B = Director.Beat
	if Director.beat_for_phase("dealt") != B.DEAL_PROMPT:
		return "Director smoke check failed — round_director.gd did not compile cleanly"

	# --- beat_for_phase: the resting-beat mapping -----------------------------
	var phase_map := {
		"dealt": B.DEAL_PROMPT,
		"selected": B.FLIP_MOMENT,
		"flipped": B.REVEALING,
		"war": B.WAR_PROMPT,
		"player_win": B.GAME_OVER,
		"cpu_win": B.GAME_OVER,
		"": B.BOOT,
		"nonsense": B.BOOT,
	}
	for phase in phase_map:
		var got: int = Director.beat_for_phase(phase)
		if got != phase_map[phase]:
			return "beat_for_phase(%s) = %d, expected %d" % [phase, got, phase_map[phase]]

	# --- war_scale: depth decay clamped to WAR_MIN_SCALE -----------------------
	var expected_scale := [1.00, 0.60, 0.36, 0.30, 0.30]  # depths 1..5
	for i in range(expected_scale.size()):
		var depth := i + 1
		var got_scale: float = Director.war_scale(depth)
		if not is_equal_approx(snappedf(got_scale, 0.0001), expected_scale[i]):
			return "war_scale(%d) = %s, expected %s" % [depth, got_scale, expected_scale[i]]
	# Depth 0 / negative clamp to the depth-1 value (1.00) via max(0, depth-1).
	if not is_equal_approx(Director.war_scale(0), 1.00):
		return "war_scale(0) = %s, expected 1.00" % Director.war_scale(0)

	# --- _dur: tempo algebra (instance method; no tree needed) -----------------
	var d = Director.new()
	var reveal_tail: float = d._dur("flip") + d._dur("read")
	if not is_equal_approx(reveal_tail, 0.65):
		d.free()
		return "_dur('flip')+_dur('read') = %s, expected 0.65" % reveal_tail
	if not is_equal_approx(d._dur("result"), 0.90):
		d.free()
		return "_dur('result') = %s, expected 0.90" % d._dur("result")
	if not is_equal_approx(d._dur("stage"), 0.22):
		d.free()
		return "_dur('stage') = %s, expected 0.22" % d._dur("stage")
	# Depth scaling: war_banner at depth 2 == 1.10 * 0.60.
	if not is_equal_approx(d._dur("war_banner", 2), 1.10 * 0.60):
		d.free()
		return "_dur('war_banner', 2) = %s, expected %s" % [d._dur("war_banner", 2), 1.10 * 0.60]
	# _transient_dur routes each transient beat to the right key.
	if not is_equal_approx(d._transient_dur(B.ROUND_RESULT, 0), 0.90):
		d.free()
		return "_transient_dur(ROUND_RESULT) = %s, expected 0.90" % d._transient_dur(B.ROUND_RESULT, 0)
	if not is_equal_approx(d._transient_dur(B.WAR_REVEALING, 1), 0.45):
		d.free()
		return "_transient_dur(WAR_REVEALING, depth 1) = %s, expected 0.45" % d._transient_dur(B.WAR_REVEALING, 1)
	# DRAWING (the draw-in) runs for the 'stage' tempo (0.22).
	if not is_equal_approx(d._transient_dur(B.DRAWING, 0), 0.22):
		d.free()
		return "_transient_dur(DRAWING) = %s, expected 0.22" % d._transient_dur(B.DRAWING, 0)
	d.free()

	# --- transient_chain: the ordered transient holds per apply ----------------
	var chain_err := _check_chains(B)
	if chain_err != "":
		return chain_err

	# --- _is_decision_beat: which beats await the player. DEAL_PROMPT is the new draw
	# decision; FLIP_MOMENT is NOT static-decision (basic loop auto-flips). -----------
	for db in [B.DEAL_PROMPT, B.WAR_PROMPT, B.GAME_OVER]:
		if not Director._is_decision_beat(db):
			return "_is_decision_beat(%d) should be true" % db
	for ab in [B.DRAWING, B.FLIP_MOMENT, B.REVEALING, B.ROUND_RESULT, B.WAR_BANNER, B.WAR_REVEALING, B.BOOT]:
		if Director._is_decision_beat(ab):
			return "_is_decision_beat(%d) should be false" % ab

	# --- _is_gated_beat: only the WAR reveal awaits a tap (no auto-timer) -------------
	if not Director._is_gated_beat(B.WAR_REVEALING):
		return "_is_gated_beat(WAR_REVEALING) should be true (the reveal must await CONTINUE)"
	for ng in [B.DEAL_PROMPT, B.DRAWING, B.FLIP_MOMENT, B.REVEALING, B.ROUND_RESULT, B.WAR_BANNER, B.WAR_PROMPT, B.GAME_OVER, B.BOOT]:
		if Director._is_gated_beat(ng):
			return "_is_gated_beat(%d) should be false" % ng

	return ""


## Each case: (events, resting_beat) -> expected ordered transient chain.
func _check_chains(B) -> String:
	var cases := [
		# new_game settles at DEAL_PROMPT with no transient.
		[[_ev("new_game")], B.DEAL_PROMPT, []],
		# start_round (round_staged) -> the DRAWING draw-in transient, then settle FLIP_MOMENT.
		[[_ev("round_staged")], B.FLIP_MOMENT, [B.DRAWING]],
		[[_ev("flip")], B.REVEALING, []],
		# A decisive resolve returns to 'dealt' (DEAL_PROMPT) -> ROUND_RESULT.
		[[_ev("flip"), _ev("award")], B.DEAL_PROMPT, [B.ROUND_RESULT]],
		[[_ev("steal_tie_fired"), _ev("award")], B.DEAL_PROMPT, [B.ROUND_RESULT]],
		# A flip tie -> straight to the WAR banner (no war_decide yet).
		[[_ev("flip"), _ev("tie")], B.WAR_PROMPT, [B.WAR_BANNER]],
		# ack_war that WINS the round: stake reveal THEN the result (the chaining fix).
		[[_ev("war_decide"), _ev("award")], B.DEAL_PROMPT, [B.WAR_REVEALING, B.ROUND_RESULT]],
		# ack_war that RE-TIES: stake reveal THEN the next war banner (the chaining fix).
		[[_ev("war_decide"), _ev("tie")], B.WAR_PROMPT, [B.WAR_REVEALING, B.WAR_BANNER]],
		# A terminal apply: transient_chain yields nothing (the resting beat is GAME_OVER,
		# which _on_state short-circuits before any transient).
		[[_ev("war_forfeit"), _ev("award"), _ev("game_over")], B.GAME_OVER, []],
		[[_ev("award"), _ev("game_over")], B.GAME_OVER, []],
	]
	for case in cases:
		var events: Array = case[0]
		var resting: int = case[1]
		var expected: Array = case[2]
		var got: Array = Director.transient_chain(events, resting)
		if got != expected:
			return "transient_chain(%s, %d) = %s, expected %s" % [_types(events), resting, got, expected]
	return ""


func _ev(t: String) -> Dictionary:
	return {"type": t}


func _types(events: Array) -> Array:
	var out: Array = []
	for e in events:
		out.append(String(e.get("type", "")))
	return out
