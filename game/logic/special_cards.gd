@tool
class_name WarSpecialCards
extends RefCounted

## Resolution of collectible Special Cards (the Balatro-style monetization hook).
## Effects are validator-authoritative and resolve INSIDE the deterministic
## engine, so this logic must be byte-for-byte equivalent to the TypeScript
## special_cards.ts.
##
## resolve(state, special_id) -> { ok:bool, state:Dictionary, events:Array, error:String }
##   Applies `special_id`'s effect to a COPY of `state` (never mutates the input
##   across the hash boundary) and consumes the card from specials.player.
##
## Two kinds of effect, by catalog `when`:
##   pre_flip  — resolves immediately and fully here (e.g. "peek" reveals the
##               player's staged card early). pending_special is cleared.
##   post_flip — may need cooperation from the engine's resolve step. Such cards
##               set state.pending_special = id so WarEngine.apply(resolve)/(ack_war)
##               can read and consume it; any immediate sub-effect is applied here.
##
## EXTENSION POINT: add a new branch to `_apply` keyed on the catalog id, add the
## id to WarConstants.SPECIAL_CARDS, and (if post_flip) teach WarEngine.resolve to
## honor it. Keep GDScript and TS in lockstep.
##
## Pure static utility — zero Node / scene dependencies, headless-loadable.

const C := preload("res://logic/constants.gd")


static func _result(ok: bool, state: Dictionary, events: Array, error: String) -> Dictionary:
	return {"ok": ok, "state": state, "events": events, "error": error}


# ---------------------------------------------------------------------------
# Catalog accessors (the engine/validator/UI discover specials through these)
# ---------------------------------------------------------------------------

## All collectible special-card ids, in catalog declaration order.
static func ids() -> Array:
	return C.SPECIAL_CARD_IDS.duplicate()


## The full id -> {name, when, desc} catalog Dictionary.
static func catalog() -> Dictionary:
	return C.SPECIAL_CARDS.duplicate(true)


## Is `id` a known, implementable special-card id?
static func is_valid_id(id) -> bool:
	return id is String and C.SPECIAL_CARDS.has(id)


## Resolve `special_id` against `state`. Caller (WarEngine) is responsible for
## phase/ownership legality (WarValidation); this re-checks the catalog only.
static func resolve(state: Dictionary, special_id: String) -> Dictionary:
	if not C.SPECIAL_CARDS.has(special_id):
		return _result(false, state, [], "unknown_special")

	# Operate on a deep copy so the input is never mutated across the hash boundary.
	var next: Dictionary = state.duplicate(true)
	var events: Array = []

	# Consume the card from the player's owned list (first matching occurrence).
	if not _consume_owned(next, special_id):
		return _result(false, state, [], "special_not_owned")

	return _apply(next, special_id, events)


## Per-id effect dispatch. Each branch returns the standard result dict.
static func _apply(next: Dictionary, special_id: String, events: Array) -> Dictionary:
	match special_id:
		"peek":
			# Pre-flip information: reveal the player's staged top card early by
			# flipping it face_up. Deck order is untouched; resolves fully now.
			var pot = next.get("player_pot", [])
			if not (pot is Array) or (pot as Array).is_empty():
				return _result(false, next, [], "peek_no_card")
			var top: Dictionary = (pot[(pot as Array).size() - 1] as Dictionary)
			top["face_up"] = true
			var seen := {"rank": top.get("rank"), "suit": top.get("suit")}
			events.append({"type": "special_peek", "card": seen})
			# Pre-flip specials resolve fully in place and leave no pending marker;
			# the phase stays "selected" (the flip moment) so the player can still
			# flip afterward.
			next["pending_special"] = null
			return _result(true, next, events, "")

		"rank_boost":
			# Post-flip: +2 to the player's revealed card rank for THIS round's
			# comparison. The card is consumed this round, so we mutate its rank
			# in-pot directly (transient by lifetime). Clamp at RANK_MAX so an Ace
			# cannot exceed the legal rank domain.
			var pot2 = next.get("player_pot", [])
			if not (pot2 is Array) or (pot2 as Array).is_empty():
				return _result(false, next, [], "rank_boost_no_card")
			var card: Dictionary = (pot2[(pot2 as Array).size() - 1] as Dictionary)
			var old_rank: int = int(card.get("rank", C.RANK_MIN))
			var new_rank: int = min(old_rank + 2, C.RANK_MAX)
			card["rank"] = new_rank
			events.append({"type": "special_rank_boost", "from": old_rank, "to": new_rank})
			# No engine cooperation needed beyond the mutated rank; clear pending.
			next["pending_special"] = null
			return _result(true, next, events, "")

		"steal_tie":
			# Post-flip: if this round ties, the player takes the pot instead of a
			# WAR. This needs the engine's resolve step to honor it, so we leave a
			# pending marker the engine reads at resolution time.
			next["pending_special"] = "steal_tie"
			events.append({"type": "special_steal_tie_armed"})
			return _result(true, next, events, "")

		_:
			# EXTENSION POINT: implement additional specials here.
			# TODO(skeleton): wire deeper effects (e.g. deck manipulation, multi-round buffs).
			return _result(false, next, [], "special_not_implemented")


## Remove the first occurrence of `id` from state.specials.player. Returns true
## if a card was removed.
static func _consume_owned(state: Dictionary, id: String) -> bool:
	var specials = state.get("specials", {})
	if not (specials is Dictionary):
		return false
	var owned = (specials as Dictionary).get("player", [])
	if not (owned is Array):
		return false
	var idx: int = (owned as Array).find(id)
	if idx < 0:
		return false
	(owned as Array).remove_at(idx)
	return true
