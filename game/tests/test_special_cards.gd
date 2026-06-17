extends RefCounted
## Editor-suite tests for WarSpecialCards example effects.
##
## Designed to run under the godot-ai `test_run` MCP (McpTestSuite): the runner
## discovers test_*.gd in res://tests/, instantiates this RefCounted, and invokes
## every `test_*` method. Self-contained (no McpTestSuite base dependency); failures
## raise via assert(). Mirrors tools/verify_special_cards.gd.
##
## Special Cards are the collectible power-up hook. The catalog + timing metadata
## live in WarConstants.SPECIAL_CARDS / SPECIAL_CARD_IDS; WarSpecialCards.resolve
## implements the effects INSIDE the deterministic engine (validator-authoritative,
## pure, deterministic). These tests assert the catalog is well-formed, ownership is
## enforced, and the representative effects (peek -> reveal + selected; rank_boost ->
## +2 clamped; steal_tie -> arms pending) behave as documented, without breaking the
## card-count invariant or apply()'s purity.


func _specials() -> Variant:
	assert(ResourceLoader.exists("res://logic/special_cards.gd"), "WarSpecialCards missing at res://logic/special_cards.gd")
	return load("res://logic/special_cards.gd")


func _engine() -> Variant:
	assert(ResourceLoader.exists("res://logic/engine.gd"), "WarEngine missing at res://logic/engine.gd")
	return load("res://logic/engine.gd")


func _constants() -> Variant:
	assert(ResourceLoader.exists("res://logic/constants.gd"), "WarConstants missing at res://logic/constants.gd")
	return load("res://logic/constants.gd")


func _make_state(player_specials: Array, player_top := 5, cpu_top := 9) -> Dictionary:
	return {
		"version": 1, "seed": "test-special-cards", "phase": "dealt",
		"player_deck": [
			{"rank": player_top, "suit": "clubs", "face_up": false},
			{"rank": 6, "suit": "clubs", "face_up": false},
			{"rank": 7, "suit": "clubs", "face_up": false},
			{"rank": 8, "suit": "clubs", "face_up": false},
		],
		"cpu_deck": [
			{"rank": cpu_top, "suit": "hearts", "face_up": false},
			{"rank": 10, "suit": "hearts", "face_up": false},
			{"rank": 11, "suit": "hearts", "face_up": false},
			{"rank": 12, "suit": "hearts", "face_up": false},
		],
		"player_pot": [], "cpu_pot": [],
		"rng": {"seq": 0}, "specials": {"player": player_specials, "cpu": []},
		"pending_special": null, "war_depth": 0,
	}


func _force_flipped(s: Dictionary) -> Dictionary:
	var out := s.duplicate(true)
	out["phase"] = "flipped"
	for key in ["player_pot", "cpu_pot"]:
		var pot := out.get(key, []) as Array
		if not pot.is_empty():
			(pot[pot.size() - 1] as Dictionary)["face_up"] = true
	return out


func _total(state: Dictionary) -> int:
	return (state.get("player_deck", []) as Array).size() \
		+ (state.get("cpu_deck", []) as Array).size() \
		+ (state.get("player_pot", []) as Array).size() \
		+ (state.get("cpu_pot", []) as Array).size()


## The catalog (WarConstants) is well-formed: unique non-empty ids, each present in
## SPECIAL_CARDS with a valid timing window, and the two structures agree.
func test_catalog_is_well_formed() -> void:
	var C: Variant = _constants()
	var ids: Array = C.SPECIAL_CARD_IDS
	var catalog: Dictionary = C.SPECIAL_CARDS
	assert(not ids.is_empty(), "SPECIAL_CARD_IDS is empty")
	var seen := {}
	for id in ids:
		assert(typeof(id) == TYPE_STRING and not (id as String).is_empty(), "id not a non-empty string: %s" % str(id))
		assert(not seen.has(id), "duplicate id %s" % id)
		seen[id] = true
		assert(catalog.has(id), "id %s missing from SPECIAL_CARDS dict" % id)
		var when: String = str((catalog[id] as Dictionary).get("when", ""))
		assert(when == C.WHEN_PRE_FLIP or when == C.WHEN_POST_FLIP, "id %s invalid window '%s'" % [id, when])
	assert(catalog.size() == ids.size(), "SPECIAL_CARDS / SPECIAL_CARD_IDS size mismatch")


## resolve() rejects an unknown id and an unowned id.
func test_resolve_rejects_unknown_and_unowned() -> void:
	var Specials: Variant = _specials()
	var C: Variant = _constants()
	var unknown: Dictionary = Specials.resolve(_make_state([]), "__not_a_real_card__")
	assert(not bool(unknown.get("ok", true)), "resolve accepted an unknown id")
	var unowned: Dictionary = Specials.resolve(_make_state([]), C.SPECIAL_CARD_IDS[0])
	assert(not bool(unowned.get("ok", true)), "resolve accepted an unowned id")


## peek (pre-flip) reveals the staged player card and leaves phase "selected".
func test_peek_reveals_and_selects() -> void:
	var Engine_: Variant = _engine()
	var s := _make_state(["peek"])
	s = Engine_.apply(s, {"type": "start_round"})["state"]
	var r: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "peek"})
	assert(bool(r.get("ok", false)), "peek rejected: %s" % str(r.get("error", "")))
	var after := r["state"] as Dictionary
	var pot := after.get("player_pot", []) as Array
	assert(not pot.is_empty(), "peek left no staged player card")
	assert(bool((pot[pot.size() - 1] as Dictionary).get("face_up", false)), "peek did not reveal the staged card")
	assert(str(after.get("phase", "")) == "selected", "peek did not leave phase selected")


## rank_boost (post-flip) adds +2 to the revealed rank, clamped at RANK_MAX.
func test_rank_boost_adds_two_and_clamps() -> void:
	var Engine_: Variant = _engine()
	var C: Variant = _constants()
	var s := _make_state(["rank_boost"], 5, 9)
	s = _force_flipped(Engine_.apply(s, {"type": "start_round"})["state"])
	var r: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "rank_boost"})
	assert(bool(r.get("ok", false)), "rank_boost rejected: %s" % str(r.get("error", "")))
	var pot := (r["state"] as Dictionary).get("player_pot", []) as Array
	assert(int((pot[pot.size() - 1] as Dictionary).get("rank", -1)) == 7, "rank_boost 5 did not become 7")

	var rank_max: int = int(C.RANK_MAX)
	var s2 := _make_state(["rank_boost"], rank_max, 9)
	s2 = _force_flipped(Engine_.apply(s2, {"type": "start_round"})["state"])
	var r2: Dictionary = Engine_.apply(s2, {"type": "play_special", "id": "rank_boost"})
	assert(bool(r2.get("ok", false)), "rank_boost clamp case rejected")
	var pot2 := (r2["state"] as Dictionary).get("player_pot", []) as Array
	assert(int((pot2[pot2.size() - 1] as Dictionary).get("rank", -1)) == rank_max, "rank_boost did not clamp at RANK_MAX")


## steal_tie (post-flip) arms pending_special for the resolver, staying pure.
func test_steal_tie_arms_pending() -> void:
	var Engine_: Variant = _engine()
	var s := _make_state(["steal_tie"])
	var before := s.duplicate(true)
	s = _force_flipped(Engine_.apply(s, {"type": "start_round"})["state"])
	var r: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "steal_tie"})
	assert(bool(r.get("ok", false)), "steal_tie rejected: %s" % str(r.get("error", "")))
	assert(str((r["state"] as Dictionary).get("pending_special", "")) == "steal_tie", "steal_tie did not arm pending_special")
	# The original handcrafted state is untouched and the count never changed.
	assert(_total(before) == _total(r["state"] as Dictionary), "steal_tie changed the card total")


## Playing an unowned special through the engine is rejected.
func test_play_special_requires_ownership() -> void:
	var Engine_: Variant = _engine()
	var C: Variant = _constants()
	var test_id: String = C.SPECIAL_CARD_IDS[0]
	var s := _make_state([])  # empty inventory
	s = Engine_.apply(s, {"type": "start_round"})["state"]
	var r: Dictionary = Engine_.apply(s, {"type": "play_special", "id": test_id})
	assert(not bool(r.get("ok", false)), "play_special accepted an unowned id")
