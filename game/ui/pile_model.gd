class_name WarPileModel
extends RefCounted
##
## WarPileModel — the COSMETIC 3-pile model for the table view: drawing deck /
## current card / win deck, per player. PRESENTATION ONLY — it never touches the
## hashed state and is a pure static utility (headless-testable, no Node deps).
##
## Why it is cosmetic
## ------------------
## The deterministic engine has NO separate "win pile": on a win it appends both
## pots to the BOTTOM of the winner's deck (player_deck / cpu_deck), and those won
## cards are re-drawn later. So a visible win pile is a presentation accumulator:
##   - `won[p]` grows by an award's card count (accrue),
##   - and is CLAMPED to the live deck size after every state (clamp_to). The clamp
##     models the "recycle" — when won cards are drawn again, the deck shrinks and
##     the win count ticks back down so it can never exceed what is actually held.
## Then `draw_shown[p] = deck_size[p] - won_clamped[p]`, so draw + win == deck for
## each side and the on-screen total always conserves the 52-card deck (pots, while
## staked, live in the current-card slots).
##
## Reset (new match) is the VIEW's job via a phase transition, because the Round
## Director drops the new_game event from its resting-beat payload; accrue() still
## honors a new_game event defensively if one is ever delivered.

## A fresh accumulator: no cards won yet.
static func empty() -> Dictionary:
	return {"player": 0, "cpu": 0}


## Apply ONE apply's engine events to the won accumulator, returning a NEW dict.
## Adds an award's `cards` to its `winner`. A war_forfeit carries a winner but NO
## card count (its paired award in the same apply carries the count), so we accrue
## on `award` only — accruing on both would double-count. A new_game event resets.
##
## IMPORTANT: call this ONCE per apply. The Director passes the same buffered
## events to every beat in a chain (e.g. a war win emits both WAR_REVEALING and
## ROUND_RESULT carrying [war_decide, award]); the view must therefore accrue on a
## single designated beat (ROUND_RESULT / GAME_OVER), not on every award-bearing beat.
static func accrue(won: Dictionary, events: Array) -> Dictionary:
	var out := {"player": int(won.get("player", 0)), "cpu": int(won.get("cpu", 0))}
	for ev in events:
		var t := String((ev as Dictionary).get("type", ""))
		if t == "new_game":
			out = {"player": 0, "cpu": 0}
		elif t == "award":
			var w := String((ev as Dictionary).get("winner", ""))
			if out.has(w):
				out[w] = int(out[w]) + int((ev as Dictionary).get("cards", 0))
	return out


## The accumulator clamped to the live deck sizes. Internal helper for recycle().
static func clamp_to(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	return {
		"player": clampi(int(won.get("player", 0)), 0, maxi(0, pdeck)),
		"cpu": clampi(int(won.get("cpu", 0)), 0, maxi(0, cdeck)),
	}


## The accumulator after a RECYCLE: when a side's win pile SATURATES its deck
## (won >= deck > 0 — the drawing deck has run dry and the engine is drawing recycled
## cards), the win pile flips over to become the new drawing deck, so won resets to 0
## (draw -> full deck). Pure + idempotent; preserves draw + win == deck. Keep the view's
## `_won` pinned to this so a reconcile snap self-corrects.
static func recycle(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	var c := clamp_to(won, pdeck, cdeck)
	return {
		"player": 0 if (pdeck > 0 and int(c["player"]) >= pdeck) else int(c["player"]),
		"cpu": 0 if (cdeck > 0 and int(c["cpu"]) >= cdeck) else int(c["cpu"]),
	}


## Which sides WOULD recycle at these (won, deck) — for edge-detecting the recycle
## animation. Pure: true iff the (clamped) win pile saturates a non-empty deck.
static func recycled_sides(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	var c := clamp_to(won, pdeck, cdeck)
	return {
		"player": pdeck > 0 and int(c["player"]) >= pdeck,
		"cpu": cdeck > 0 and int(c["cpu"]) >= cdeck,
	}


## Derive the per-player draw/win counts from the accumulator and the live deck sizes
## (after recycle): { player:{draw,win}, cpu:{draw,win} }, with draw + win == deck per
## side. After a recycle a saturated win pile reads as a full draw pile (win 0).
static func counts(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	var c := recycle(won, pdeck, cdeck)
	var wp: int = c["player"]
	var wc: int = c["cpu"]
	return {
		"player": {"draw": maxi(0, pdeck) - wp, "win": wp},
		"cpu": {"draw": maxi(0, cdeck) - wc, "win": wc},
	}
