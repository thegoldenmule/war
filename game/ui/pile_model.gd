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


## The accumulator clamped to the live deck sizes (the recycle write-back). Keep
## the view's `_won` pinned to this so a reconcile snap self-corrects.
static func clamp_to(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	return {
		"player": clampi(int(won.get("player", 0)), 0, maxi(0, pdeck)),
		"cpu": clampi(int(won.get("cpu", 0)), 0, maxi(0, cdeck)),
	}


## Clamp + derive the per-player draw/win counts from the accumulator and the live
## deck sizes: { player:{draw,win}, cpu:{draw,win} }, with draw + win == deck per side.
static func counts(won: Dictionary, pdeck: int, cdeck: int) -> Dictionary:
	var c := clamp_to(won, pdeck, cdeck)
	var wp: int = c["player"]
	var wc: int = c["cpu"]
	return {
		"player": {"draw": maxi(0, pdeck) - wp, "win": wp},
		"cpu": {"draw": maxi(0, cdeck) - wc, "win": wc},
	}
