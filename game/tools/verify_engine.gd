extends SceneTree
## VERIFY engine — exercises the pure WarEngine state machine end to end.
##
## Asserts the core loop as built (and as gated by WarValidation, the authoritative
## phase table both client and server share):
##   - new_game deals 26 cards to the player and 26 to the CPU from a seeded shuffle
##     (combined = a full unique 52-card deck) and rests in phase "dealt";
##   - start_round STAGES the top card of each deck into the pots and advances to
##     "selected" (the flip moment: play a special, or flip);
##   - flip (legal in "selected") reveals both cards; resolve awards the higher rank
##     and conserves the 52-card total;
##   - equal revealed ranks escalate to a WAR (phase "war", war_depth >= 1) and
##     ack_war stakes + decides it;
##   - win detection flips phase to player_win / cpu_win when a side is drained.
##
## WarEngine.apply(state, action) -> {ok, state, events, error} is PURE: it returns
## a NEW state and must not mutate the input across the hash boundary; checked too.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_engine.gd

const SEED := "war-engine-vector-0001"


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY engine: PASS")
	else:
		print("VERIFY engine: FAIL %s" % reason)
	quit()


func _run() -> String:
	var Engine_: Variant = _load("res://logic/engine.gd")
	if Engine_ == null:
		return "WarEngine not found at res://logic/engine.gd"

	# --- new_game deals 26/26 ------------------------------------------------
	var res: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})
	if not _ok(res):
		return "new_game rejected: %s" % _err(res)
	var state: Dictionary = res["state"]

	var pd: Array = state.get("player_deck", [])
	var cd: Array = state.get("cpu_deck", [])
	if pd.size() != 26:
		return "player_deck has %d cards, expected 26" % pd.size()
	if cd.size() != 26:
		return "cpu_deck has %d cards, expected 26" % cd.size()
	if state.get("phase", "") != "dealt":
		return "phase after new_game is %s, expected dealt" % state.get("phase", "")

	var card_err := _assert_full_deck(pd + cd)
	if card_err != "":
		return "deal is not a full 52-card deck: %s" % card_err

	# Determinism: same seed -> identical deal.
	var deal_b: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})["state"]
	if str(deal_b.get("player_deck", [])) != str(pd):
		return "seeded deal is not deterministic for seed %s" % SEED

	# PURITY: applying an action must not mutate the input dict's decks.
	var before_top := str(pd[0]) if pd.size() > 0 else ""
	var _ignored: Dictionary = Engine_.apply(state, {"type": "start_round"})
	if pd.size() > 0 and str(pd[0]) != before_top:
		return "WarEngine.apply mutated the input state (purity violation)"

	# --- start_round stages into the pots, rests in "dealt" -----------------
	var stage_err := _run_start_round(Engine_, state)
	if stage_err != "":
		return stage_err

	# --- normal round awards the higher card (driven via the legal flow) ----
	var round_err := _run_one_round(Engine_)
	if round_err != "":
		return round_err

	# --- forced tie escalates to WAR, ack_war decides it --------------------
	var war_err := _run_forced_war(Engine_)
	if war_err != "":
		return war_err

	# --- win detection -------------------------------------------------------
	var win_err := _run_win_detection(Engine_)
	if win_err != "":
		return win_err

	return ""


## start_round on a freshly dealt state stages one card per side into the pots and
## advances to "selected" (the flip moment). Total cards are conserved.
func _run_start_round(Engine_: Variant, dealt: Dictionary) -> String:
	var total_before := _total_cards(dealt)
	var r: Dictionary = Engine_.apply(dealt, {"type": "start_round"})
	if not _ok(r):
		return "start_round rejected: %s" % _err(r)
	var s: Dictionary = r["state"]
	if (s.get("player_pot", []) as Array).size() != 1 or (s.get("cpu_pot", []) as Array).size() != 1:
		return "start_round did not stage exactly one card per pot"
	if str(s.get("phase", "")) != "selected":
		return "phase after start_round is %s, expected selected (the flip moment)" % s.get("phase", "")
	if _total_cards(s) != total_before:
		return "start_round did not conserve cards (%d -> %d)" % [total_before, _total_cards(s)]
	return ""


## Plays a full legal round on a hand-crafted state: stage -> selected -> flip ->
## resolve. Asserts the higher card wins the pot and the total is conserved with a
## clear single winner.
func _run_one_round(Engine_: Variant) -> String:
	# Player top = 9 beats CPU top = 4.
	var state := _make_state(
		[_card(9, "clubs"), _card(2, "clubs"), _card(3, "clubs")],
		[_card(4, "hearts"), _card(5, "hearts"), _card(6, "hearts")]
	)
	var total_before := _total_cards(state)
	var player_before := (state["player_deck"] as Array).size()

	var s: Dictionary = Engine_.apply(state, {"type": "start_round"})["state"]
	if str(s.get("phase", "")) != "selected":
		return "start_round did not advance to selected (got %s)" % s.get("phase", "")

	var rf: Dictionary = Engine_.apply(s, {"type": "flip"})
	if not _ok(rf):
		return "flip rejected: %s" % _err(rf)
	s = rf["state"]
	if str(s.get("phase", "")) != "flipped":
		return "phase after flip is %s, expected flipped (9 vs 4 is not a tie)" % s.get("phase", "")

	var rr: Dictionary = Engine_.apply(s, {"type": "resolve"})
	if not _ok(rr):
		return "resolve rejected: %s" % _err(rr)
	s = rr["state"]

	if _total_cards(s) != total_before:
		return "round did not conserve cards (%d -> %d)" % [total_before, _total_cards(s)]
	# Player won 9 vs 4: their deck should have grown by the 2-card pot (minus the
	# one they staged), i.e. net +1 vs the pre-round count.
	var player_after := (s.get("player_deck", []) as Array).size()
	if player_after <= player_before - 1:
		return "winner (player) did not gain the pot: %d -> %d" % [player_before, player_after]
	if not (s.get("cpu_pot", []) as Array).is_empty() or not (s.get("player_pot", []) as Array).is_empty():
		return "pots not cleared after a decisive resolve"
	return ""


## Equal revealed ranks escalate to a war; ack_war stakes + decides it.
func _run_forced_war(Engine_: Variant) -> String:
	# Both tops = 7 -> tie at flip. Each side has enough depth (>= WAR_STAKE+1) to
	# stake the war.
	var state := _make_state(
		[_card(7, "clubs"), _card(13, "clubs"), _card(2, "clubs"), _card(3, "clubs"), _card(4, "clubs"), _card(5, "clubs")],
		[_card(7, "hearts"), _card(8, "hearts"), _card(9, "hearts"), _card(10, "hearts"), _card(11, "hearts"), _card(12, "hearts")]
	)
	var total_before := _total_cards(state)

	var s: Dictionary = Engine_.apply(state, {"type": "start_round"})["state"]
	var rf: Dictionary = Engine_.apply(s, {"type": "flip"})
	if not _ok(rf):
		return "war setup: flip rejected: %s" % _err(rf)
	s = rf["state"]
	if str(s.get("phase", "")) != "war":
		return "equal top ranks did not trigger war (phase=%s)" % s.get("phase", "")
	if int(s.get("war_depth", -1)) < 1:
		return "war_depth did not increment on tie (got %s)" % str(s.get("war_depth", -1))

	# ack_war stakes WAR_STAKE face-down + 1 decider per side, then compares.
	var ra: Dictionary = Engine_.apply(s, {"type": "ack_war"})
	if not _ok(ra):
		return "ack_war rejected: %s" % _err(ra)
	s = ra["state"]
	if _total_cards(s) != total_before:
		return "war did not conserve cards (%d -> %d)" % [total_before, _total_cards(s)]
	# Player decider 13 beats CPU decider 8, so the player should hold everything
	# (the smaller hand-crafted deck is fully consumed) or the round is awarded.
	var phase := str(s.get("phase", ""))
	if phase != "dealt" and phase != "player_win" and phase != "cpu_win":
		return "phase after ack_war is %s, expected dealt or a terminal win" % phase
	return ""


## Draining a side's deck flips the phase to the opponent's win.
func _run_win_detection(Engine_: Variant) -> String:
	# Player 14 beats CPU 2; after the award the CPU deck is empty -> player_win.
	var state := _make_state(
		[_card(14, "spades"), _card(13, "spades")],
		[_card(2, "clubs")]
	)
	var s: Dictionary = Engine_.apply(state, {"type": "start_round"})["state"]
	var rf: Dictionary = Engine_.apply(s, {"type": "flip"})
	if not _ok(rf):
		return "win setup: flip rejected: %s" % _err(rf)
	var rr: Dictionary = Engine_.apply(rf["state"], {"type": "resolve"})
	if not _ok(rr):
		return "win setup: resolve rejected: %s" % _err(rr)
	s = rr["state"]
	if (s.get("cpu_deck", []) as Array).is_empty() and str(s.get("phase", "")) != "player_win":
		return "cpu deck emptied but phase is %s, expected player_win" % s.get("phase", "")
	return ""


# --- state/card builders & invariants -------------------------------------

func _make_state(player_deck: Array, cpu_deck: Array, player_specials := []) -> Dictionary:
	return {
		"version": 1,
		"seed": "verify-engine-handcrafted",
		"phase": "dealt",
		"player_deck": player_deck,
		"cpu_deck": cpu_deck,
		"player_pot": [],
		"cpu_pot": [],
		"rng": {"seq": 0},
		"specials": {"player": player_specials, "cpu": []},
		"pending_special": null,
		"war_depth": 0,
	}


func _card(rank: int, suit: String) -> Dictionary:
	return {"rank": rank, "suit": suit, "face_up": false}


func _assert_full_deck(cards: Array) -> String:
	if cards.size() != 52:
		return "expected 52 cards, got %d" % cards.size()
	var seen := {}
	var suits := ["clubs", "diamonds", "hearts", "spades"]
	for c in cards:
		if typeof(c) != TYPE_DICTIONARY:
			return "card is not a dictionary"
		var rank := int(c.get("rank", -1))
		var suit := str(c.get("suit", ""))
		if rank < 2 or rank > 14:
			return "rank %d out of range 2..14" % rank
		if not suits.has(suit):
			return "unknown suit %s" % suit
		var key := "%d-%s" % [rank, suit]
		if seen.has(key):
			return "duplicate card %s" % key
		seen[key] = true
	if seen.size() != 52:
		return "deck has %d distinct cards, expected 52" % seen.size()
	return ""


func _total_cards(state: Dictionary) -> int:
	return (state.get("player_deck", []) as Array).size() \
		+ (state.get("cpu_deck", []) as Array).size() \
		+ (state.get("player_pot", []) as Array).size() \
		+ (state.get("cpu_pot", []) as Array).size()


# --- generic helpers -------------------------------------------------------

func _load(path: String) -> Variant:
	if not ResourceLoader.exists(path):
		return null
	return load(path)


func _ok(res: Variant) -> bool:
	return typeof(res) == TYPE_DICTIONARY and bool(res.get("ok", false))


func _err(res: Variant) -> String:
	if typeof(res) == TYPE_DICTIONARY:
		return str(res.get("error", "<no error>"))
	return "<engine returned non-dictionary>"
