extends SceneTree
## VERIFY play_loop — the Round Director driving a real match end to end.
##
## A frame-advancing SceneTree verifier (adds the Director to the tree and awaits
## frames/timers — it does NOT do all work in _init()). It exercises Phase A of the
## Core Play Loop against a live WarMatch (offline, the engine is the source of truth):
##
##   - Full auto-advance: from a fresh deal the match plays to a terminal win with
##     the harness only tapping FLIP (+ DECLARE WAR on ties) and SKIP on transients —
##     never a manual start_round/resolve. A non-empty deal renders (guards the old
##     silent no-deal bug), and >=1 WAR occurs and resolves.
##   - Per-beat input lock: locked is true for STAGING/REVEALING/ROUND_RESULT/
##     WAR_BANNER/WAR_REVEALING and false for FLIP_MOMENT/WAR_PROMPT/GAME_OVER.
##   - Transient gating: an award arms ROUND_RESULT and start_round does NOT fire
##     until that hold's callback runs; a tie shows WAR_BANNER before WAR_PROMPT; a
##     non-terminal ack_war chains WAR_REVEALING before the result/next beat. Proven
##     by stepping the single armed timer with skip (deterministic) plus one real
##     wall-clock confirmation that the timer auto-fires on its own.
##   - Tap-to-skip is a NO-OP at decision beats (never auto-skips the player's choice).
##   - Flip-moment gating: request_flip flips only at FLIP_MOMENT; request_declare_war
##     at the flip moment is dropped by the beat-guard (no engine rejection), while an
##     UNOWNED special IS beat-legal and the ENGINE rejects it (action_rejected).
##   - Determinism-neutral: the same seed + same decisions yields the same 64-hex
##     final hash (the Director adds no nondeterminism; pacing changes when, not which).
##   - Headless driveability preserved: a bare WarMatch plays a full match via
##     start_round/flip/resolve/ack_war with NO Director.
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
	# Kick off the async suite; the tree keeps ticking until _main() calls quit().
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
	# Rounds actually advanced (the deal was non-empty and the loop ran).
	if not rec["events"].has("round_staged"):
		return "no round_staged event — the deal never staged (silent no-deal regression?)"
	if not rec["events"].has("award"):
		return "no award event — no round was ever resolved"
	if rec["max_player_cards"] < 1 or rec["max_cpu_cards"] < 1:
		return "a side never held cards — the deal did not render a non-empty 'dealt' state"

	# Input-lock flag is correct for every beat that appeared.
	var locked_expected := {
		B.STAGING: true, B.REVEALING: true, B.ROUND_RESULT: true,
		B.WAR_BANNER: true, B.WAR_REVEALING: true,
		B.FLIP_MOMENT: false, B.WAR_PROMPT: false, B.GAME_OVER: false,
	}
	for beat_name in locked_expected:
		if rec["locks"].has(beat_name) and rec["locks"][beat_name] != locked_expected[beat_name]:
			return "beat %d emitted locked=%s, expected %s" % [beat_name, rec["locks"][beat_name], locked_expected[beat_name]]

	# >=1 WAR occurred and the war beats appeared (tie -> banner -> prompt; the
	# ack_war stake reveal chained as WAR_REVEALING).
	if not rec["events"].has("tie"):
		return "no WAR ever occurred for FIXED_SEED — retune the seed to include a tie"
	if not rec["beats_seen"].has(B.WAR_BANNER):
		return "a tie occurred but WAR_BANNER never showed"
	if not rec["beats_seen"].has(B.WAR_PROMPT):
		return "a tie occurred but WAR_PROMPT never showed"
	if rec["events"].has("war_decide") and not rec["beats_seen"].has(B.WAR_REVEALING):
		return "an ack_war resolved (war_decide) but WAR_REVEALING never chained"
	# Ordering adjacencies (skip-driven, so chained beats are emitted back-to-back).
	if not _has_adjacent(rec["beat_seq"], B.ROUND_RESULT, B.STAGING):
		return "ROUND_RESULT was not followed by STAGING (result hold did not gate the next round)"
	if not _has_adjacent(rec["beat_seq"], B.WAR_BANNER, B.WAR_PROMPT):
		return "WAR_BANNER was not followed by WAR_PROMPT"
	if rec["beats_seen"].has(B.WAR_REVEALING):
		if not (_has_adjacent(rec["beat_seq"], B.WAR_REVEALING, B.ROUND_RESULT) \
				or _has_adjacent(rec["beat_seq"], B.WAR_REVEALING, B.WAR_BANNER)):
			return "WAR_REVEALING did not chain into ROUND_RESULT or WAR_BANNER"

	# === 2. Transient gating (deterministic skip-stepping) ====================
	var gate_err := await _check_transient_gating()
	if gate_err != "":
		return gate_err

	# === 3. A real timer auto-fires the reveal on its own (no skip) ===========
	var timer_err := await _check_timer_autofire()
	if timer_err != "":
		return timer_err

	# === 4. Flip-moment gating + skip-no-op + distinct rejection paths =========
	var gate2_err := await _check_flip_moment_and_skip()
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

	# === 5e. War forfeit (< WAR_STAKE+1 cards) routes the Director to GAME_OVER ==
	var forfeit_err := await _check_war_forfeit()
	if forfeit_err != "":
		return forfeit_err

	# === 5f. A game-WINNING war ([war_decide, award, game_over]) short-circuits ==
	# straight to GAME_OVER (no stranded ROUND_RESULT; the stake-reveal is deliberately
	# skipped on a terminal war — see the brief's open question).
	var termwar_err := await _check_terminal_war_routes_game_over()
	if termwar_err != "":
		return termwar_err

	# === 5g. Accepted pre-flip special (peek) stays 'selected' / re-derives FLIP ==
	var peek_err := await _check_accepted_peek()
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

	# === 6. Determinism: the same seed + same decisions reproduces the same 64-hex
	# final hash run-to-run (the Director adds no nondeterminism). Skip-vs-no-skip
	# neutrality is asserted separately in 5h. ====================================
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

## Drive a Director (fixed seed) to GAME_OVER, tapping only FLIP / DECLARE WAR at
## decision beats and SKIP on transients. Returns a record of what happened.
func _drive_to_end(seed: String) -> Dictionary:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = seed
	var rec := {
		"beat_seq": [], "beats_seen": {}, "locks": {}, "events": [],
		"max_player_cards": 0, "max_cpu_cards": 0,
	}
	rec["reached_end"] = false
	rec["last_beat"] = Director.Beat.BOOT
	rec["final_phase"] = ""
	rec["final_hash"] = ""
	# Connect the beat recorder BEFORE add_child so the first STAGING (emitted from
	# the deferred _ready) is captured.
	d.beat.connect(func(name: int, _events: Array, locked: bool) -> void:
		rec["beat_seq"].append(name)
		rec["beats_seen"][name] = true
		rec["locks"][name] = locked
	)
	get_root().add_child(d)
	await process_frame   # in a --script SceneTree, _ready runs on the next frame
	if d._match == null:
		_retire(d)
		return rec
	# Seed the max-card counts from the initial deal, then record subsequent renders.
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
		match d._beat:
			B.FLIP_MOMENT: d.request_flip()
			B.WAR_PROMPT: d.request_declare_war()
			B.STAGING, B.REVEALING, B.ROUND_RESULT, B.WAR_BANNER, B.WAR_REVEALING:
				d.request_skip()
			_: pass
		guard += 1
	rec["reached_end"] = (d._beat == B.GAME_OVER)
	rec["last_beat"] = d._beat
	rec["final_phase"] = String(d._match.get_state().get("phase", ""))
	rec["final_hash"] = d._match.get_hash()
	_retire(d)
	return rec


## Synchronous skip-stepping proves each auto-action is GATED behind its hold: it is
## not fired until the armed callback runs.
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

	if not await _drive_to_revealing(d, events, MAX_FRAMES):
		_retire(d)
		return "could not reach a non-tie REVEALING to test the transient holds"

	# Right after the flip (synchronous): REVEALING is armed but resolve has NOT fired.
	if d._beat != B.REVEALING:
		_retire(d)
		return "expected REVEALING after a non-tie flip, got beat %d" % d._beat
	var awards_before := events.count("award")

	# Fire the reveal hold's callback -> resolve -> award -> ROUND_RESULT.
	d.request_skip()
	if d._beat != B.ROUND_RESULT and d._beat != B.GAME_OVER:
		_retire(d)
		return "skip at REVEALING did not reach ROUND_RESULT/GAME_OVER (got %d)" % d._beat
	if events.count("award") <= awards_before:
		_retire(d)
		return "resolve did not award when its reveal hold fired"
	if d._beat == B.ROUND_RESULT:
		var staged_before := events.count("round_staged")
		# start_round must NOT have fired yet — it is gated behind the result hold.
		if events.count("round_staged") != staged_before:
			_retire(d)
			return "start_round fired during the ROUND_RESULT hold (not gated)"
		d.request_skip()  # ROUND_RESULT hold -> STAGING (arms start_round, not yet fired)
		if d._beat != B.STAGING:
			_retire(d)
			return "skip at ROUND_RESULT did not reach STAGING (got %d)" % d._beat
		if events.count("round_staged") != staged_before:
			_retire(d)
			return "start_round fired before the STAGING hold elapsed"
		d.request_skip()  # STAGING hold -> start_round fires
		if events.count("round_staged") <= staged_before:
			_retire(d)
			return "start_round did not fire when the STAGING hold's callback ran"
		if d._beat != B.FLIP_MOMENT:
			_retire(d)
			return "after start_round the beat is %d, expected FLIP_MOMENT" % d._beat
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
	if not await _drive_to_revealing(d, events, MAX_FRAMES):
		_retire(d)
		return "could not reach REVEALING for the timer auto-fire check"
	var awards_before := events.count("award")
	# Reveal tail is flip(0.30)+read(0.35)=0.65s; wait comfortably past it WITHOUT skipping.
	await create_timer(0.85).timeout
	if events.count("award") <= awards_before:
		_retire(d)
		return "the reveal timer did not auto-fire resolve within 0.85s"
	_retire(d)
	return ""


## Flip-moment gating, skip-no-op at the flip moment, and the two distinct rejection
## paths (beat-guard drop vs engine rejection).
func _check_flip_moment_and_skip() -> String:
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
	d._match.action_rejected.connect(func(a: Dictionary, e: String) -> void: rejected.append(e))

	if not await _advance_to_flip_moment(d, MAX_FRAMES):
		_retire(d)
		return "could not reach the first FLIP_MOMENT"
	var phase0 := String(d._match.get_state().get("phase", ""))
	if phase0 != "selected":
		_retire(d)
		return "at FLIP_MOMENT the engine phase is '%s', expected 'selected'" % phase0

	# Skip is a no-op at the flip moment (does not auto-flip the player's choice).
	d.request_skip()
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "request_skip at FLIP_MOMENT advanced the phase (should be a no-op)"

	# request_declare_war at the flip moment is dropped by the beat-guard: it never
	# reaches WarMatch, so there is NO engine rejection.
	var rej_before := rejected.size()
	d.request_declare_war()
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "request_declare_war at FLIP_MOMENT changed the phase (should be dropped)"
	if rejected.size() != rej_before:
		_retire(d)
		return "request_declare_war at FLIP_MOMENT produced an engine rejection (should be beat-dropped)"

	# An UNOWNED special IS beat-legal, so it reaches WarMatch and the ENGINE rejects it.
	d.request_special("peek")
	if rejected.size() != rej_before + 1:
		_retire(d)
		return "request_special('peek') unowned did not produce exactly one engine rejection"
	if String(d._match.get_state().get("phase", "")) != "selected":
		_retire(d)
		return "an unowned special changed the state (should be unchanged)"
	if d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "after a no-op special the beat is %d, expected FLIP_MOMENT (still awaiting flip)" % d._beat

	# request_flip flips exactly once at the flip moment...
	d.request_flip()
	var after_flip := String(d._match.get_state().get("phase", ""))
	if after_flip != "flipped" and after_flip != "war":
		_retire(d)
		return "request_flip at FLIP_MOMENT did not reveal (phase '%s')" % after_flip
	# ...and a second flip while now locked (REVEALING / WAR_*) does nothing.
	if d._beat == B.FLIP_MOMENT:
		_retire(d)
		return "beat is still FLIP_MOMENT after a flip"
	var locked_phase := String(d._match.get_state().get("phase", ""))
	d.request_flip()
	if String(d._match.get_state().get("phase", "")) != locked_phase:
		_retire(d)
		return "request_flip while locked changed the phase (should be dropped)"
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


## Deep-war auto-ack threshold: a shallow WAR_PROMPT (war_depth <= WAR_AUTO_DEPTH)
## awaits the player (no armed auto-action); a deep one (> WAR_AUTO_DEPTH) arms an
## auto-ack. Tested directly on _enter_resting so it does not depend on the deal
## producing a 5-deep war. (can_auto_ack() is always true in the basic loop; its
## false branch is the documented seam the Special Cards feature overrides.)
func _check_deep_war_autoack() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	# Shallow: awaits the player — no auto-action armed.
	d._arm(null)
	d._enter_resting(B.WAR_PROMPT, WAR_SHALLOW_DEPTH)
	if d._beat != B.WAR_PROMPT:
		_retire(d)
		return "enter_resting(WAR_PROMPT, shallow) did not emit WAR_PROMPT"
	if d._pending != null:
		_retire(d)
		return "a shallow WAR_PROMPT armed an auto-ack (should await the player)"
	# Deep: arms the auto-ack timer.
	d._enter_resting(B.WAR_PROMPT, WAR_DEEP_DEPTH)
	if d._pending == null:
		_retire(d)
		return "a deep WAR_PROMPT (depth %d) did not arm the auto-ack" % WAR_DEEP_DEPTH
	d._arm(null)
	_retire(d)
	return ""


## Reconcile safety: re-snapping the SAME authoritative state runs the single
## re-derive entry (_on_state) EXACTLY once (proving `reconciled` is not also bound
## to _on_state) and re-arms one fresh timer — and the re-armed auto-action then
## fires exactly once (no double-apply).
func _check_reconcile_resnap() -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	var beats: Array = []
	var events: Array = []
	d.beat.connect(func(n: int, _e: Array, _l: bool) -> void: beats.append(n))
	get_root().add_child(d)
	await process_frame   # _ready deals and rests at STAGING with start_round armed
	if d._match == null:
		_retire(d)
		return "Director did not initialize its WarMatch"
	d._match.event.connect(func(ev: Dictionary) -> void: events.append(String(ev.get("type", ""))))
	if d._beat != B.STAGING:
		_retire(d)
		return "expected STAGING right after the deal, got beat %d" % d._beat

	var beats_before := beats.size()
	var staged_before := events.count("round_staged")
	# Re-snap to the identical state (as a validator reconcile would).
	d._match._reconcile_from_json(JSON.stringify(d._match.get_state()))
	if beats.size() != beats_before + 1:
		_retire(d)
		return "reconcile emitted %d beats, expected exactly 1 (reconciled double-bound to _on_state?)" % (beats.size() - beats_before)
	if d._beat != B.STAGING:
		_retire(d)
		return "after a STAGING re-snap the beat is %d, expected STAGING" % d._beat
	if d._pending == null:
		_retire(d)
		return "reconcile did not re-arm the resting auto-action"
	# The re-armed start_round fires exactly once when its callback runs.
	d.request_skip()
	if events.count("round_staged") != staged_before + 1:
		_retire(d)
		return "after a re-snap, start_round fired %d times, expected exactly 1 (double-apply?)" % (events.count("round_staged") - staged_before)
	_retire(d)
	return ""


## PLAY AGAIN: from a terminal match, request_play_again deals a fresh, non-terminal
## match (full decks) and restarts the loop.
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
		match d._beat:
			B.FLIP_MOMENT: d.request_flip()
			B.WAR_PROMPT: d.request_declare_war()
			B.BOOT: pass
			_: d.request_skip()
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
	if d._beat != B.STAGING and d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "after PLAY AGAIN the beat is %d, expected STAGING/FLIP_MOMENT" % d._beat
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
	# Inject a phase 'war' state where the player holds < WAR_STAKE+1 (=4) cards.
	d._match._reconcile_from_json(JSON.stringify(_war_state([_card(5, "clubs"), _card(6, "clubs")],
		[_card(8, "hearts"), _card(9, "hearts"), _card(10, "hearts"), _card(11, "hearts"), _card(12, "hearts"), _card(13, "hearts")])))
	if d._beat != B.WAR_PROMPT:
		_retire(d)
		return "injected war state did not settle at WAR_PROMPT (got beat %d)" % d._beat
	events.clear()
	d.request_declare_war()   # ack_war on a short deck -> forfeit
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


## A game-WINNING war: the deciding card empties the loser's deck, so ack_war emits
## [war_decide, award, game_over] in ONE apply. The Director short-circuits to GAME_OVER
## (no stranded ROUND_RESULT; the WAR_REVEALING stake-reveal is deliberately skipped on a
## terminal war — see the brief's open question). This locks that chosen behavior.
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
	# Player deck: 3 face-down stakes + a 14 decider (+1 spare). CPU deck: exactly 4 cards,
	# all consumed by the war, deciding on 9 < 14 -> player wins and drains the CPU.
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


## Accepted pre-flip special (peek) seam: with peek OWNED, request_special('peek') is
## accepted by the engine (no rejection), reveals the player's staged card, leaves
## pending_special NULL and the phase 'selected', the Director re-derives FLIP_MOMENT,
## and the following flip still proceeds — all with NO special-specific Director code.
func _check_accepted_peek() -> String:
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
	# Inject a phase 'selected' state where the player owns 'peek' and a card is staged.
	d._match._reconcile_from_json(JSON.stringify(_selected_state_with_peek()))
	if d._beat != B.FLIP_MOMENT:
		_retire(d)
		return "injected 'selected' state did not settle at FLIP_MOMENT (got beat %d)" % d._beat

	d.request_special("peek")
	if rejected.size() != 0:
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
		return "after peek the Director re-derived beat %d, expected FLIP_MOMENT (still awaiting flip)" % d._beat
	var ppot := st.get("player_pot", []) as Array
	if ppot.is_empty() or not bool((ppot.back() as Dictionary).get("face_up", false)):
		_retire(d)
		return "peek did not reveal the player's staged card face_up"
	# The following flip still proceeds.
	d.request_flip()
	if String(d._match.get_state().get("phase", "")) != "flipped":
		_retire(d)
		return "the flip after peek did not advance to 'flipped'"
	_retire(d)
	return ""


## Tap-to-skip is determinism-neutral: reaching the same point (the 2nd flip moment)
## by SKIPPING the transients vs by LETTING THE TIMERS auto-fire yields the identical
## 64-hex hash — skip changes WHEN an auto-action fires, never WHICH.
func _check_skip_neutrality() -> String:
	var h_skip := await _hash_at_second_flip(true)
	var h_timer := await _hash_at_second_flip(false)
	if h_skip == "" or h_timer == "":
		return "could not reach the 2nd flip moment for the skip-neutrality check"
	if h_skip != h_timer:
		return "tap-to-skip changed the hash (%s != %s) — skip must change WHEN, not WHICH" % [h_skip, h_timer]
	return ""


## Drive to the 2nd FLIP_MOMENT either by skipping transients (use_skip) or by letting
## the armed timers auto-fire, and return the WarMatch hash there (a stable, timer-free
## point). Returns "" if the match ended before a 2nd flip moment.
func _hash_at_second_flip(use_skip: bool) -> String:
	var B = Director.Beat
	var d = Director.new()
	d.boot_seed = FIXED_SEED
	d.beat.connect(func(_n: int, _e: Array, _l: bool) -> void: pass)
	get_root().add_child(d)
	await process_frame
	if d._match == null:
		_retire(d)
		return ""
	var flips := 0
	var guard := 0
	while guard < MAX_FRAMES:
		await process_frame
		match d._beat:
			B.FLIP_MOMENT:
				flips += 1
				if flips >= 2:
					var h: String = d._match.get_hash()
					_retire(d)
					return h
				d.request_flip()
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
				# else: let the armed timer auto-fire on its own schedule
		guard += 1
	_retire(d)
	return ""


## CONTINUE TO LOBBY: request_quit records the match exactly once and routes home. The
## meta/router autoloads request_quit resolves at /root are stubbed (they are absent in a
## --script run), so we can observe the calls.
func _check_continue() -> String:
	var B = Director.Beat
	# In a --script run the real autoload NODES may sit at /root (only the global
	# identifier is absent). Replace them with observable stubs so request_quit's
	# /root lookups resolve to ours and we can count the calls.
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
		match d._beat:
			B.FLIP_MOMENT: d.request_flip()
			B.WAR_PROMPT: d.request_declare_war()
			B.BOOT: pass
			_: d.request_skip()
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

## Skip autos / declare wars until the first FLIP_MOMENT (always reachable: round 1
## stages then rests at the flip moment before any tie can occur).
func _advance_to_flip_moment(d, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.FLIP_MOMENT: return true
			B.WAR_PROMPT: d.request_declare_war()
			B.GAME_OVER: return false
			B.BOOT: pass
			_: d.request_skip()
		guard += 1
	return false


## Drive (flipping, resolving wars) until a non-tie flip lands at REVEALING. Returns
## true with the resolve hold armed (so callers can probe synchronously).
func _drive_to_revealing(d, _events: Array, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.FLIP_MOMENT:
				d.request_flip()
				if d._beat == B.REVEALING:
					return true
			B.WAR_PROMPT: d.request_declare_war()
			B.GAME_OVER: return false
			B.BOOT: pass
			_: d.request_skip()
		guard += 1
	return false


## Drive until the first WAR_PROMPT (skipping autos, flipping at flip moments).
func _advance_to_war_prompt(d, max_frames: int) -> bool:
	var B = Director.Beat
	var guard := 0
	while guard < max_frames:
		await process_frame
		match d._beat:
			B.WAR_PROMPT: return true
			B.FLIP_MOMENT: d.request_flip()
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
