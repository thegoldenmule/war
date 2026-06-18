extends SceneTree
## VERIFY pile_model — the COSMETIC 3-pile (draw / current / win) count model.
##
## WarPileModel is pure and hash-irrelevant, but it must (a) CONSERVE the 52-card
## deck on screen, (b) never show a negative or over-deck count (clamp/recycle), and
## (c) accrue a win pile correctly from award events without double-counting. This
## asserts all three in isolation and across a real driven match.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_pile_model.gd

const PileModel := preload("res://ui/pile_model.gd")


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY pile_model: PASS")
	else:
		print("VERIFY pile_model: FAIL %s" % reason)
	quit()


func _run() -> String:
	# --- empty -----------------------------------------------------------------
	var e := PileModel.empty()
	if int(e["player"]) != 0 or int(e["cpu"]) != 0:
		return "empty() is not {player:0, cpu:0}"

	# --- counts conserve + clamp over a grid ----------------------------------
	for pdeck in [0, 1, 4, 26, 52]:
		for cdeck in [0, 1, 4, 26, 52]:
			for wp in [0, 2, 30, 999, -5]:
				for wc in [0, 1, 60]:
					var c := PileModel.counts({"player": wp, "cpu": wc}, pdeck, cdeck)
					var dp: int = c["player"]["draw"]
					var vp: int = c["player"]["win"]
					var dc: int = c["cpu"]["draw"]
					var vc: int = c["cpu"]["win"]
					if dp < 0 or vp < 0 or dc < 0 or vc < 0:
						return "negative count at (pdeck=%d,cdeck=%d,wp=%d,wc=%d): %s" % [pdeck, cdeck, wp, wc, c]
					if dp + vp != pdeck:
						return "player draw+win (%d) != pdeck (%d)" % [dp + vp, pdeck]
					if dc + vc != cdeck:
						return "cpu draw+win (%d) != cdeck (%d)" % [dc + vc, cdeck]
					if vp > pdeck or vc > cdeck:
						return "win exceeds deck (clamp failed) at wp=%d pdeck=%d" % [wp, pdeck]

	# Specific clamp + recycle: 30 won but only 10 in deck -> win 10, draw 0.
	var clamped := PileModel.counts({"player": 30, "cpu": 0}, 10, 10)
	if int(clamped["player"]["win"]) != 10 or int(clamped["player"]["draw"]) != 0:
		return "clamp/recycle: 30 won over a 10-card deck should be win 10 / draw 0, got %s" % clamped["player"]

	# --- accrue: award adds to winner; forfeit does NOT; new_game resets --------
	var w := PileModel.empty()
	w = PileModel.accrue(w, [{"type": "flip"}, {"type": "award", "winner": "player", "cards": 2}])
	if int(w["player"]) != 2 or int(w["cpu"]) != 0:
		return "accrue award player 2 failed: %s" % w
	w = PileModel.accrue(w, [{"type": "war_decide"}, {"type": "award", "winner": "cpu", "cards": 8}])
	if int(w["cpu"]) != 8 or int(w["player"]) != 2:
		return "accrue award cpu 8 failed: %s" % w
	# war_forfeit carries a winner but NO cards -> it must not accrue on its own.
	var wf := PileModel.accrue(PileModel.empty(), [{"type": "war_forfeit", "winner": "player"}])
	if int(wf["player"]) != 0:
		return "war_forfeit (no cards) must not accrue, got %s" % wf
	# new_game resets.
	var wr := PileModel.accrue({"player": 9, "cpu": 4}, [{"type": "new_game", "seed": "x"}])
	if int(wr["player"]) != 0 or int(wr["cpu"]) != 0:
		return "new_game did not reset the accumulator: %s" % wr

	# --- idempotence of clamp_to ----------------------------------------------
	var once := PileModel.clamp_to({"player": 99, "cpu": 99}, 5, 7)
	var twice := PileModel.clamp_to(once, 5, 7)
	if once != twice:
		return "clamp_to is not idempotent: %s vs %s" % [once, twice]

	# --- accrual + clamp across a REAL driven match ----------------------------
	var match_err := _run_real_match("pile-model-vector-0001")
	if match_err != "":
		return match_err

	return ""


## Drive a bare WarMatch to a terminal phase, accruing won per apply (exactly once)
## and clamping, asserting the conservation + clamp invariants after every step.
func _run_real_match(seed: String) -> String:
	var m = WarMatch.new()
	var ev_buf: Array = []
	# NOTE: clear() in place, never `ev_buf = []` — the signal lambda captures THIS
	# array by reference; reassigning would leave it appending to the orphaned original.
	m.event.connect(func(ev: Dictionary) -> void: ev_buf.append(ev))
	m.new_game(seed)
	var won := PileModel.accrue(PileModel.empty(), ev_buf)  # consumes the new_game event
	ev_buf.clear()

	var saw_award := false
	var steps := 0
	while steps < 200000:
		var st := m.get_state() as Dictionary
		var phase := String(st.get("phase", ""))
		# Invariants at the CURRENT state.
		var pdeck: int = (st.get("player_deck", []) as Array).size()
		var cdeck: int = (st.get("cpu_deck", []) as Array).size()
		won = PileModel.clamp_to(won, pdeck, cdeck)
		var c := PileModel.counts(won, pdeck, cdeck)
		if int(c["player"]["draw"]) < 0 or int(c["cpu"]["draw"]) < 0:
			return "negative draw mid-match at step %d" % steps
		if int(c["player"]["win"]) > pdeck or int(c["cpu"]["win"]) > cdeck:
			return "win exceeds deck mid-match at step %d" % steps
		if int(c["player"]["draw"]) + int(c["player"]["win"]) != pdeck:
			return "player draw+win != deck mid-match at step %d" % steps
		# Pots empty (resting at dealt or terminal) -> the on-screen total is the full 52.
		var pots_empty := (st.get("player_pot", []) as Array).is_empty() and (st.get("cpu_pot", []) as Array).is_empty()
		if pots_empty:
			var total := int(c["player"]["draw"]) + int(c["player"]["win"]) + int(c["cpu"]["draw"]) + int(c["cpu"]["win"])
			if total != 52:
				return "on-screen total %d != 52 at a pots-empty state (step %d, phase %s)" % [total, steps, phase]
		if phase == "player_win" or phase == "cpu_win":
			break
		# Advance.
		match phase:
			"dealt": m.submit_action(WarActions.start_round())
			"selected": m.submit_action(WarActions.flip())
			"flipped": m.submit_action(WarActions.resolve())
			"war": m.submit_action(WarActions.ack_war())
			_:
				m.free()
				return "unexpected phase '%s' mid-match" % phase
		# Accrue this apply's events exactly once.
		var added := PileModel.accrue(PileModel.empty(), ev_buf)
		if int(added["player"]) > 0 or int(added["cpu"]) > 0:
			saw_award = true
		won = PileModel.accrue(won, ev_buf)
		ev_buf.clear()
		steps += 1

	var final_state := m.get_state() as Dictionary
	var fp: int = (final_state.get("player_deck", []) as Array).size()
	var fc: int = (final_state.get("cpu_deck", []) as Array).size()
	won = PileModel.clamp_to(won, fp, fc)
	var fcounts := PileModel.counts(won, fp, fc)
	m.free()
	# Terminal conservation: winner holds all 52 (draw+win), loser holds 0.
	if int(fcounts["player"]["draw"]) + int(fcounts["player"]["win"]) != fp:
		return "terminal: player draw+win != player_deck"
	if int(fcounts["cpu"]["draw"]) + int(fcounts["cpu"]["win"]) != fc:
		return "terminal: cpu draw+win != cpu_deck"
	if fp + fc != 52:
		return "terminal decks do not sum to 52 (%d + %d)" % [fp, fc]
	if not saw_award:
		return "no award occurred in the driven match (cannot validate win accrual)"
	return ""
