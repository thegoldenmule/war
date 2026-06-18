@tool
class_name WarEngine
extends RefCounted

## The pure, deterministic rules engine for "War" — the heart of the skeleton
## and the definition of determinism parity. game/logic/engine.gd (GDScript) and
## validator/src/logic/engine.ts (TypeScript) MUST be byte-for-byte equivalent:
## identical canonical JSON, identical state hash, identical events, for the same
## (state, action) input.
##
## HARD WALL: zero Node / scene dependencies — headless-loadable, no presentation.
## Flow: input -> action -> logic(pure) -> NEW state + hash -> render.
##
## ENTRY POINTS:
##   new_game(seed) -> state                build + shuffle + deal a fresh match.
##   apply(state, action) -> { ok, state, events, error }
##                                          pure transition; returns a NEW state,
##                                          never mutates the input across the
##                                          hash boundary (duplicate(true)).
##   state_hash(state) -> String            WarHasher.hash_value(state).
##
## CORE LOOP / PHASE TRANSITIONS (the shared contract):
##   dealt    --start_round--> selected   (stage top card face-down on each side)
##   selected --play_special(pre_flip)--> selected (e.g. peek; resolves in place)
##   selected --flip--> flipped           (reveal; a TIE goes straight to "war")
##                  \--flip--> war        (equal ranks -> WAR, war_depth = 1)
##   flipped  --play_special(post_flip)--> flipped (e.g. rank_boost / arm steal_tie)
##   flipped  --resolve--> dealt          (award the pot to the higher rank)
##   war      --ack_war/resolve--> dealt | war  (stake WAR_STAKE+1, compare; another
##                                          tie stays "war" with war_depth++)
##   any non-terminal --(deck emptied)--> player_win | cpu_win
##
## STATE SCHEMA (synchronized + hashed; same shape in TS):
##   { version:int, seed:String, phase:String,
##     player_deck:Card[], cpu_deck:Card[],
##     player_pot:Card[], cpu_pot:Card[],
##     rng:{seq:int}, specials:{player:String[], cpu:String[]},
##     pending_special:String|null, war_depth:int }
##   Card = { rank:int(2..14), suit:String, face_up:bool }
##   Deck index 0 = TOP. Pots are append-ordered staging piles for the round.
##
## EVENTS: an ordered Array of small dicts describing what happened (for the UI
## to animate). Events are part of the deterministic output and are produced
## identically in TS, but they are NOT part of the hashed state.

const C := preload("res://logic/constants.gd")
const Rng := preload("res://logic/rng.gd")
const Hasher := preload("res://logic/hasher.gd")
const Validation := preload("res://logic/validation.gd")
const Specials := preload("res://logic/special_cards.gd")


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

static func _result(ok: bool, state: Dictionary, events: Array, error: String) -> Dictionary:
	return {"ok": ok, "state": state, "events": events, "error": error}


static func _fail(state: Dictionary, error: String) -> Dictionary:
	# On failure, return the (unchanged) input state so callers can keep going.
	return _result(false, state, [], error)


# ---------------------------------------------------------------------------
# Match construction
# ---------------------------------------------------------------------------

## Build an ordered 52-card deck (for each suit, for each rank) — all face_down.
## Order is load-bearing for determinism (must match TS).
static func _build_deck() -> Array:
	var deck: Array = []
	for suit in C.SUITS:
		for rank in C.RANKS:
			deck.append({"rank": rank, "suit": suit, "face_up": false})
	return deck


## Create a fresh match state from `seed`: build the ordered deck, deterministic
## shuffle, then deal DEAL_SIZE to the player and DEAL_SIZE to the cpu. Phase is
## "dealt" (a round may begin). pending_special is null and OMITTED from the hash
## by the canonical serializer.
static func new_game(seed: String) -> Dictionary:
	var rng: Dictionary = Rng.seed_from(seed)
	var deck: Array = _build_deck()
	var shuffled: Dictionary = Rng.shuffle(seed, deck, rng)
	deck = shuffled["array"]
	rng = shuffled["rng"]

	var player_deck: Array = deck.slice(0, C.DEAL_SIZE)
	var cpu_deck: Array = deck.slice(C.DEAL_SIZE, C.DEAL_SIZE * 2)

	return {
		"version": C.STATE_VERSION,
		"seed": seed,
		"phase": C.PHASE_DEALT,
		"player_deck": player_deck,
		"cpu_deck": cpu_deck,
		"player_pot": [],
		"cpu_pot": [],
		"rng": rng,
		"specials": {"player": [], "cpu": []},
		"pending_special": null,
		"war_depth": 0,
	}


# ---------------------------------------------------------------------------
# Pure transition
# ---------------------------------------------------------------------------

## Apply `action` to `state`, returning { ok, state, events, error }. The
## returned state is ALWAYS a new object; the input is never mutated.
static func apply(state: Dictionary, action: Dictionary) -> Dictionary:
	# new_game is special: it ignores the prior state entirely.
	if action.get("type", "") == C.ACTION_NEW_GAME:
		var seed: String = str(action.get("seed", ""))
		return _result(true, new_game(seed), [{"type": "new_game", "seed": seed}], "")

	# Phase-legality gate (shared with the validator).
	var legal: Dictionary = Validation.check(state, action)
	if not legal["ok"]:
		return _fail(state, legal["error"])

	# Work on a deep copy from here on.
	var next: Dictionary = state.duplicate(true)
	var type: String = action["type"]

	match type:
		C.ACTION_START_ROUND:
			return _start_round(next)
		C.ACTION_PLAY_SPECIAL:
			return _play_special(next, str(action["id"]))
		C.ACTION_FLIP:
			return _flip(next)
		C.ACTION_RESOLVE:
			# In a war, "resolve" advances the war exactly like ack_war.
			if str(next.get("phase", "")) == C.PHASE_WAR:
				return _ack_war(next)
			return _resolve(next)
		C.ACTION_ACK_WAR:
			return _ack_war(next)
		_:
			return _fail(state, "unknown_action")


# ---------------------------------------------------------------------------
# start_round: stage the top card of each deck into the pots (face_down)
# ---------------------------------------------------------------------------

static func _start_round(next: Dictionary) -> Dictionary:
	var pd: Array = next["player_deck"]
	var cd: Array = next["cpu_deck"]
	# Validation guarantees both decks are non-empty here.
	var p_card: Dictionary = pd.pop_front()
	var c_card: Dictionary = cd.pop_front()
	p_card["face_up"] = false
	c_card["face_up"] = false
	next["player_pot"].append(p_card)
	next["cpu_pot"].append(c_card)
	next["war_depth"] = 0
	next["pending_special"] = null
	# The flip moment: a round is staged, awaiting (optional) specials then flip.
	next["phase"] = C.PHASE_SELECTED
	var events: Array = [{"type": "round_staged"}]
	return _result(true, next, events, "")


# ---------------------------------------------------------------------------
# play_special: delegate to WarSpecialCards
# ---------------------------------------------------------------------------

static func _play_special(next: Dictionary, id: String) -> Dictionary:
	var res: Dictionary = Specials.resolve(next, id)
	if not res["ok"]:
		# special_cards returns the original (copied) state on failure.
		return _fail(next, res["error"])
	return _result(true, res["state"], res["events"], "")


# ---------------------------------------------------------------------------
# flip: reveal both staged top cards; a tie escalates immediately to WAR
# ---------------------------------------------------------------------------

static func _flip(next: Dictionary) -> Dictionary:
	var pp: Array = next["player_pot"]
	var cp: Array = next["cpu_pot"]
	(pp[pp.size() - 1] as Dictionary)["face_up"] = true
	(cp[cp.size() - 1] as Dictionary)["face_up"] = true
	var p_rank: int = int((pp[pp.size() - 1] as Dictionary)["rank"])
	var c_rank: int = int((cp[cp.size() - 1] as Dictionary)["rank"])
	var events: Array = [{
		"type": "flip",
		"player": _top_summary(pp),
		"cpu": _top_summary(cp),
	}]
	if p_rank == c_rank and str(next.get("pending_special", "")) != "steal_tie":
		# Tie -> WAR. war_depth becomes 1 (the first war level for this round).
		events.append({"type": "tie", "rank": p_rank})
		next["war_depth"] = 1
		next["phase"] = C.PHASE_WAR
	else:
		next["phase"] = C.PHASE_FLIPPED
	return _result(true, next, events, "")


# ---------------------------------------------------------------------------
# resolve: award the revealed (flipped) round to the higher rank
# ---------------------------------------------------------------------------

static func _resolve(next: Dictionary) -> Dictionary:
	var pp: Array = next["player_pot"]
	var cp: Array = next["cpu_pot"]
	var p_rank: int = int((pp[pp.size() - 1] as Dictionary)["rank"])
	var c_rank: int = int((cp[cp.size() - 1] as Dictionary)["rank"])
	var events: Array = []

	if p_rank > c_rank:
		_award_pots_to(next, "player", events)
		next["pending_special"] = null
		next["war_depth"] = 0
		return _finish_round(next, "player", events)
	elif c_rank > p_rank:
		_award_pots_to(next, "cpu", events)
		next["pending_special"] = null
		next["war_depth"] = 0
		return _finish_round(next, "cpu", events)
	else:
		# Equal ranks at resolve time: an armed "steal_tie" awards the player;
		# otherwise this escalates to a WAR. (Normally flip already routes ties to
		# war, but resolving a tie directly stays correct and deterministic.)
		if str(next.get("pending_special", "")) == "steal_tie":
			events.append({"type": "steal_tie_fired"})
			_award_pots_to(next, "player", events)
			next["pending_special"] = null
			next["war_depth"] = 0
			return _finish_round(next, "player", events)
		events.append({"type": "tie", "rank": p_rank})
		next["pending_special"] = null
		next["war_depth"] = max(1, int(next.get("war_depth", 0)))
		next["phase"] = C.PHASE_WAR
		return _result(true, next, events, "")


# ---------------------------------------------------------------------------
# ack_war: stake WAR_STAKE face-down + 1 face-up per side; compare deciders
# ---------------------------------------------------------------------------

static func _ack_war(next: Dictionary) -> Dictionary:
	var pd: Array = next["player_deck"]
	var cd: Array = next["cpu_deck"]

	# A player who cannot complete a war (insufficient cards) loses immediately.
	# A war needs WAR_STAKE face-down + 1 face-up = WAR_STAKE + 1 cards. If a side
	# has fewer than that, it forfeits; if BOTH are short, the side with strictly
	# more cards wins (a tie on count resolves to cpu for determinism).
	var need: int = C.WAR_STAKE + 1
	var p_short: bool = pd.size() < need
	var c_short: bool = cd.size() < need
	var events: Array = []
	if p_short or c_short:
		var winner: String
		if p_short and c_short:
			winner = "player" if pd.size() > cd.size() else "cpu"
		elif p_short:
			winner = "cpu"
		else:
			winner = "player"
		events.append({"type": "war_forfeit", "winner": winner})
		_award_pots_to(next, winner, events)
		next["pending_special"] = null
		next["war_depth"] = 0
		# Forfeit ends the match in the winner's favor (the loser cannot continue).
		next["phase"] = C.PHASE_PLAYER_WIN if winner == "player" else C.PHASE_CPU_WIN
		events.append({"type": "game_over", "winner": winner})
		return _result(true, next, events, "")

	# Stake WAR_STAKE face-down cards from each deck into each pot. The staked cards are
	# ALSO collected (as {rank,suit} summaries) for the war_decide event so the reveal UI
	# can flip them face-up — presentation metadata only; it rides the (un-hashed) events,
	# never the state, so the canonical JSON / hash is unchanged.
	var p_cards: Array = []
	var c_cards: Array = []
	for _i in range(C.WAR_STAKE):
		var pfd: Dictionary = pd.pop_front()
		var cfd: Dictionary = cd.pop_front()
		pfd["face_up"] = false
		cfd["face_up"] = false
		next["player_pot"].append(pfd)
		next["cpu_pot"].append(cfd)
		p_cards.append(_card_summary(pfd))
		c_cards.append(_card_summary(cfd))

	# Stake the deciding face-up card from each deck (appended LAST, so it is the final
	# element of each *_cards array — the decider the reveal flips for the win).
	var p_dec: Dictionary = pd.pop_front()
	var c_dec: Dictionary = cd.pop_front()
	p_dec["face_up"] = true
	c_dec["face_up"] = true
	next["player_pot"].append(p_dec)
	next["cpu_pot"].append(c_dec)
	p_cards.append(_card_summary(p_dec))
	c_cards.append(_card_summary(c_dec))
	next["war_depth"] = int(next.get("war_depth", 0)) + 1

	var p_rank: int = int(p_dec["rank"])
	var c_rank: int = int(c_dec["rank"])
	events.append({
		"type": "war_decide",
		"depth": next["war_depth"],
		"player": p_rank,
		"cpu": c_rank,
		"player_cards": p_cards,
		"cpu_cards": c_cards,
	})

	if p_rank > c_rank:
		_award_pots_to(next, "player", events)
		next["pending_special"] = null
		next["war_depth"] = 0
		return _finish_round(next, "player", events)
	elif c_rank > p_rank:
		_award_pots_to(next, "cpu", events)
		next["pending_special"] = null
		next["war_depth"] = 0
		return _finish_round(next, "cpu", events)
	else:
		# Another tie — stay in WAR (war_depth already incremented).
		events.append({"type": "tie", "rank": p_rank})
		next["phase"] = C.PHASE_WAR
		return _result(true, next, events, "")


# ---------------------------------------------------------------------------
# Award / round-finish helpers
# ---------------------------------------------------------------------------

## Move BOTH pots to the bottom of `winner`'s deck (winner's pot first, then the
## loser's pot — a fixed order for determinism), face_down. Clears both pots.
static func _award_pots_to(next: Dictionary, winner: String, events: Array) -> void:
	var winner_deck: Array = next["player_deck"] if winner == "player" else next["cpu_deck"]
	var won: int = 0
	for card in next["player_pot"]:
		(card as Dictionary)["face_up"] = false
		winner_deck.append(card)
		won += 1
	for card in next["cpu_pot"]:
		(card as Dictionary)["face_up"] = false
		winner_deck.append(card)
		won += 1
	next["player_pot"] = []
	next["cpu_pot"] = []
	events.append({"type": "award", "winner": winner, "cards": won})


## After awarding, set the resting phase and check for a terminal win.
static func _finish_round(next: Dictionary, _winner: String, events: Array) -> Dictionary:
	next["phase"] = C.PHASE_DEALT
	return _check_win(next, events)


## Detect a terminal state: one side holds all DECK_SIZE cards (other empty).
static func _check_win(next: Dictionary, events: Array) -> Dictionary:
	var p: int = (next["player_deck"] as Array).size()
	var c: int = (next["cpu_deck"] as Array).size()
	if c == 0 and p > 0:
		next["phase"] = C.PHASE_PLAYER_WIN
		events.append({"type": "game_over", "winner": "player"})
	elif p == 0 and c > 0:
		next["phase"] = C.PHASE_CPU_WIN
		events.append({"type": "game_over", "winner": "cpu"})
	return _result(true, next, events, "")


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

## A compact {rank, suit} summary of a pot's top card (for events).
static func _top_summary(pot: Array) -> Dictionary:
	if pot.is_empty():
		return {}
	var top: Dictionary = pot[pot.size() - 1]
	return {"rank": top.get("rank"), "suit": top.get("suit")}


## A {rank,suit} summary of a single card — for presentation-only event payloads (e.g. the
## war_decide staked cards the reveal UI flips). Mirrors _top_summary's shape.
static func _card_summary(card: Dictionary) -> Dictionary:
	return {"rank": card.get("rank"), "suit": card.get("suit")}


# ---------------------------------------------------------------------------
# Determinism hash
# ---------------------------------------------------------------------------

## The canonical state hash (64 lowercase hex chars). Identical in TS.
static func state_hash(state: Dictionary) -> String:
	return Hasher.hash_value(state)
