@tool
class_name WarActions
extends RefCounted

## Factory helpers + shape validation for the unified action Dictionaries that
## drive the engine (WarEngine.apply). Both player and CPU input flow through
## these same action shapes.
##
## ACTION SCHEMA: { type:String, ...args }. The factories below produce the
## canonical shape for each type; `validate_shape` checks structural validity
## (correct type token + required args of the right Variant type) WITHOUT
## inspecting game state — phase-legality lives in WarValidation.
##
## These shapes are part of the wire contract: actions travel to the validator
## as canonical-JSON strings, so the field names / types here must match the
## TypeScript actions.ts exactly.
##
## Pure static utility — zero Node / scene dependencies, headless-loadable.

const C := preload("res://logic/constants.gd")


# ---------------------------------------------------------------------------
# Factories
# ---------------------------------------------------------------------------

## Start a fresh match with the given deterministic seed string.
static func new_game(seed: String) -> Dictionary:
	return {"type": C.ACTION_NEW_GAME, "seed": seed}


## Begin a round: deal the next top card face-down on each side, opening the
## pre-flip window. No args.
static func start_round() -> Dictionary:
	return {"type": C.ACTION_START_ROUND}


## Queue / play a special card by catalog id (e.g. "peek", "rank_boost").
static func play_special(id: String) -> Dictionary:
	return {"type": C.ACTION_PLAY_SPECIAL, "id": id}


## Reveal both staged top cards (face_up = true). No args.
static func flip() -> Dictionary:
	return {"type": C.ACTION_FLIP}


## Resolve the revealed round: compare ranks, award the pot, or detect a tie and
## transition into WAR. No args.
static func resolve() -> Dictionary:
	return {"type": C.ACTION_RESOLVE}


## Acknowledge / advance a WAR: stake WAR_STAKE face-down cards + 1 face-up on
## each side, then compare the deciding cards. No args.
static func ack_war() -> Dictionary:
	return {"type": C.ACTION_ACK_WAR}


# ---------------------------------------------------------------------------
# Shape validation
# ---------------------------------------------------------------------------

## Structural validity of an action Dictionary: a known `type` token plus the
## required args present with the correct Variant types. Does NOT consult game
## state (use WarValidation.validate for phase-legality). Returns bool.
static func validate_shape(action) -> bool:
	if not (action is Dictionary):
		return false
	if not action.has("type"):
		return false
	var t = action["type"]
	if not (t is String):
		return false
	match t:
		C.ACTION_NEW_GAME:
			return action.has("seed") and action["seed"] is String
		C.ACTION_PLAY_SPECIAL:
			return action.has("id") and action["id"] is String and C.SPECIAL_CARDS.has(action["id"])
		C.ACTION_START_ROUND, C.ACTION_FLIP, C.ACTION_RESOLVE, C.ACTION_ACK_WAR:
			# No required args beyond the type token.
			return true
		_:
			return false
