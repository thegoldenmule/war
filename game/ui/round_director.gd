class_name WarRoundDirector
extends Node
##
## WarRoundDirector — the presentation-tier PLAY SEQUENCER for War.
##
## Position in the stack (strictly one-way beneath the HARD WALL):
##   table.gd (VIEW, render-only)
##      └── WarRoundDirector (this — paces legal transitions into beats)
##             └── WarMatch  (FUNNEL — optimistic apply + reconcile; unchanged)
##                    └── WarEngine (pure rules)  <->  Validator (authoritative)
##
## What it does
## ------------
## The engine exposes discrete LEGAL transitions; this Node turns them into a
## playable match by auto-advancing the mechanical actions the player should
## never tap (`start_round`, `resolve`) on timed *beats*, and pausing for the
## player only at the two signature decision points: the **flip moment**
## (phase "selected") and the **WAR ack** (phase "war"; deep runaway wars
## auto-advance). It owns NO authoritative state — only a cosmetic `_beat`
## derived from the engine phase, a single armed timer, and the last apply's
## buffered events. A validator reconcile therefore snaps cleanly: `_on_state`
## re-derives the beat from the authoritative state.
##
## Zero authority (the north star)
## -------------------------------
## The Director only chooses WHICH legal action to submit and WHEN. The auto
## actions (`start_round`, `resolve`, and a deep-war `ack_war`) are deterministic
## and phase-legal, so the validator re-runs an identical action stream and every
## existing determinism + reconcile guarantee carries over unchanged. Tempo is
## pure presentation: the constants below change only WHEN an auto-action fires,
## never WHICH — so the 64-hex hashes are identical at any speed.
##
## Reconcile safety
## ----------------
## Connect ONLY `state_changed` -> `_on_state` (the single re-derive entry).
## WarMatch's reconcile re-emits `state_changed` AND THEN `reconciled`; binding
## `reconciled` to the same handler would run `_on_state` twice per snap. Because
## the beat is a pure function of phase and `_on_state` cancels the pending timer
## before re-deriving, a mid-animation snap cannot double-apply an action or
## strand a phantom beat — worst case is a skipped animation.
##
## Transient beats and the event/state ordering trap
## -------------------------------------------------
## ROUND_RESULT / WAR_BANNER / WAR_REVEALING are NOT engine phases. WarMatch emits
## engine events BEFORE `state_changed`, and an award/tie/decide returns the phase
## to dealt/war in the SAME apply — so a naive "emit a transient in `_on_event`,
## re-derive in `_on_state`" overwrites it instantly. The fix: `_on_event` only
## BUFFERS the apply's events, and `_on_state` decides, in ONE place, the ordered
## chain of transient holds to play (on the single armed timer) BEFORE arming the
## resting beat's auto-action. Because the engine bundles `war_decide` together
## with the `award`/`tie` of the same apply, WAR_REVEALING is CHAINED ahead of the
## following ROUND_RESULT/WAR_BANNER rather than chosen instead of it.

## Re-render the table from this authoritative snapshot (pure presentation).
signal view_state(state: Dictionary)
## The cosmetic beat changed — animate it and lock/unlock input from `locked`.
## `events` are the engine events of the apply that produced this beat (for the
## view to animate); empty for a resting beat with no events.
signal beat(name: int, events: Array, locked: bool)

## Cosmetic beats — pacing only, distinct from the engine phase (the truth).
enum Beat {
	BOOT,           # before the first deal
	DEAL_PROMPT,    # phase "dealt"    — AWAIT: request_deal_and_flip (one tap draws + flips)
	DRAWING,        # transient        — a card flies from each deck into the current slots
	FLIP_MOMENT,    # phase "selected" — basic: auto-flip; special window: await flip/special
	REVEALING,      # phase "flipped"  — auto: play reveal, then submit resolve
	ROUND_RESULT,   # transient        — hold winner highlight, then next round
	WAR_BANNER,     # transient        — "I. DECLARE. WAR." on entering a tie
	WAR_PROMPT,     # phase "war"      — await: request_declare_war
	WAR_REVEALING,  # transient        — stake 3-down + 1-up, reveal the deciders
	GAME_OVER,      # phase player_win / cpu_win
}

# --- Tempo profile (presentation-only; never affects the hash) --------------
# Drive EVERY auto-beat through `_dur()` — no literal durations elsewhere. The
# reveal tail is `_dur("flip") + _dur("read")`. These change WHEN an auto-action
# fires, never WHICH, so the parity/hash domain is untouched by any value here.
const TEMPO := {
	"stage": 0.22,       # DRAWING: draw-in flight from each deck into the current slots
	"flip": 0.30,        # REVEALING: card-flip animation
	"read": 0.35,        # REVEALING tail: dwell on revealed faces, then submit resolve
	"result": 0.90,      # ROUND_RESULT: winner highlight + deck-delta hold
	"war_banner": 1.10,  # WAR_BANNER: "I. DECLARE. WAR." before the prompt
	"war_stake": 0.45,   # WAR_REVEALING: stake 3-down + 1-up, then reveal deciders
}
## Global multiplier scaling the whole profile (fast mode / accessibility).
const SPEED := 1.0
## Each extra war level multiplies war beats by this...
const WAR_DECAY := 0.6
## ...clamped so deep wars stay readable, not instant.
const WAR_MIN_SCALE := 0.30
## war_depth > this: stop prompting and auto-submit ack_war after a quick banner.
const WAR_AUTO_DEPTH := 3

## The funnel this Director paces. Created in `_ready` (offline by default).
var _match: WarMatch = null
## The current cosmetic beat (one of Beat.*).
var _beat: int = Beat.BOOT
## The single armed timer carrying the current hold / auto-action, and its
## callback. One timer at a time keeps tap-to-skip and reconcile-cancel uniform.
var _pending: SceneTreeTimer = null
var _pending_cb: Callable = Callable()
## Events of the most-recent apply, buffered by `_on_event`, consumed by `_on_state`.
var _last_events: Array = []
## The staged round's specials, captured in `_on_state` so `_has_preflip_special()`
## can gate the FLIP_MOMENT auto-flip. Always empty in the basic loop.
var _specials_player: Array = []
var _pending_special: Variant = null
## Optional fixed seed for the OPENING deal. Empty -> a fresh local seed each
## match (the offline default). Set before the Director enters the tree to make a
## deterministic deal (used by verifiers; the Phase B seam for a server seed).
var boot_seed: String = ""


func _ready() -> void:
	_match = WarMatch.new()
	_match.name = "WarMatch"
	add_child(_match)
	# Connect state_changed ONCE as the re-derive entry. Do NOT also bind
	# `reconciled` here — WarMatch's reconcile already re-emits state_changed, so
	# binding both would run `_on_state` twice per snap.
	_match.state_changed.connect(_on_state)
	_match.event.connect(_on_event)
	_match.action_rejected.connect(_on_rejected)
	_match.new_game(_initial_seed())   # offline default; Phase B inits online first


# ---------------------------------------------------------------------------
# Player intents (called by the view). Each is gated to the awaited beat so an
# intent fired during an animation/transient is simply dropped — never queued.
# ---------------------------------------------------------------------------

## The signature tap each round: at DEAL_PROMPT (phase "dealt") the player commits to
## the round. Submits start_round; the resulting "selected" state chains the DRAWING
## draw-in then auto-flips (basic loop), so one tap visibly draws AND flips.
func request_deal_and_flip() -> void:
	_intent(WarActions.start_round(), Beat.DEAL_PROMPT)


## Flip after the draw. Only reachable when FLIP_MOMENT AWAITS — i.e. a pre-flip
## special is available (the special window); in the basic loop FLIP_MOMENT auto-flips.
func request_flip() -> void:
	_intent(WarActions.flip(), Beat.FLIP_MOMENT)


func request_special(id: String) -> void:
	# play_special is beat-legal at the flip moment; the ENGINE decides ownership
	# and timing. NOTE: "peek" (the only pre-flip special) does NOT set
	# pending_special — it clears it; the engine stays in "selected", so the
	# resulting state_changed re-derives FLIP_MOMENT and the Director keeps
	# awaiting the flip. Do not advance the beat here.
	_intent(WarActions.play_special(id), Beat.FLIP_MOMENT)


func request_declare_war() -> void:
	_intent(WarActions.ack_war(), Beat.WAR_PROMPT)


## Deal a brand-new match (offline self-generates a fresh seed). Restarts at DEAL_PROMPT.
func request_play_again() -> void:
	_match.new_game(_fresh_seed())


## Leave the match: record it for the meta layer and route home. The meta/router
## autoloads are resolved through the tree (not as compile-time globals) so this
## Node still compiles in a headless `--script` run, where autoloads are absent.
func request_quit() -> void:
	var gs := get_node_or_null(^"/root/GameState")
	if gs != null:
		gs.record_match_played()
	var router := get_node_or_null(^"/root/UiRouter")
	if router != null:
		router.goto("home")


## Tap-to-skip: fire the armed transient/auto-action NOW. A no-op at the decision
## beats (so the player's only choice is never auto-skipped) — changes WHEN, never
## WHICH, so it is determinism-neutral.
func request_skip() -> void:
	if _pending_cb.is_valid() and not _is_decision_beat(_beat):
		var cb := _pending_cb
		_arm(null)
		cb.call()


## Submit `action` only when the current beat matches the awaited one. Dropping a
## mis-timed intent here means it never reaches WarMatch (no action_rejected); an
## engine-illegal-but-beat-legal action (e.g. an unowned special) DOES reach the
## funnel and the engine rejects it.
func _intent(action: Dictionary, awaited: int) -> void:
	if _beat == awaited:
		_match.submit_action(action)


func _on_rejected(action: Dictionary, error: String) -> void:
	# Illegal per the pure engine; local state is unchanged, so stay put.
	push_warning("[Director] rejected %s: %s" % [action, error])


# ---------------------------------------------------------------------------
# Reconcile-safe driver with event-GATED transient holds.
# ---------------------------------------------------------------------------

func _on_event(ev: Dictionary) -> void:
	_last_events.append(ev)   # buffer only; never emit a beat here


## The single re-render + re-derive entry. A normal apply and a reconcile snap
## both arrive here (via state_changed), so the loop is always reconstructable
## from authoritative state.
func _on_state(state: Dictionary) -> void:
	_arm(null)                       # cancel any pending beat timer
	var events: Array = _last_events
	_last_events = []
	var phase := String(state.get("phase", ""))
	var depth := int(state.get("war_depth", 0))
	# Capture the staged round's specials BEFORE deriving, so `_has_preflip_special()`
	# can gate the FLIP_MOMENT auto-flip when `_enter_resting` runs (now or after a chain).
	_specials_player = (state.get("specials", {}) as Dictionary).get("player", [])
	_pending_special = state.get("pending_special", null)
	var resting := beat_for_phase(phase)
	view_state.emit(state)
	if resting == Beat.GAME_OVER:
		# Terminal short-circuit: a terminal apply routes STRAIGHT to GAME_OVER with no
		# transient hold (per the spec's "terminal award short-circuits ... with no
		# stranded ROUND_RESULT"). DELIBERATE EDGE CASE: when the match is WON on a war's
		# deciding card the apply is [war_decide, award, game_over], so this skips the
		# WAR_REVEALING stake-reveal and jumps to the win banner. That is presentation-only
		# (zero authority — the engine already produced the terminal phase) and the detailed
		# war animation is owned by the I-Declare-War Moment feature; flagged for product
		# review (see the brief's open question on the game-winning-war reveal).
		_emit(Beat.GAME_OVER, events, false)
		return
	# Play the ordered transient holds implied by this apply, THEN the resting beat.
	_play_chain(transient_chain(events, resting), events, resting, depth)


## Play `chain` (an ordered list of transient Beat.*) on the single armed timer,
## each locked, then settle into the resting beat. Re-entrant via the timer; a
## reconcile mid-chain cancels it through `_on_state`'s `_arm(null)`.
func _play_chain(chain: Array, events: Array, resting: int, depth: int) -> void:
	if chain.is_empty():
		_enter_resting(resting, depth)
		return
	var head: int = chain.pop_front()
	_emit(head, events, true)        # show the transient, input locked
	_arm(_transient_dur(head, depth), func() -> void: _play_chain(chain, events, resting, depth))


## Enter the resting beat for a phase: emit it (locked unless it awaits the player)
## and arm its auto-action if it has one. DEAL_PROMPT / shallow WAR_PROMPT / GAME_OVER
## await a tap. FLIP_MOMENT auto-flips in the basic loop, but AWAITS (unlocked) when a
## pre-flip special is available — the Special Cards seam.
func _enter_resting(resting: int, depth: int) -> void:
	# FLIP_MOMENT is unlocked ONLY on the special-window path; otherwise it is a locked
	# auto beat. Every other beat's lock follows the static decision-beat predicate.
	var locked := not _is_decision_beat(resting)
	if resting == Beat.FLIP_MOMENT:
		locked = not _has_preflip_special()
	elif resting == Beat.WAR_PROMPT and depth > WAR_AUTO_DEPTH and can_auto_ack():
		# A runaway war auto-advances — present it as an auto beat (button disabled,
		# skip-catcher shown), not an awaited DECLARE WAR prompt.
		locked = true
	_emit(resting, [], locked)
	match resting:
		Beat.FLIP_MOMENT:
			if _has_preflip_special():
				_arm(null)                                   # await request_flip / request_special
			else:
				_arm(_dur("flip"), func() -> void: _match.submit_action(WarActions.flip()))
		Beat.REVEALING:
			_arm(_dur("flip") + _dur("read"), func() -> void: _match.submit_action(WarActions.resolve()))
		Beat.WAR_PROMPT:
			if depth > WAR_AUTO_DEPTH and can_auto_ack():   # runaway war auto-advances
				_arm(_dur("war_banner", depth), func() -> void: _match.submit_action(WarActions.ack_war()))
			else:
				_arm(null)                                   # await request_declare_war
		_:
			_arm(null)                                       # DEAL_PROMPT / GAME_OVER: await intent


func _emit(b: int, events: Array, locked: bool) -> void:
	_beat = b
	beat.emit(b, events, locked)


## Arm (or cancel, with `seconds == null`) the single pending timer. Guards the
## disconnect so a just-fired timer is not double-disconnected, and clears the
## stored callback on every path so `request_skip` can trust `_pending_cb`.
func _arm(seconds, cb := Callable()) -> void:
	if _pending != null and _pending.time_left > 0.0 and _pending_cb.is_valid() \
			and _pending.timeout.is_connected(_pending_cb):
		_pending.timeout.disconnect(_pending_cb)
	_pending_cb = Callable()
	if seconds == null:
		_pending = null
		return
	_pending = get_tree().create_timer(seconds)
	_pending_cb = cb
	_pending.timeout.connect(cb)


# ---------------------------------------------------------------------------
# Pure helpers (no Node state) — safe to unit-test directly.
# ---------------------------------------------------------------------------

## The RESTING beat implied by an engine phase. Transient beats are layered on by
## the driver and are never returned here.
static func beat_for_phase(phase: String) -> int:
	match phase:
		"dealt":                 return Beat.DEAL_PROMPT
		"selected":              return Beat.FLIP_MOMENT
		"flipped":               return Beat.REVEALING
		"war":                   return Beat.WAR_PROMPT
		"player_win", "cpu_win": return Beat.GAME_OVER
		_:                       return Beat.BOOT


## The ordered transient holds implied by one apply's events (given its resting beat).
## DRAWING (the draw-in) rides the start_round apply (`round_staged`, resting FLIP_MOMENT).
## WAR_REVEALING (an ack_war's stake reveal) is CHAINED ahead of the ROUND_RESULT (a win)
## or WAR_BANNER (a re-tie) of the SAME apply, because the engine emits `war_decide`
## together with the `award`/`tie`. `tie` and `award` are mutually exclusive within an
## apply, and `round_staged` never co-occurs with `war_decide`.
static func transient_chain(events: Array, resting: int) -> Array:
	var chain: Array = []
	if _has(events, "war_decide"):
		chain.append(Beat.WAR_REVEALING)
	if _has(events, "round_staged"):
		chain.append(Beat.DRAWING)
	if _has(events, "tie"):
		chain.append(Beat.WAR_BANNER)
	elif _has(events, "award") and resting == Beat.DEAL_PROMPT:
		chain.append(Beat.ROUND_RESULT)
	return chain


## Duration of a transient beat (presentation-only). War transients scale by depth.
func _transient_dur(b: int, depth: int) -> float:
	match b:
		Beat.DRAWING:       return _dur("stage")
		Beat.WAR_REVEALING: return _dur("war_stake", depth)
		Beat.WAR_BANNER:    return _dur("war_banner", depth)
		Beat.ROUND_RESULT:  return _dur("result")
		_:                  return 0.0


## Beat duration in seconds. `depth > 0` applies the war-depth decay.
func _dur(key: String, depth := 0) -> float:
	var s := float(TEMPO[key]) * SPEED
	return s * war_scale(depth) if depth > 0 else s


## War-beat time scale by depth: 1 -> 1.00, 2 -> 0.60, 3 -> 0.36, 4+ -> 0.30.
static func war_scale(depth: int) -> float:
	return max(WAR_MIN_SCALE, pow(WAR_DECAY, max(0, depth - 1)))


## True for the beats that wait for a player and must never be auto-skipped. Note
## FLIP_MOMENT is NOT here: in the basic loop it auto-flips (a locked auto beat), and
## on the special-window path it awaits but arms no auto-action (so request_skip, which
## requires a valid armed callback, is a no-op there too — the choice is never skipped).
static func _is_decision_beat(b: int) -> bool:
	return b == Beat.DEAL_PROMPT or b == Beat.WAR_PROMPT or b == Beat.GAME_OVER


## Does any buffered event carry this `type`?
static func _has(events: Array, t: String) -> bool:
	for ev in events:
		if String((ev as Dictionary).get("type", "")) == t:
			return true
	return false


## Override seam: while true, deep wars auto-ack. The Special Cards feature
## overrides this to defer the auto-ack while the player owns a relevant post-flip
## special. Always true in the basic loop.
func can_auto_ack() -> bool:
	return true


## Seam: true when the staged round offers a playable pre-flip special, in which case
## FLIP_MOMENT AWAITS (the special window) instead of auto-flipping. Always false in the
## basic loop (no specials owned), so one tap draws + flips. The Special Cards feature
## broadens this; mirrors `can_auto_ack()`.
func _has_preflip_special() -> bool:
	return _pending_special == null and not _specials_player.is_empty()


# --- seed sources -----------------------------------------------------------

func _initial_seed() -> String:
	return boot_seed if not boot_seed.is_empty() else _fresh_seed()


## A deterministic-but-fresh local seed for a new offline match.
func _fresh_seed() -> String:
	return "match-%d" % Time.get_ticks_usec()
