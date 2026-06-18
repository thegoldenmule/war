class_name WarMatch
extends Node
##
## WarMatch — the client-side match runtime: owner of the live game state and
## the bridge between PURE LOGIC and the rest of the app (UI + networking).
##
## Architecture (HARD WALL)
## ------------------------
##   input ─▶ action ─▶ WarEngine.apply(state, action) ─▶ new state + hash ─▶ render
##                                  │
##                                  └─▶ (online) WarValidatorClient.validate_action(...)
##                                          └─▶ match: ACK   /   mismatch: snap to authoritative
##
## This Node touches NO scenes and NO UI widgets. It speaks only:
##   * pure logic by class_name — WarEngine, WarHasher, WarActions, WarConstants
##   * the validator by class_name — WarValidatorClient (optional; offline-safe)
## Presentation observes it through signals.
##
## Optimistic-by-default
## ---------------------
## Every `submit_action` is applied LOCALLY first for instant feedback, then
## (if online) sent to the validator with the predicted hash. A matching hash
## is a silent fast-path ACK; a mismatch causes a snap to the authoritative
## state and a `reconciled` emission so the UI can correct itself. With no
## validator attached the match is fully playable offline — the deterministic
## engine is the source of truth.
##
## State shape (the hashed contract — see SHARED CONTRACT)
##   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot,
##     rng:{seq}, specials:{player,cpu}, pending_special, war_depth }
##

## The authoritative-as-far-as-the-client-knows state changed. Carries a deep
## COPY so observers cannot mutate the canonical state across the hash boundary.
signal state_changed(state: Dictionary)
## A gameplay event was produced by the engine (flip result, war started,
## special resolved, game over...). One signal per event in order.
signal event(ev: Dictionary)
## The validator disagreed with our optimistic prediction and we snapped to its
## authoritative state. UI should re-render from scratch (no tweening from the
## now-discarded optimistic state).
signal reconciled(state: Dictionary)
## A submitted action was rejected by the pure engine (illegal move). The local
## state is unchanged. Carries the engine's error string.
signal action_rejected(action: Dictionary, error: String)

## Current game state (the hash domain). Mutated only via engine results.
var _state: Dictionary = {}
## Hash of `_state`, kept in sync so we never recompute redundantly.
var _hash: String = ""
## Optional authoritative client. When null, the match is offline/optimistic-only.
var _validator: WarValidatorClient = null
## Guards against overlapping async validations clobbering each other; we track
## the seq of the latest local apply so a late reconcile for a stale action is
## ignored.
var _apply_seq: int = 0
## Guards CompleteMatch to a single send per match. Set when we finalize on an
## authoritative-confirmed terminal phase; reset by new_game.
var _completed_sent: bool = false


## Attach (or detach with null) the validator. Optional — a freshly-created
## WarMatch is immediately playable offline.
func set_validator(validator: WarValidatorClient) -> void:
	_validator = validator


## Returns a deep copy of the current state. Callers (UI/tests) get an isolated
## snapshot they can read/render without risk of corrupting the canonical state.
func get_state() -> Dictionary:
	return _state.duplicate(true)


## Returns the 64-hex state hash of the current state.
func get_hash() -> String:
	return _hash


## True once a game has been dealt (state is non-empty and not terminal-only).
func has_state() -> bool:
	return not _state.is_empty()


## Start a brand-new match for `seed`.
##
## OFFLINE: deal locally and synchronously through the engine's "new_game"
## action (deterministic deal). Emits `state_changed` + deal events immediately.
##
## ONLINE: the server is the seed/state authority (anti seed-shop). We defer to
## InitMatch and adopt the authoritative starting state when it arrives — pass an
## empty `seed` to let the server assign one. The deal surfaces via `state_changed`
## once the round-trip resolves (callers are signal-driven, so this is safe).
##
## Returns true once the new-game intent is accepted (the online deal lands async).
func new_game(seed: String) -> bool:
	_completed_sent = false
	if _validator != null and _validator.is_online():
		_online_new_game(seed)
		return true
	return _offline_new_game(seed)


## Local deterministic deal. Begin from an empty state; the engine's new_game
## action constructs the full dealt state for the seed.
func _offline_new_game(seed: String) -> bool:
	var action := WarActions.new_game(seed)
	var result: Dictionary = WarEngine.apply({}, action)
	if not result.get("ok", false):
		action_rejected.emit(action, result.get("error", "new_game_failed"))
		return false
	_adopt_state(result.get("state", {}))
	_emit_events(result.get("events", []))
	state_changed.emit(get_state())
	return true


## Online init-first deal: ask the validator for authoritative t0 state (and the
## match id every later RPC binds to), then adopt it verbatim. By the determinism
## parity contract the adopted state is byte-identical to what our own engine
## would deal for the same seed — so the optimistic loop proceeds with no snap.
func _online_new_game(seed: String) -> void:
	# The server is the seed authority online (War's outcome IS the deal, so the
	# seed must not be client-shoppable). We pass an EMPTY seed — the server
	# assigns one and returns the authoritative t0 state we adopt verbatim. The
	# caller's `seed` is only the offline-degrade fallback.
	var res: Dictionary = await _validator.init_match("")
	if not res.get("ok", false):
		# Could not reach / init the server — degrade to an offline deal so the
		# player still gets a game. Use the requested seed, or synthesize one.
		push_warning("WarMatch: InitMatch failed (%s); dealing offline." % res.get("error", ""))
		_offline_new_game(seed if not seed.is_empty() else _synth_seed())
		return
	_adopt_from_json(res.get("state_json", ""))


## Submit a player/CPU action. This is the single funnel for ALL game input:
##   WarActions.start_round() / play_special(id) / flip() / resolve() / ack_war()
##
## Steps: apply locally (optimistic) → emit state/events → if online, validate
## the predicted hash and reconcile on mismatch. Returns true if the local
## apply was accepted (note: an online mismatch can still reconcile afterwards).
func submit_action(action: Dictionary) -> bool:
	if _state.is_empty():
		action_rejected.emit(action, "no_active_match")
		return false
	var result: Dictionary = WarEngine.apply(_state, action)
	if not result.get("ok", false):
		# Illegal move per pure rules — local state untouched.
		action_rejected.emit(action, result.get("error", "rejected"))
		return false
	# OPTIMISTIC: adopt the new state immediately for instant feedback.
	_apply_seq += 1
	var my_seq := _apply_seq
	_adopt_state(result.get("state", {}))
	_emit_events(result.get("events", []))
	state_changed.emit(get_state())
	# Confirm with the authority (no-op / instant in offline mode). Terminal
	# finalize is deferred to _validate_async so it fires only once the server
	# has CONFIRMED the terminal phase — never from optimistic state, which a
	# mismatch could still reconcile back to a non-terminal phase.
	if _validator != null and _validator.is_online():
		_validate_async(action, _hash, my_seq)
	return true


## Adopt `new_state` as canonical and refresh the cached hash. Stores a deep
## copy so external references to the previous state can't bleed in.
func _adopt_state(new_state: Dictionary) -> void:
	_state = new_state.duplicate(true)
	_hash = WarHasher.hash_value(_state)


## Re-emit engine events in order as individual `event` signals.
func _emit_events(events: Array) -> void:
	for ev in events:
		event.emit(ev)


## Best-effort terminal finalize. Fire-and-forget: the result is telemetry only.
func _complete_async() -> void:
	await _validator.complete_match()


## True when the current state is a terminal (game-over) phase.
func _is_terminal() -> bool:
	var phase: String = _state.get("phase", "")
	return phase == "player_win" or phase == "cpu_win"


## A deterministic-enough local fallback seed for when an online InitMatch fails
## and we must deal offline. Only used on the degraded path.
func _synth_seed() -> String:
	return "local-%d" % int(Time.get_unix_time_from_system() * 1000.0)


## Background validation + reconcile for a submitted action.
##
## `predicted_hash` is the hash of the optimistic state we already showed the
## player; `from_seq` is the apply counter at submit time, used to ignore a
## reconcile that arrives after newer local input (we never rewind past fresher
## optimistic state — the next validation will correct it instead).
func _validate_async(action: Dictionary, predicted_hash: String, from_seq: int) -> void:
	var res: Dictionary = await _validator.validate_action(action, predicted_hash)
	if not res.get("ok", false):
		# Validator hard-rejected (e.g. anti-cheat). Snap if it gave us state.
		var auth_json: String = res.get("authoritative_state", "")
		if not auth_json.is_empty():
			_reconcile_from_json(auth_json)
		else:
			action_rejected.emit(action, res.get("error", "validator_rejected"))
		return
	if res.get("matched", false):
		# Fast-path ACK: optimistic state confirmed. Finalize if it was terminal.
		_maybe_complete()
		return
	# MISMATCH: snap to authoritative state — but only if no newer local action
	# has superseded this one (stale reconciles are dropped).
	if from_seq != _apply_seq:
		return
	_reconcile_from_json(res.get("authoritative_state", ""))
	_maybe_complete()


## Fire CompleteMatch exactly once, and only when the AUTHORITATIVE state (just
## confirmed by an ACK or a reconcile) is terminal. The validator also auto-
## completes on a terminal ValidateAction, so this is a best-effort, idempotent
## finalize — but gated on confirmation so we never close a match the server has
## not actually seen reach game-over.
func _maybe_complete() -> void:
	if _completed_sent or not _is_terminal():
		return
	_completed_sent = true
	_complete_async()


## Adopt an authoritative INITIAL state from canonical JSON (online init-first).
## Unlike `_reconcile_from_json` this is the first state, not a correction, so it
## emits only `state_changed` (no `reconciled` — there is nothing to snap from).
func _adopt_from_json(state_json: String) -> void:
	if state_json.is_empty():
		push_warning("WarMatch: empty authoritative init state")
		return
	var parsed: Variant = JSON.parse_string(state_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("WarMatch: could not parse authoritative init state JSON")
		return
	_adopt_state(parsed)
	state_changed.emit(get_state())


## Parse a canonical-JSON authoritative state, adopt it, and announce the snap.
func _reconcile_from_json(state_json: String) -> void:
	if state_json.is_empty():
		return
	var parsed: Variant = JSON.parse_string(state_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("WarMatch: could not parse authoritative state JSON")
		return
	_adopt_state(parsed)
	var snapshot := get_state()
	state_changed.emit(snapshot)
	reconciled.emit(snapshot)
