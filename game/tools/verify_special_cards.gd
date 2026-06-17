extends SceneTree
## VERIFY special_cards — exercises the WarSpecialCards example effects.
##
## Special Cards are the Balatro-style hook + monetization surface: collectible
## power-ups played around a flip (peek = pre-flip info, rank_boost / steal_tie =
## post-flip) — the catalog + timing metadata live in WarConstants.SPECIAL_CARDS,
## and WarSpecialCards.resolve(state, id) implements the effects INSIDE the
## deterministic engine. Effects are validator-authoritative and must be pure +
## deterministic exactly like the rest of WarEngine.
##
## This verifier asserts the catalog is well-formed, every id resolves through the
## engine's play_special action in its declared timing window, ownership is
## enforced, and the representative effects (peek -> reveals + selected;
## rank_boost -> +2 clamped; steal_tie -> arms pending) behave as documented — all
## without breaking the 52-card invariant or apply()'s purity.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_special_cards.gd


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY special_cards: PASS")
	else:
		print("VERIFY special_cards: FAIL %s" % reason)
	quit()


func _run() -> String:
	var Specials: Variant = _load("res://logic/special_cards.gd")
	if Specials == null:
		return "WarSpecialCards not found at res://logic/special_cards.gd"
	var Engine_: Variant = _load("res://logic/engine.gd")
	if Engine_ == null:
		return "WarEngine not found at res://logic/engine.gd"
	var C: Variant = _load("res://logic/constants.gd")
	if C == null:
		return "WarConstants not found at res://logic/constants.gd"

	# --- catalog is well-formed (source of truth: WarConstants) -------------
	var ids: Array = C.SPECIAL_CARD_IDS
	var catalog: Dictionary = C.SPECIAL_CARDS
	if ids.is_empty():
		return "WarConstants.SPECIAL_CARD_IDS is empty"
	var seen := {}
	for id in ids:
		if typeof(id) != TYPE_STRING or (id as String).is_empty():
			return "special-card id is not a non-empty string: %s" % str(id)
		if seen.has(id):
			return "duplicate special-card id: %s" % id
		seen[id] = true
		if not catalog.has(id):
			return "id %s in SPECIAL_CARD_IDS missing from SPECIAL_CARDS dict" % id
		var when: String = str((catalog[id] as Dictionary).get("when", ""))
		if when != C.WHEN_PRE_FLIP and when != C.WHEN_POST_FLIP:
			return "id %s has invalid timing window '%s'" % [id, when]
	# The id list and the catalog dict must describe the same set.
	if (catalog.keys() as Array).size() != ids.size():
		return "SPECIAL_CARDS has %d entries but SPECIAL_CARD_IDS has %d" % [catalog.size(), ids.size()]

	# --- resolve() rejects an unknown id and an unowned id ------------------
	var unknown: Dictionary = Specials.resolve(_make_state([]), "__not_a_real_card__")
	if bool(unknown.get("ok", true)):
		return "WarSpecialCards.resolve accepted an unknown id"
	var unowned: Dictionary = Specials.resolve(_make_state([]), ids[0])
	if bool(unowned.get("ok", true)):
		return "WarSpecialCards.resolve accepted an id the player does not own"

	# --- every id is playable through the engine in its timing window -------
	for id in ids:
		var when: String = str((catalog[id] as Dictionary).get("when", ""))
		var played: String = _play_in_window(Engine_, id, when)
		if played != "":
			return "play_special(%s, when=%s): %s" % [id, when, played]

	# --- peek (pre-flip): reveals the staged card and advances to selected --
	var peek_err := _check_peek(Engine_)
	if peek_err != "":
		return peek_err

	# --- rank_boost (post-flip): +2 to the revealed rank, clamped at RANK_MAX
	var boost_err := _check_rank_boost(Engine_, C)
	if boost_err != "":
		return boost_err

	# --- steal_tie (post-flip): arms pending_special for the resolver -------
	var steal_err := _check_steal_tie(Engine_)
	if steal_err != "":
		return steal_err

	return ""


## Stages a round, plays `id` in the phase its `when` permits, and asserts the
## engine accepts it, stays pure, and conserves the card total. Returns "" on
## success or a failure reason string.
func _play_in_window(Engine_: Variant, id: String, when: String) -> String:
	var state := _make_state([id])
	var before := state.duplicate(true)
	var total_before := _total_cards(state)

	# Stage the round -> phase "selected" (the flip moment).
	var staged: Dictionary = Engine_.apply(state, {"type": "start_round"})
	if not _ok(staged):
		return "start_round rejected: %s" % _err(staged)
	var s := staged["state"] as Dictionary

	if when == "post_flip":
		# Reach "flipped" so a post-flip special is legal. We hand-set the phase +
		# face_up flags to mirror what WarEngine._flip produces (a real flip on equal
		# tops would route to "war" instead), keeping this a focused window probe.
		s = _force_flipped(s)

	var res: Dictionary = Engine_.apply(s, {"type": "play_special", "id": id})
	if not _ok(res):
		return "rejected while granted & in-window: %s" % _err(res)
	var after := res["state"] as Dictionary

	if str(state) != str(before):
		return "apply mutated the input (purity violation)"
	if _total_cards(after) != total_before:
		return "card total changed by play_special (%d -> %d)" % [total_before, _total_cards(after)]
	return ""


## peek reveals the player's staged top card (face_up) and sets phase "selected".
func _check_peek(Engine_: Variant) -> String:
	var s := _make_state(["peek"])
	s = Engine_.apply(s, {"type": "start_round"})["state"]
	var res: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "peek"})
	if not _ok(res):
		return "peek rejected: %s" % _err(res)
	var after := res["state"] as Dictionary
	var pot := after.get("player_pot", []) as Array
	if pot.is_empty():
		return "peek left no staged player card"
	if not bool((pot[pot.size() - 1] as Dictionary).get("face_up", false)):
		return "peek did not reveal the staged player card"
	if str(after.get("phase", "")) != "selected":
		return "peek did not advance phase to selected (got %s)" % after.get("phase", "")
	return ""


## rank_boost adds +2 to the revealed rank, clamped at RANK_MAX (Ace stays 14).
func _check_rank_boost(Engine_: Variant, C: Variant) -> String:
	# A 5 should become 7.
	var s := _make_state(["rank_boost"], 5, 9)
	s = Engine_.apply(s, {"type": "start_round"})["state"]
	s = _force_flipped(s)
	var res: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "rank_boost"})
	if not _ok(res):
		return "rank_boost rejected: %s" % _err(res)
	var pot := (res["state"] as Dictionary).get("player_pot", []) as Array
	var boosted := int((pot[pot.size() - 1] as Dictionary).get("rank", -1))
	if boosted != 7:
		return "rank_boost 5 -> %d, expected 7" % boosted

	# An Ace (RANK_MAX) must clamp, not overflow.
	var rank_max: int = int(C.RANK_MAX)
	var s2 := _make_state(["rank_boost"], rank_max, 9)
	s2 = Engine_.apply(s2, {"type": "start_round"})["state"]
	s2 = _force_flipped(s2)
	var res2: Dictionary = Engine_.apply(s2, {"type": "play_special", "id": "rank_boost"})
	if not _ok(res2):
		return "rank_boost (clamp case) rejected: %s" % _err(res2)
	var pot2 := (res2["state"] as Dictionary).get("player_pot", []) as Array
	var clamped := int((pot2[pot2.size() - 1] as Dictionary).get("rank", -1))
	if clamped != rank_max:
		return "rank_boost did not clamp at RANK_MAX (%d -> %d)" % [rank_max, clamped]
	return ""


## steal_tie leaves a pending_special marker for the resolver.
func _check_steal_tie(Engine_: Variant) -> String:
	var s := _make_state(["steal_tie"])
	s = Engine_.apply(s, {"type": "start_round"})["state"]
	s = _force_flipped(s)
	var res: Dictionary = Engine_.apply(s, {"type": "play_special", "id": "steal_tie"})
	if not _ok(res):
		return "steal_tie rejected: %s" % _err(res)
	if str((res["state"] as Dictionary).get("pending_special", "")) != "steal_tie":
		return "steal_tie did not arm pending_special"
	return ""


# --- state helpers ----------------------------------------------------------

## Sets phase "flipped" and marks the staged top cards face_up, mirroring what
## WarEngine._flip would have produced, so a post-flip special is legal.
func _force_flipped(s: Dictionary) -> Dictionary:
	var out := s.duplicate(true)
	out["phase"] = "flipped"
	for key in ["player_pot", "cpu_pot"]:
		var pot := out.get(key, []) as Array
		if not pot.is_empty():
			(pot[pot.size() - 1] as Dictionary)["face_up"] = true
	return out


func _make_state(player_specials: Array, player_top := 5, cpu_top := 9) -> Dictionary:
	return {
		"version": 1,
		"seed": "verify-special-cards",
		"phase": "dealt",
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
		"player_pot": [],
		"cpu_pot": [],
		"rng": {"seq": 0},
		"specials": {"player": player_specials, "cpu": []},
		"pending_special": null,
		"war_depth": 0,
	}


func _total_cards(state: Dictionary) -> int:
	return (state.get("player_deck", []) as Array).size() \
		+ (state.get("cpu_deck", []) as Array).size() \
		+ (state.get("player_pot", []) as Array).size() \
		+ (state.get("cpu_pot", []) as Array).size()


# --- generic helpers --------------------------------------------------------

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
