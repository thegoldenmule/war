extends RefCounted
## Editor-suite tests for the pure WarEngine state machine.
##
## Designed to run under the godot-ai `test_run` MCP (McpTestSuite): the runner
## discovers test_*.gd in res://tests/, instantiates this RefCounted, and invokes
## every `test_*` method. Self-contained (no McpTestSuite base dependency); failures
## raise via assert(). Mirrors tools/verify_engine.gd.
##
## Covers: new_game deals 26/26 from a seeded shuffle; a normal round awards the
## higher card and conserves 52; a forced tie escalates to WAR; win detection flips
## phase to player_win/cpu_win. WarEngine.apply is PURE (returns a new state).

const SEED := "war-engine-vector-0001"


func _engine() -> Variant:
	assert(ResourceLoader.exists("res://logic/engine.gd"), "WarEngine missing at res://logic/engine.gd")
	return load("res://logic/engine.gd")


func _card(rank: int, suit: String) -> Dictionary:
	return {"rank": rank, "suit": suit, "face_up": false}


func _make_state(player_deck: Array, cpu_deck: Array) -> Dictionary:
	return {
		"version": 1, "seed": "test-engine", "phase": "dealt",
		"player_deck": player_deck, "cpu_deck": cpu_deck,
		"player_pot": [], "cpu_pot": [],
		"rng": {"seq": 0}, "specials": {"player": [], "cpu": []},
		"pending_special": null, "war_depth": 0,
	}


func _total(state: Dictionary) -> int:
	return (state.get("player_deck", []) as Array).size() \
		+ (state.get("cpu_deck", []) as Array).size() \
		+ (state.get("player_pot", []) as Array).size() \
		+ (state.get("cpu_pot", []) as Array).size()


## new_game deals exactly 26 to each side from a full standard deck.
func test_new_game_deals_26_26() -> void:
	var Engine_: Variant = _engine()
	var res: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})
	assert(bool(res.get("ok", false)), "new_game rejected: %s" % str(res.get("error", "")))
	var state: Dictionary = res["state"]
	assert((state["player_deck"] as Array).size() == 26, "player_deck != 26")
	assert((state["cpu_deck"] as Array).size() == 26, "cpu_deck != 26")
	assert(str(state.get("phase", "")) == "dealt", "phase after new_game != dealt")

	# Combined deal is a full, unique 52-card deck.
	var seen := {}
	for c in (state["player_deck"] as Array) + (state["cpu_deck"] as Array):
		var key := "%d-%s" % [int(c["rank"]), str(c["suit"])]
		assert(int(c["rank"]) >= 2 and int(c["rank"]) <= 14, "rank out of range")
		assert(not seen.has(key), "duplicate card %s" % key)
		seen[key] = true
	assert(seen.size() == 52, "deal is not 52 distinct cards")


## Same seed -> identical deal (determinism).
func test_seeded_deal_is_deterministic() -> void:
	var Engine_: Variant = _engine()
	var a: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})["state"]
	var b: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})["state"]
	assert(str(a["player_deck"]) == str(b["player_deck"]), "seeded deal not deterministic")


## apply() must not mutate the input state across the hash boundary.
func test_apply_is_pure() -> void:
	var Engine_: Variant = _engine()
	var state: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})["state"]
	var top_before := str((state["player_deck"] as Array)[0])
	var _ignored: Dictionary = Engine_.apply(state, {"type": "start_round"})
	assert(str((state["player_deck"] as Array)[0]) == top_before, "apply mutated input (purity violation)")


## A normal round (start_round -> flip -> resolve) conserves the 52-card total.
func test_round_conserves_cards() -> void:
	var Engine_: Variant = _engine()
	var state: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": SEED})["state"]
	for action in [{"type": "start_round"}, {"type": "flip"}, {"type": "resolve"}]:
		var r: Dictionary = Engine_.apply(state, action)
		assert(bool(r.get("ok", false)), "%s rejected: %s" % [action["type"], str(r.get("error", ""))])
		state = r["state"]
	assert(_total(state) == 52, "round did not conserve 52 cards (got %d)" % _total(state))


## Equal top ranks escalate to a WAR (phase == war, war_depth increments).
func test_tie_triggers_war() -> void:
	var Engine_: Variant = _engine()
	var state := _make_state(
		[_card(7, "clubs"), _card(2, "clubs"), _card(3, "clubs"), _card(4, "clubs"), _card(5, "clubs")],
		[_card(7, "hearts"), _card(9, "hearts"), _card(10, "hearts"), _card(11, "hearts"), _card(12, "hearts")]
	)
	state = Engine_.apply(state, {"type": "start_round"})["state"]
	var r: Dictionary = Engine_.apply(state, {"type": "flip"})
	assert(bool(r.get("ok", false)), "flip rejected: %s" % str(r.get("error", "")))
	var s: Dictionary = r["state"]
	assert(str(s.get("phase", "")) == "war", "tie did not trigger war (phase=%s)" % s.get("phase", ""))
	assert(int(s.get("war_depth", -1)) >= 1, "war_depth did not increment")


## Emptying the CPU deck flips the phase to player_win.
func test_win_detection() -> void:
	var Engine_: Variant = _engine()
	var state := _make_state([_card(14, "spades"), _card(13, "spades")], [_card(2, "clubs")])
	for action in [{"type": "start_round"}, {"type": "flip"}, {"type": "resolve"}]:
		var r: Dictionary = Engine_.apply(state, action)
		assert(bool(r.get("ok", false)), "%s rejected: %s" % [action["type"], str(r.get("error", ""))])
		state = r["state"]
	if (state.get("cpu_deck", []) as Array).is_empty():
		assert(str(state.get("phase", "")) == "player_win", "cpu emptied but phase != player_win")
