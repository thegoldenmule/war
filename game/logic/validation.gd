@tool
class_name WarValidation
extends RefCounted

## Phase-legality validation: given a state and an action, is the action legal
## RIGHT NOW? Used by both the client (to gate input / predict) and the
## validator-side logic (authoritative re-check). Must be byte-for-byte
## equivalent to the TypeScript validation.ts so client and server never
## disagree about legality.
##
## ENTRY POINTS (the engine and verifiers call these):
##   check(state, action)    -> { ok:bool, error:String }   (canonical shape)
##   is_legal(state, action) -> { ok:bool, error:String }   (alias of check)
##   validate(state, action) -> { ok:bool, error:String }   (alias of check)
##
## PHASE TABLE (the shared contract):
##   "dealt"     -> start_round legal; flip/resolve/ack_war illegal.
##   "selected"  -> flip legal, play_special(pre_flip) legal; start_round/resolve illegal.
##   "flipped"   -> resolve legal, play_special(post_flip) legal; flip/start_round illegal.
##   "war"       -> ack_war legal, resolve legal, play_special(post_flip) legal; start_round illegal.
##   terminal (player_win / cpu_win) -> only new_game legal.
##   new_game    -> always legal (discards any prior state).
##
## Legality here is purely about PHASE + action shape + ownership; it does NOT
## require pots to be pre-staged (deck-depth feasibility is the engine's concern,
## except that start_round refuses an empty deck).
##
## Pure static utility — zero Node / scene dependencies, headless-loadable.

const C := preload("res://logic/constants.gd")
const Actions := preload("res://logic/actions.gd")


static func _ok() -> Dictionary:
	return {"ok": true, "error": ""}


static func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Canonical entry point. Returns {ok, error}.
static func check(state, action) -> Dictionary:
	if not (state is Dictionary):
		return _err("state_not_dict")
	if not Actions.validate_shape(action):
		return _err("malformed_action")

	var type: String = action["type"]
	var phase: String = str(state.get("phase", ""))

	# new_game is always legal (it discards any prior state).
	if type == C.ACTION_NEW_GAME:
		return _ok()

	# No action other than new_game is legal once a side has won.
	if phase == C.PHASE_PLAYER_WIN or phase == C.PHASE_CPU_WIN:
		return _err("game_over")

	match type:
		C.ACTION_START_ROUND:
			if phase != C.PHASE_DEALT:
				return _err("start_round_wrong_phase")
			if _deck_empty(state, "player_deck") or _deck_empty(state, "cpu_deck"):
				return _err("start_round_empty_deck")
			return _ok()

		C.ACTION_PLAY_SPECIAL:
			var id: String = action["id"]
			if not C.SPECIAL_CARDS.has(id):
				return _err("unknown_special")
			if not _player_owns_special(state, id):
				return _err("special_not_owned")
			if state.get("pending_special", null) != null:
				return _err("special_already_pending")
			var when: String = str(C.SPECIAL_CARDS[id]["when"])
			if when == C.WHEN_PRE_FLIP:
				# Pre-flip specials fire during the flip moment (round staged but
				# not yet revealed): phase "dealt" (about to stage) or "selected".
				if phase != C.PHASE_DEALT and phase != C.PHASE_SELECTED:
					return _err("pre_flip_wrong_phase")
			else:
				# Post-flip specials fire after reveal: "flipped" or during a "war".
				if phase != C.PHASE_FLIPPED and phase != C.PHASE_WAR:
					return _err("post_flip_wrong_phase")
			return _ok()

		C.ACTION_FLIP:
			# Reveal is legal only at the flip moment, i.e. phase "selected".
			if phase != C.PHASE_SELECTED:
				return _err("flip_wrong_phase")
			return _ok()

		C.ACTION_RESOLVE:
			# Resolve awards a revealed round; legal once flipped or mid-war.
			if phase != C.PHASE_FLIPPED and phase != C.PHASE_WAR:
				return _err("resolve_wrong_phase")
			return _ok()

		C.ACTION_ACK_WAR:
			if phase != C.PHASE_WAR:
				return _err("ack_war_wrong_phase")
			return _ok()

		_:
			return _err("unknown_action")


## Alias of check() — some call sites/tests use is_legal().
static func is_legal(state, action) -> Dictionary:
	return check(state, action)


## Alias of check() — kept for callers that spell it validate().
static func validate(state, action) -> Dictionary:
	return check(state, action)


# ---------------------------------------------------------------------------
# Predicate helpers (state shape introspection)
# ---------------------------------------------------------------------------

static func _deck_empty(state: Dictionary, key: String) -> bool:
	var deck = state.get(key, [])
	return not (deck is Array) or (deck as Array).is_empty()


## Does the player own the special with this id (it is in specials.player)?
static func _player_owns_special(state: Dictionary, id: String) -> bool:
	var specials = state.get("specials", {})
	if not (specials is Dictionary):
		return false
	var owned = (specials as Dictionary).get("player", [])
	return owned is Array and (owned as Array).has(id)
