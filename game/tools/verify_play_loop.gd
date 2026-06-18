extends SceneTree
## VERIFY play_loop — the Round Director driving a real match end to end.
##
## A frame-advancing SceneTree verifier (adds the Director to the tree and awaits
## frames/timers — it does NOT do all work in _init()). It exercises Phase A of the
## Core Play Loop against a live WarMatch (offline, the engine is the source of truth).
##
## The decision point is the DEAL_PROMPT (phase "dealt"): the player taps FLIP CARD to
## DRAW (the DRAWING transient flies a card into each current slot) and then the basic
## loop AUTO-FLIPS (FLIP_MOMENT). So one tap draws + flips; the action stream is still
## start_round -> flip -> resolve, only the human gesture moved to "dealt".
##
##   - Full auto-advance: from a fresh deal the match plays to a terminal win with the
##     harness only tapping FLIP at DEAL_PROMPT (+ DECLARE WAR on ties) and SKIP on the
##     transient/auto beats. A non-empty deal renders, the DRAWING transient fires, and
##     >=1 WAR occurs and resolves.
##   - Per-beat input lock: locked true for DRAWING/FLIP_MOMENT(basic)/REVEALING/
##     ROUND_RESULT/WAR_BANNER/WAR_REVEALING; false for DEAL_PROMPT/WAR_PROMPT/GAME_OVER.
##   - Transient gating + the new draw-on-click flow; reconcile safety; the deep-war
##     auto-ack; war forfeit + terminal routing; the accepted/rejected pre-flip special
##     seam at an awaited FLIP_MOMENT; determinism (run-to-run + skip-neutral); and
##     headless driveability without the Director.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_play_loop.gd

const Director := preload("res://ui/round_director.gd")

## A fixed deal so the run is deterministic. Chosen to contain >=1 WAR and to
## terminate within MAX_FRAMES (asserted below; if not, the message says to retune).
const FIXED_SEED := "play-loop-vector-0001"
const MAX_FRAMES := 80000
## Around the Director's WAR_AUTO_DEPTH (=3): shallow prompts, deep auto-acks.
const WAR_SHALLOW_DEPTH := 2
const WAR_DEEP_DEPTH := 4


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY play_loop: PASS")
	else:
		print("VERIFY play_loop: FAIL %s" % reason)
	quit()


func _run() -> String:
	var B = Director.Beat

	# === 1. Full auto-advance match (also feeds input-lock + WAR-loop checks) ===
	var rec := await _drive_to_end(FIXED_SEED)
	if not rec["reached_end"]:
		return "match did not terminate within %d frames (final beat=%d) — retune FIXED_SEED" % [MAX_FRAMES, rec["last_beat"]]
	if not (rec["final_phase"] == "player_win" or rec["final_phase"] == "cpu_win"):
		return "match ended in non-terminal phase '%s'" % rec["final_phase"]
	if rec["final_hash"].length() != 64:
		return "final hash is not 64 hex chars: '%s'" % rec["final_hash"]
	if not rec["events"].has("round_staged"):
		return "no round_staged event — the deal never staged (silent no-deal regression?)"
	if not rec["events"].has("award"):
		return "no award event — no round was ever resolved"
	if rec["max_player_cards"] < 1 or rec["max_cpu_cards"] < 1:
		return "a side never held cards — the deal did not render a non-empty 'dealt' state"

	# Input-lock flag is correct for every beat that appeared.
	# (WAR_PROMPT's lock is conditional — false when awaited, true when a deep war
	# auto-acks — so it is asserted in _check_deep_war_autoack, not here.)
	var locked_expected := {
		B.DEAL_PROMPT: false, B.DRAWING: true, B.FLIP_MOMENT: true,
		B.REVEALING: true, B.ROUND_RESULT: true,
		B.WAR_BANNER: true, B.WAR_REVEALING: true,
		B.GAME_OVER: false,
	}
	for beat_name in locked_expected:
		if rec["locks"].has(beat_name) and rec["locks"][beat_name] != locked_expected[beat_name]:
			return "beat %d emitted locked=%s, expected %s" % [beat_name, rec["locks"][beat_name], locked_expected[beat_name]]

	# The tap draws on the click: every round shows the DRAWING transient, which settles
	# into FLIP_MOMENT (the auto-flip), and the result hold gates the next DEAL_PROMPT.
	if not rec["beats_seen"].has(B.DRAWING):
		return "DRAWING (draw-in) never showed — the tap did not draw on the click"
	if not _has_adjacent(rec["beat_seq"], B.DRAWING, B.FLIP_MOMENT):
		return "DRAWING was not followed by FLIP_MOMENT (draw-in did not settle into the flip)"
	if not _has_adjacent(rec["beat_seq"], B.ROUND_RESULT, B.DEAL_PROMPT):
		return "ROUND_RESULT was not followed by DEAL_PROMPT (result hold did not gate the next round)"

	# >=1 WAR occurred and the war beats appeared.
	if not rec["events"].has("tie"):
		return "no WAR ever occurred for FIXED_SEED — retune the seed to include a tie"
	if not rec["beats_seen"].has(B.WAR_BANNER):
		return "a tie occurred but WAR_BANNER never showed"
	if not rec["beats_seen"].has(B.WAR_PROMPT):
		return "a tie occurred but WAR_PROMPT never showed"
	if rec["events"].has("war_decide") and not rec["beats_seen"].has(B.WAR_REVEALING):
		return "an ack_war resolved (war_decide) but WAR_REVEALING never chained"
	if not _has_adjacent(rec["beat_seq"], B.WAR_BANNER, B.WAR_PROMPT):
		return "WAR_BANNER was not followed by WAR_PROMPT"
	if rec["beats_seen"].has(B.WAR_REVEALING):
		if not (_has_adjacent(rec["beat_seq"], B.WAR_REVEALING, B.ROUND_RESULT) \
				or _has_adjacent(rec["beat_seq"], B.WAR_REVEALING, B.WAR_BANNER)):
			return "WAR_REVEALING did not chain into ROUND_RESULT or WAR_BANNER"

	# === 2. Transient gating + draw-on-click (deterministic skip-stepping) =====
	var gate_err := await _check_transient_gating()
	if gate_err != "":
		return gate_err

	# === 3. A real timer auto-fires the reveal on its own (no skip) ===========
	var timer_err := await _check_timer_autofire()
	if timer_err != "":
		return timer_err

	# === 4. DEAL_PROMPT gating + skip-no-op + a dropped mis-timed intent ========
	var gate2_err := await _check_deal_prompt_and_skip()
	if gate2_err != "":
		return gate2_err

	# === 5. Skip is a no-op at WAR_PROMPT ======================================
	var war_skip_err := await _check_skip_noop_at_war()
	if war_skip_err != "":
		return war_skip_err

	# === 5b. Deep-war auto-ack threshold (shallow awaits; deep arms ack) ========
	var autoack_err := await _check_deep_war_autoack()
	if autoack_err != "":
		return autoack_err

	# === 5c. Reconcile re-snap re-derives ONCE (reconciled not double-bound) ====
	var reconcile_err := await _check_reconcile_resnap()
	if reconcile_err != "":
		return reconcile_err

	# === 5d. PLAY AGAIN deals a fresh, non-terminal match =======================
	var replay_err := await _check_play_again()
	if replay_err != "":
		return replay_err

	# === 5e. War forfeit routes the Director to GAME_OVER =======================
	var forfeit_err := await _check_war_forfeit()
	if forfeit_err != "":
		return forfeit_err

	# === 5f. A game-WINNING war short-circuits straight to GAME_OVER ============
	var termwar_err := await _check_terminal_war_routes_game_over()
	if termwar_err != "":
		return termwar_err

	# === 5g. The pre-flip special window: awaited FLIP_MOMENT, accepted + rejected ==
	var peek_err := await _check_special_window()
	if peek_err != "":
		return peek_err

	# === 5h. Tap-to-skip is determinism-neutral (skip vs let-timers-fire) ========
	var skipneutral_err := await _check_skip_neutrality()
	if skipneutral_err != "":
		return skipneutral_err

	# === 5i. CONTINUE records the match once and routes home =====================
	var continue_err := await _check_continue()
	if continue_err != "":
		return continue_err

	# === 6. Determinism: same seed + same decisions -> same final hash run-to-run.
	var rec_b := await _drive_to_end(FIXED_SEED)
	if rec_b["final_hash"] != rec["final_hash"]:
		return "non-deterministic: two identical drives diverged (%s != %s)" % [rec["final_hash"], rec_b["final_hash"]]
	if rec_b["final_phase"] != rec["final_phase"]:
		return "non-deterministic: terminal phase differs (%s != %s)" % [rec["final_phase"], rec_b["final_phase"]]

	# === 7. Headless driveability preserved (no Director) ======================
	var bare := _bare_match_plays_to_end(FIXED_SEED, 200000)
	if not bare["terminal"]:
		return "a bare WarMatch (no Director) did not reach a terminal phase (got '%s')" % bare["phase"]
	if bare["phase"] != rec["final_phase"]:
		return "bare WarMatch terminal phase '%s' != Director's '%s' (same seed should agree)" % [bare["phase"], rec["final_phase"]]

	return ""


# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

## The drive decision for a beat: tap FLIP at DEAL_PROMPT (draws + auto-flips), DECLARE
## WAR at WAR_PROMPT, SKIP every transient/auto beat (incl. the basic-loop FLIP_MOMENT,
## whose armed auto-flip skip fast-forwards). Idle at BOOT/GAME_OVER.
func _drive_step(d) -> void:
	var B = Director.Beat
	match d._beat:
		B.DEAL_PROMPT: d.request_deal_and_flip()
		B.WAR_PROMPT: d.request_declare_war()
		B.BOOT, B.GAME_OVER: pass
		_: d.request_skip()


## Drive a Director (fixed seed) to GAME_OVER. Returns a record of what happened.
func _drive_to_end(seed: String) -> Dictionary:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = seed
	var rec := {
		"beat_seq": [], "beats_seen": {}, "locks": {}, "events": [],
		"max_player_cards": 0, "max_cpu_cards": 0,
		"reached_end": false, "last_beat": Director.Beat.BOOT, "final_phase": "", "final_hash": "",
	}
	# Connect the beat recorder BEFORE add_child so the first DEAL_PROMPT is captured.
	d.beat.connect(func(bn: int, _events: Array, locked: bool) -> void:
		rec["beat_seq"].append(bn)
		rec["beats_seen"][bn] = true
		rec["locks"][bn] = locked
	)
	get_root().add_child(d)
	await process_frame   # in a --script SceneTree, _ready runs on the next frame
	if d._match == null:
		_retire(d)
		return rec
	var s0 := d._match.get_state() as Dictionary
	rec["max_player_cards"] = (s0.get("player_deck", []) as Array).size()
	rec["max_cpu_cards"] = (s0.get("cpu_deck", []) as Array).size()
	d._match.event.connect(func(ev: Dictionary) -> void:
		rec["events"].append(String(ev.get("type", "")))
	)
	d.view_state.connect(func(state: Dictionary) -> void:
		rec["max_player_cards"] = maxi(rec["max_player_cards"], (state.get("player_deck", []) as Array).size())
		rec["max_cpu_cards"] = maxi(rec["max_cpu_cards"], (state.get("cpu_deck", []) as Array).size())
	)
	var guard := 0
	while d._beat != B.GAME_OVER and guard < MAX_FRAMES:
		await process_frame
		_drive_step(d)
		guard += 1
	rec["reached_end"] = (d._beat == B.GAME_OVER)
	rec["last_beat"] = d._beat
	rec["final_phase"] = String(d._match.get_state().get("phase", ""))
	rec["final_hash"] = d._match.get_hash()
	_retire(d)
	return rec


## Synchronous skip-stepping proves: the result hold gates the next round AND the
## DEAL_PROMPT awaits the player (no auto-draw) — the tap is what draws.
func _check_transient_gating() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var events: Array = []
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))

	if not await _drive_to_revealing(d, MAX_FRAMES):
		_retire(d)
		return "could not reach a non-tie REVEALING to test the transient holds"

	# Right after the auto-flip (synchronous): REVEALING is armed but resolve has NOT fired.
	if d._beat != B.REVEALING:
		_retire(d)
		return "expected REVEALING after a non-tie flip, got beat %d" % d._beat
	var awards_before := events.count("award")

	# Fire the reveal hold -> resolve -> award -> ROUND_RESULT.
	d.request_skip()
	if d._beat != B.ROUND_RESULT and d._beat != B.GAME_OVER:
		_retire(d)
		return "skip at REVEALING did not reach ROUND_RESULT/GAME_OVER (got %d)" % d._beat
	if events.count("award") <= awards_before:
		_retire(d)
		return "resolve did not award when its reveal hold fired"
	if d._beat == B.ROUND_RESULT:
		var staged_before := events.count("round_staged")
		# The result hold gates the next round.
		d.request_skip()  # ROUND_RESULT hold -> DEAL_PROMPT (awaits; arms NO auto-draw)
		if d._beat != B.DEAL_PROMPT:
			_retire(d)
			return "skip at ROUND_RESULT did not reach DEAL_PROMPT (got %d)" % d._beat
		if events.count("round_staged") != staged_before:
			_retire(d)
			return "start_round fired without a tap — DEAL_PROMPT must AWAIT the draw"
		if d._pending != null:
			_retire(d)
			return "DEAL_PROMPT armed an auto-action (it must await the player's tap)"
		# The tap is what draws: request_deal_and_flip submits start_round (round_staged++).
		d.request_deal_and_flip()
		if events.count("round_staged") <= staged_before:
			_retire(d)
			return "request_deal_and_flip did not draw (start_round never fired)"
		if d._beat != B.DRAWING:
			_retire(d)
			return "after the draw tap the beat is %d, expected DRAWING (the draw-in)" % d._beat
	_retire(d)
	return ""


## One real wall-clock confirmation that the reveal timer auto-fires (not only via skip).
func _check_timer_autofire() -> String:
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var events: Array = []
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))
	if not await _drive_to_revealing(d, MAX_FRAMES):
		_retire(d)
		return "could not reach REVEALING for the timer auto-fire check"
	var awards_before := events.count("award")
	await create_timer(0.85).timeout   # reveal tail flip(0.30)+read(0.35)=0.65s, no skip
	if events.count("award") <= awards_before:
		_retire(d)
		return "the reveal timer did not auto-fire resolve within 0.85s"
	_retire(d)
	return ""


## DEAL_PROMPT gating: skip is a no-op there; mis-timed intents (declare war, flip) are
## beat-dropped without reaching the engine; request_deal_and_flip draws.
func _check_deal_prompt_and_skip() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var rejected: Array = []
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.action_rejected.connect(func(_a: Dictionary, e: String) -> void: rejected.append(e))

	if not await _advance_to_deal_prompt(d, MAX_FRAMES):
		_retire(d)
		return "could not reach the first DEAL_PROMPT"
	if String(d._match.get_state().get("phase", "")) != "dealt":
		_retire(d)
		return "at DEAL_PROMPT the engine phase is '%s', expected 'dealt'" % d._match.get_state().get("phase", "")

	# Skip is a no-op at the draw decision (does not auto-draw).
	d.request_skip()
	if String(d._match.get_state().get("phase", "")) != "dealt":
		_retire(d)
		return "request_skip at DEAL_PROMPT advanced the phase (should be a no-op)"

	# Mis-timed intents are dropped by the beat-guard: they never reach WarMatch, so
	# there is NO engine rejection.
	var rej_before := rejected.size()
	d.request_declare_war()
	d.request_flip()
	if String(d._match.get_state().get("phase", "")) != "dealt":
		_retire(d)
		return "a mis-timed intent at DEAL_PROMPT changed the phase (should be dropped)"
	if rejected.size() != rej_before:
		_retire(d)
		return "a mis-timed intent at DEAL_PROMPT produced an engine rejection (should be beat-dropped)"

	# request_deal_and_flip draws (start_round) -> phase 'selected'.
	d.request_deal_and_flip()
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "request_deal_and_flip did not draw (phase '%s', expected 'selected')" % d._match.get_state().get("phase", "")
	# A second request_deal_and_flip while no longer at DEAL_PROMPT is a no-op.
	if d._beat == B.DEAL_PROMPT:
		_retire(d)
		return "beat is still DEAL_PROMPT after the draw tap"
	var phase_now := String(d._match.get_state().get("phase", ""))
	d.request_deal_and_flip()
	if String(d._match.get_state().get("phase", "")) != phase_now:
		_retire(d)
		return "a second request_deal_and_flip changed the phase (should be dropped off DEAL_PROMPT)"
	_retire(d)
	return ""


## Skip is a no-op at WAR_PROMPT (drive until the first war prompt, then probe).
func _check_skip_noop_at_war() -> String:
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	if not await _advance_to_war_prompt(d, MAX_FRAMES):
		_retire(d)
		return "could not reach a WAR_PROMPT to test skip-no-op (retune FIXED_SEED)"
	var phase0 := String(d._match.get_state().get("phase", ""))
	d.request_skip()
	if String(d._match.get_state().get("phase", "")) != phase0:
		_retire(d)
		return "request_skip at WAR_PROMPT advanced the war (should be a no-op)"
	_retire(d)
	return ""


## Deep-war auto-ack threshold: a shallow WAR_PROMPT awaits the player (no armed
## auto-action); a deep one (> WAR_AUTO_DEPTH) arms an auto-ack. Tested directly on
## _enter_resting so it does not depend on the deal producing a 5-deep war.
func _check_deep_war_autoack() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var last_locked := [false]
	d.beat.connect(func(_n: int, _e: Array, l: bool) -> void: last_locked[0] = l)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	# Shallow: awaits the player — no auto-action armed, emitted UNLOCKED (interactive).
	d._arm(null)
	d._enter_resting(B.WAR_PROMPT, WAR_SHALLOW_DEPTH)
	if d._beat != B.WAR_PROMPT:
		_retire(d)
		return "enter_resting(WAR_PROMPT, shallow) did not emit WAR_PROMPT"
	if d._pending != null:
		_retire(d)
		return "a shallow WAR_PROMPT armed an auto-ack (should await the player)"
	if last_locked[0]:
		_retire(d)
		return "a shallow WAR_PROMPT was emitted LOCKED (an awaited prompt must be unlocked)"
	# Deep: arms the auto-ack timer AND is emitted LOCKED (an auto beat, not a prompt).
	d._enter_resting(B.WAR_PROMPT, WAR_DEEP_DEPTH)
	if d._pending == null:
		_retire(d)
		return "a deep WAR_PROMPT (depth %d) did not arm the auto-ack" % WAR_DEEP_DEPTH
	if not last_locked[0]:
		_retire(d)
		return "a deep (auto-acking) WAR_PROMPT was emitted UNLOCKED (should be a locked auto beat)"
	d._arm(null)
	_retire(d)
	return ""


## Reconcile safety: a re-snap runs the single re-derive entry (_on_state) EXACTLY once
## (proving `reconciled` is not also bound) — at DEAL_PROMPT it arms NO auto-action, and
## at an auto beat (FLIP_MOMENT) it re-arms exactly one timer that fires its action once.
func _check_reconcile_resnap() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var beats: Array = []
	var events: Array = []
	d.beat.connect(func(n: int, _e: Array, _l: bool) -> void: beats.append(n))
	get_root().add_child(d)
	await process_frame   # _ready deals and rests at DEAL_PROMPT (awaiting the draw tap)
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))
	if d._beat != B.DEAL_PROMPT:
		_retire(d)
		return "expected DEAL_PROMPT right after the deal, got beat %d" % d._beat

	# Part A — re-snap at DEAL_PROMPT: exactly one beat (no double-bind), arms nothing.
	var beats_before := beats.size()
	d._match._reconcile_from_json(JSON.stringify(d._match.get_state()))
	if beats.size() != beats_before + 1:
		_retire(d)
		return "reconcile emitted %d beats, expected exactly 1 (reconciled double-bound?)" % (beats.size() - beats_before)
	if d._beat != B.DEAL_PROMPT:
		_retire(d)
		return "after a DEAL_PROMPT re-snap the beat is %d, expected DEAL_PROMPT" % d._beat
	if d._pending != null:
		_retire(d)
		return "DEAL_PROMPT re-snap armed an auto-action (it must await the tap)"

	# Part B — re-snap at an AUTO beat re-arms one timer and fires once. Draw + skip to
	# the basic-loop FLIP_MOMENT (auto-flip armed), then re-snap to that 'selected' state.
	var staged_before := events.count("round_staged")
	d.request_deal_and_flip()       # -> DRAWING
	if d._beat == B.DRAWING:
		d.request_skip()             # DRAWING -> FLIP_MOMENT (basic auto-flip armed)
	if d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "could not reach the basic-loop FLIP_MOMENT for the re-arm check (got %d)" % d._beat
	var flips_before := events.count("flip")
	beats_before = beats.size()
	d._match._reconcile_from_json(JSON.stringify(d._match.get_state()))
	if beats.size() != beats_before + 1:
		_retire(d)
		return "FLIP_MOMENT re-snap emitted %d beats, expected exactly 1" % (beats.size() - beats_before)
	if d._pending == null:
		_retire(d)
		return "FLIP_MOMENT re-snap did not re-arm the auto-flip"
	d.request_skip()                # fire the re-armed auto-flip
	if events.count("flip") != flips_before + 1:
		_retire(d)
		return "after a re-snap, flip fired %d times, expected exactly 1 (double-apply?)" % (events.count("flip") - flips_before)
	# (and start_round was not re-fired by the reconcile)
	if events.count("round_staged") != staged_before + 1:
		_retire(d)
		return "reconcile re-fired start_round (round_staged moved by %d, expected 1)" % (events.count("round_staged") - staged_before)
	_retire(d)
	return ""


## PLAY AGAIN: from a terminal match, request_play_again deals a fresh, non-terminal
## match (full decks) and restarts the loop at DEAL_PROMPT.
func _check_play_again() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	var guard := 0
	while d._beat != B.GAME_OVER and guard < MAX_FRAMES:
		await process_frame
		_drive_step(d)
		guard += 1
	if d._beat != B.GAME_OVER:
		_retire(d)
		return "could not reach GAME_OVER for the replay test"

	d.request_play_again()
	await process_frame
	var st := d._match.get_state() as Dictionary
	var phase := String(st.get("phase", ""))
	if phase == "player_win" or phase == "cpu_win":
		_retire(d)
		return "request_play_again stayed terminal (phase '%s')" % phase
	var total := (st.get("player_deck", []) as Array).size() + (st.get("cpu_deck", []) as Array).size()
	if total != 52:
		_retire(d)
		return "request_play_again did not deal a full 52-card match (got %d cards)" % total
	if d._beat != B.DEAL_PROMPT:
		_retire(d)
		return "after PLAY AGAIN the beat is %d, expected DEAL_PROMPT" % d._beat
	_retire(d)
	return ""


## War forfeit driven LIVE: a side that cannot complete a war (< WAR_STAKE+1 cards)
## forfeits — ack_war emits war_forfeit + game_over and the Director routes straight to
## GAME_OVER (exercising the _on_state terminal short-circuit, not just transient_chain).
func _check_war_forfeit() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var events: Array = []
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))
	d._match._reconcile_from_json(JSON.stringify(_war_state([_card(5, "clubs"), _card(6, "clubs")],
		[_card(8, "hearts"), _card(9, "hearts"), _card(10, "hearts"), _card(11, "hearts"), _card(12, "hearts"), _card(13, "hearts")])))
	if d._beat != B.WAR_PROMPT:
		_retire(d)
		return "injected war state did not settle at WAR_PROMPT (got beat %d)" % d._beat
	events.clear()
	d.request_declare_war()
	if not (events.has("war_forfeit") and events.has("game_over")):
		_retire(d)
		return "ack_war on a short deck did not emit war_forfeit + game_over (events=%s)" % str(events)
	if d._beat != B.GAME_OVER:
		_retire(d)
		return "after a war forfeit the Director is at beat %d, expected GAME_OVER" % d._beat
	if String(d._match.get_state().get("phase", "")) != "cpu_win":
		_retire(d)
		return "war forfeit terminal phase is '%s', expected cpu_win" % d._match.get_state().get("phase", "")
	_retire(d)
	return ""


## A game-WINNING war: [war_decide, award, game_over] in ONE apply -> the Director
## short-circuits to GAME_OVER (no stranded ROUND_RESULT; the stake-reveal is deliberately
## skipped on a terminal war — see the brief's open question). Locks that behavior.
func _check_terminal_war_routes_game_over() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var beats: Array = []
	var events: Array = []
	d.beat.connect(func(n: int, _e: Array, _l: bool) -> void: beats.append(n))
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))
	d._match._reconcile_from_json(JSON.stringify(_war_state(
		[_card(2, "clubs"), _card(3, "clubs"), _card(4, "clubs"), _card(14, "clubs"), _card(5, "clubs")],
		[_card(6, "hearts"), _card(7, "hearts"), _card(8, "hearts"), _card(9, "hearts")])))
	if d._beat != B.WAR_PROMPT:
		_retire(d)
		return "injected winning-war state did not settle at WAR_PROMPT (got beat %d)" % d._beat
	beats.clear()
	events.clear()
	d.request_declare_war()
	if not (events.has("war_decide") and events.has("game_over")):
		_retire(d)
		return "a game-winning war did not emit war_decide + game_over (events=%s)" % str(events)
	if d._beat != B.GAME_OVER:
		_retire(d)
		return "a game-winning war did not route to GAME_OVER (got beat %d)" % d._beat
	if String(d._match.get_state().get("phase", "")) != "player_win":
		_retire(d)
		return "game-winning war terminal phase is '%s', expected player_win" % d._match.get_state().get("phase", "")
	if beats.has(B.WAR_REVEALING):
		_retire(d)
		return "WAR_REVEALING played on a terminal war (terminal short-circuit expected — behavior changed without resolving the brief question?)"
	if beats.has(B.ROUND_RESULT):
		_retire(d)
		return "stranded ROUND_RESULT on a terminal war"
	_retire(d)
	return ""


## The pre-flip special window. With a special OWNED, FLIP_MOMENT AWAITS (does not
## auto-flip): an UNOWNED special is engine-rejected; the OWNED 'peek' is accepted, stays
## 'selected', leaves pending_special NULL, reveals the staged card, and re-derives a
## FLIP_MOMENT that now auto-flips (peek consumed). No special-specific Director code.
func _check_special_window() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var rejected: Array = []
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.action_rejected.connect(func(_a: Dictionary, e: String) -> void: rejected.append(e))
	d._match._reconcile_from_json(JSON.stringify(_selected_state_with_peek()))
	if d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "injected 'selected' (peek owned) state did not settle at FLIP_MOMENT (got beat %d)" % d._beat
	# With a special available, FLIP_MOMENT AWAITS — it must NOT auto-flip.
	if d._pending != null:
		_retire(d)
		return "FLIP_MOMENT auto-armed a flip while a pre-flip special was available (should await)"
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "the awaited FLIP_MOMENT did not stay at 'selected'"

	# An UNOWNED special is beat-legal (reaches the engine) and the ENGINE rejects it.
	d.request_special("steal_tie")
	if rejected.size() != 1:
		_retire(d)
		return "request_special('steal_tie') unowned did not produce exactly one engine rejection"
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "an unowned special changed the state (should be unchanged)"

	# The OWNED peek is accepted: stays 'selected', pending null, reveals the card.
	d.request_special("peek")
	if rejected.size() != 1:
		_retire(d)
		return "an OWNED peek was rejected by the engine (%s)" % str(rejected)
	var st := d._match.get_state() as Dictionary
	if String(st.get("phase", "")) != "selected":
		_retire(d)
		return "after peek the phase is '%s', expected 'selected'" % st.get("phase", "")
	if st.get("pending_special", "x") != null:
		_retire(d)
		return "after peek pending_special is %s, expected null (peek clears it)" % str(st.get("pending_special"))
	if d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "after peek the Director re-derived beat %d, expected FLIP_MOMENT" % d._beat
	var ppot := st.get("player_pot", []) as Array
	if ppot.is_empty() or not bool((ppot.back() as Dictionary).get("face_up", false)):
		_retire(d)
		return "peek did not reveal the player's staged card face_up"
	# Peek consumed the only special -> FLIP_MOMENT now auto-flips; firing it reveals.
	if d._pending == null:
		_retire(d)
		return "FLIP_MOMENT did not auto-arm a flip after the special was consumed"
	d.request_skip()
	if String(d._match.get_state().get("phase", "")) != "flipped":
		_retire(d)
		return "the flip after peek did not advance to 'flipped'"
	_retire(d)
	return ""


## Tap-to-skip is determinism-neutral: reaching the same point (the 2nd DEAL_PROMPT) by
## SKIPPING the transients vs by LETTING THE TIMERS auto-fire yields the identical 64-hex
## hash — skip changes WHEN an auto-action fires, never WHICH.
func _check_skip_neutrality() -> String:
	var h_skip := await _hash_at_second_deal_prompt(true)
	var h_timer := await _hash_at_second_deal_prompt(false)
	if h_skip == "" or h_timer == "":
		return "could not reach the 2nd DEAL_PROMPT for the skip-neutrality check"
	if h_skip != h_timer:
		return "tap-to-skip changed the hash (%s != %s) — skip must change WHEN, not WHICH" % [h_skip, h_timer]
	return ""


## Drive to the 2nd DEAL_PROMPT either by skipping transients (use_skip) or by letting
## the armed timers auto-fire, and return the WarMatch hash there (a stable, timer-free
## 'dealt' state). Returns "" if the match ended before a 2nd DEAL_PROMPT.
func _hash_at_second_deal_prompt(use_skip: bool) -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return ""
	var prompts := 0
	var guard := 0
	while guard < MAX_FRAMES:
		await process_frame
		match d._beat:
			B.DEAL_PROMPT:
				prompts += 1
				if prompts >= 2:
					var h: String = d._match.get_hash()
					_retire(d)
					return h
				d.request_deal_and_flip()
			B.WAR_PROMPT:
				d.request_declare_war()
			B.GAME_OVER:
				_retire(d)
				return ""
			B.BOOT:
				pass
			_:
				if use_skip:
					d.request_skip()
				# else: let the armed timer auto-fire (DRAWING / FLIP_MOMENT / REVEALING / ...)
		guard += 1
	_retire(d)
	return ""


## CONTINUE TO LOBBY: request_quit records the match exactly once and routes home. The
## meta/router autoloads request_quit resolves at /root are stubbed.
func _check_continue() -> String:
	var B = Director.Beat
	var prior_gs := get_root().get_node_or_null(^"GameState")
	if prior_gs != null:
		get_root().remove_child(prior_gs)
		prior_gs.queue_free()
	var prior_router := get_root().get_node_or_null(^"UiRouter")
	if prior_router != null:
		get_root().remove_child(prior_router)
		prior_router.queue_free()
	var gs := _StubGameState.new()
	gs.name = "GameState"
	get_root().add_child(gs)
	var router := _StubRouter.new()
	router.name = "UiRouter"
	get_root().add_child(router)
	var d := Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		gs.queue_free()
		router.queue_free()
		return "Director did not initialize its WarMatch"
	var guard := 0
	while d._beat != B.GAME_OVER and guard < MAX_FRAMES:
		await process_frame
		_drive_step(d)
		guard += 1
	if d._beat != B.GAME_OVER:
		_retire(d)
		gs.queue_free()
		router.queue_free()
		return "could not reach GAME_OVER for the CONTINUE test"
	d.request_quit()
	var calls: int = gs.calls
	var routed: String = router.last_goto
	_retire(d)
	gs.queue_free()
	router.queue_free()
	if calls != 1:
		return "request_quit called record_match_played %d times, expected exactly 1" % calls
	if routed != "home":
		return "request_quit routed to '%s', expected 'home'" % routed
	return ""


# ---------------------------------------------------------------------------
# Crafted-state builders (for injecting specific scenarios via reconcile)
# ---------------------------------------------------------------------------

func _card(rank: int, suit: String) -> Dictionary:
	return {"rank": rank, "suit": suit, "face_up": false}


## A phase 'war' state with the given decks and one tied face-up card staged per side.
func _war_state(player_deck: Array, cpu_deck: Array) -> Dictionary:
	return {
		"version": 1, "seed": "verify-play-loop-craft", "phase": "war",
		"player_deck": player_deck, "cpu_deck": cpu_deck,
		"player_pot": [{"rank": 7, "suit": "hearts", "face_up": true}],
		"cpu_pot": [{"rank": 7, "suit": "spades", "face_up": true}],
		"rng": {"seq": 0}, "specials": {"player": [], "cpu": []},
		"pending_special": null, "war_depth": 1,
	}


## A phase 'selected' state where the player owns 'peek' and a card is staged face-down.
func _selected_state_with_peek() -> Dictionary:
	return {
		"version": 1, "seed": "verify-play-loop-peek", "phase": "selected",
		"player_deck": [_card(5, "clubs"), _card(6, "clubs")],
		"cpu_deck": [_card(8, "hearts"), _card(9, "hearts")],
		"player_pot": [_card(7, "clubs")], "cpu_pot": [_card(4, "spades")],
		"rng": {"seq": 0}, "specials": {"player": ["peek"], "cpu": []},
		"pending_special": null, "war_depth": 0,
	}


# Stub autoloads for the CONTINUE test (request_quit resolves these at /root).
class _StubGameState extends Node:
	var calls: int = 0
	func record_match_played() -> void:
		calls += 1


class _StubRouter extends Node:
	var last_goto: String = ""
	func goto(n: String) -> void:
		last_goto = n


# ---------------------------------------------------------------------------
# Navigation helpers (advance a Director to a target beat)
# ---------------------------------------------------------------------------

## Skip/declare until the first DEAL_PROMPT (the draw decision — the first decision each
## match, reached right after the deal).
func _advance_to_deal_prompt(d, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.DEAL_PROMPT: return true
			B.WAR_PROMPT: d.request_declare_war()
			B.GAME_OVER: return false
			B.BOOT: pass
			_: d.request_skip()
		guard += 1
	return false


## Drive until a non-tie flip lands at REVEALING (with the resolve hold armed, so callers
## can probe synchronously). Taps the draw, skips the draw-in + auto-flip; on a tie the
## flip routes to war and we keep going.
func _drive_to_revealing(d, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.DEAL_PROMPT: d.request_deal_and_flip()
			B.FLIP_MOMENT:
				d.request_skip()                 # fire the basic-loop auto-flip
				if d._beat == B.REVEALING:
					return true
			B.WAR_PROMPT: d.request_declare_war()
			B.GAME_OVER: return false
			B.BOOT: pass
			_: d.request_skip()                  # DRAWING / ROUND_RESULT / WAR_BANNER / WAR_REVEALING
		guard += 1
	return false


## Drive until the first WAR_PROMPT (tapping the draw, skipping the draw-in/auto-flip).
func _advance_to_war_prompt(d, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.WAR_PROMPT: return true
			B.DEAL_PROMPT: d.request_deal_and_flip()
			B.GAME_OVER: return false
			B.BOOT: pass
			_: d.request_skip()
		guard += 1
	return false


# ---------------------------------------------------------------------------
# Bare-match (no Director) driveability
# ---------------------------------------------------------------------------

func _bare_match_plays_to_end(seed: String, max_steps: int) -> Dictionary:
	var m = WarMatch.new()
	m.new_game(seed)
	var steps := 0
	while steps < max_steps:
		var phase := String(m.get_state().get("phase", ""))
		if phase == "player_win" or phase == "cpu_win":
			break
		match phase:
			"dealt": m.submit_action(WarActions.start_round())
			"selected": m.submit_action(WarActions.flip())
			"flipped": m.submit_action(WarActions.resolve())
			"war": m.submit_action(WarActions.ack_war())
			_: break
		steps += 1
	var final_phase := String(m.get_state().get("phase", ""))
	m.free()
	return {
		"phase": final_phase,
		"terminal": (final_phase == "player_win" or final_phase == "cpu_win"),
		"steps": steps,
	}


# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

## Cancel the Director's pending timer (so a freed-node callback can't fire) and free it.
func _retire(d) -> void:
	d._arm(null)
	d.queue_free()


## True if `a` is immediately followed by `b` anywhere in `seq`.
func _has_adjacent(seq: Array, a: int, b: int) -> bool:
	for i in range(seq.size() - 1):
		if seq[i] == a and seq[i + 1] == b:
			return true
	return false
