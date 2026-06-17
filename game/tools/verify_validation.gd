extends SceneTree
## VERIFY validation — WarValidation's per-phase legal/illegal action gating.
##
## WarValidation is the shared gate (mirrored byte-for-byte in TS) that decides
## whether an action is legal in the current phase BEFORE the engine mutates state.
## The engine and the server both call it, so this is the single source of truth for
## "what can I do right now". This verifier walks the phase table:
##
##   phase "dealt"     -> start_round legal; flip/resolve/ack_war illegal
##   phase "selected"  -> flip legal, play_special legal; start_round illegal
##   phase "flipped"   -> resolve legal; flip illegal
##   phase "war"       -> ack_war/resolve legal; start_round illegal
##   terminal (*_win)  -> only new_game legal
##
## Contract: WarValidation.check(state, action) -> {ok:bool, error:String} (or a bool).
## This verifier tolerates either return shape.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_validation.gd


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY validation: PASS")
	else:
		print("VERIFY validation: FAIL %s" % reason)
	quit()


func _run() -> String:
	var Validation: Variant = _load("res://logic/validation.gd")
	if Validation == null:
		return "WarValidation not found at res://logic/validation.gd"
	if not _has_check(Validation):
		return "WarValidation exposes no check()/is_legal() entry point"

	# Each case: phase, action, expected-legal. The player owns one special so the
	# play_special legality is about PHASE, not inventory.
	var cases := [
		# dealt
		{"phase": "dealt", "action": {"type": "start_round"}, "legal": true},
		{"phase": "dealt", "action": {"type": "flip"}, "legal": false},
		{"phase": "dealt", "action": {"type": "resolve"}, "legal": false},
		{"phase": "dealt", "action": {"type": "ack_war"}, "legal": false},
		# selected (after start_round, before reveal — the flip moment)
		{"phase": "selected", "action": {"type": "flip"}, "legal": true},
		{"phase": "selected", "action": {"type": "play_special", "id": "peek"}, "legal": true},
		{"phase": "selected", "action": {"type": "start_round"}, "legal": false},
		{"phase": "selected", "action": {"type": "resolve"}, "legal": false},
		# flipped (revealed, awaiting award)
		{"phase": "flipped", "action": {"type": "resolve"}, "legal": true},
		{"phase": "flipped", "action": {"type": "flip"}, "legal": false},
		{"phase": "flipped", "action": {"type": "start_round"}, "legal": false},
		# war (tie escalation)
		{"phase": "war", "action": {"type": "ack_war"}, "legal": true},
		{"phase": "war", "action": {"type": "start_round"}, "legal": false},
		# terminal
		{"phase": "player_win", "action": {"type": "new_game", "seed": "x"}, "legal": true},
		{"phase": "player_win", "action": {"type": "start_round"}, "legal": false},
		{"phase": "cpu_win", "action": {"type": "flip"}, "legal": false},
	]

	for c in cases:
		var state := _make_state(str(c["phase"]))
		var got := _is_legal(Validation, state, c["action"])
		var want: bool = c["legal"]
		if got != want:
			return "phase=%s action=%s: expected legal=%s, got %s" % [
				c["phase"], c["action"].get("type", "?"), str(want), str(got)
			]

	# Unknown action type is always illegal, regardless of phase.
	if _is_legal(Validation, _make_state("dealt"), {"type": "__bogus__"}):
		return "unknown action type accepted in phase dealt"

	# new_game should be legal from the canonical empty/initial state too.
	if not _is_legal(Validation, {}, {"type": "new_game", "seed": "x"}):
		return "new_game rejected from empty state"

	return ""


# --- check() adapters (tolerant of {ok,error} dict OR bool return) ----------

func _has_check(Validation: Variant) -> bool:
	return Validation.has_method("check") or Validation.has_method("is_legal")


func _is_legal(Validation: Variant, state: Dictionary, action: Variant) -> bool:
	var res: Variant
	if Validation.has_method("check"):
		res = Validation.check(state, action)
	else:
		res = Validation.is_legal(state, action)
	if typeof(res) == TYPE_BOOL:
		return res
	if typeof(res) == TYPE_DICTIONARY:
		return bool(res.get("ok", false))
	return false


# --- state builder ----------------------------------------------------------

func _make_state(phase: String) -> Dictionary:
	# A mid-game-ish state with enough cards that nothing is "legal but impossible
	# for lack of cards" — keeps the test about PHASE gating, not deck depth.
	var deck := []
	for r in range(2, 10):
		deck.append({"rank": r, "suit": "clubs", "face_up": false})
	var deck2 := []
	for r in range(2, 10):
		deck2.append({"rank": r, "suit": "hearts", "face_up": false})
	return {
		"version": 1,
		"seed": "verify-validation",
		"phase": phase,
		"player_deck": deck,
		"cpu_deck": deck2,
		"player_pot": [],
		"cpu_pot": [],
		"rng": {"seq": 0},
		"specials": {"player": ["peek"], "cpu": []},
		"pending_special": null,
		"war_depth": (1 if phase == "war" else 0),
	}


func _load(path: String) -> Variant:
	if not ResourceLoader.exists(path):
		return null
	return load(path)
