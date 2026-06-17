extends Node
##
## WarDebug — headless / LLM / debug control surface over a live WarMatch.
##
## NOTE on the global name: this script is the `WarDebug` AUTOLOAD (project.godot:
## WarDebug = "*res://game/mcp_game_api.gd"). In Godot 4 a script that is
## registered as an autoload singleton MUST NOT also declare `class_name
## WarDebug` — the engine rejects it with "Class hides an autoload singleton".
## The autoload registration already publishes the global identifier `WarDebug`,
## so the pinned `WarDebug` name is fully available everywhere (e.g.
## `WarDebug.new_game(...)`) WITHOUT a redundant `class_name`. We therefore omit
## the `class_name` here on purpose; the autoload IS the contract's `WarDebug`.
##
## Registered as the `WarDebug` AUTOLOAD (see project.godot:
##   WarDebug = "*res://game/mcp_game_api.gd"). It is therefore globally
## reachable from anywhere — UI code, the in-editor console, headless verifier
## scripts, and (the design intent) an LLM/agent driving the game through the
## godot-ai MCP. It owns ONE WarMatch instance and exposes a flat, side-effect-
## explicit API that is trivial to call programmatically.
##
## Why this exists
## ---------------
## The deterministic core (WarEngine + WarHasher) plus WarMatch make the game
## fully drivable WITHOUT any UI. This class is the documented entry point for
## that: a script or agent can deal a seed, push actions, and read back the
## canonical state + hash to assert determinism, reproduce bugs, or play the
## whole match to completion in a headless run.
##
## Determinism note
## ----------------
## Every method here goes through WarMatch → WarEngine, so the state/hash you
## read are exactly the synchronized, validator-comparable values. `get_hash()`
## here equals `WarHasher.hash_value(get_state())` and equals what the TS
## validator computes for the same state. Two runs of the same seed + action
## sequence MUST yield identical hashes; that invariant is what the verifier
## scripts assert.
##
## Typical driving session (GDScript or via MCP batch):
##   WarDebug.new_game("seed-123")
##   WarDebug.do({ "type": "start_round" })
##   WarDebug.do({ "type": "play_special", "id": "peek" })
##   WarDebug.do({ "type": "flip" })
##   WarDebug.do({ "type": "resolve" })
##   var snap := WarDebug.snapshot()   # { hash, phase, state, events_tail, ... }
##

## Re-broadcast of WarMatch.state_changed so external observers (or a UI bound
## to the autoload) can react without holding the WarMatch directly.
signal state_changed(state: Dictionary)
## Re-broadcast of WarMatch.event.
signal event(ev: Dictionary)
## Re-broadcast of WarMatch.reconciled (validator snap-back occurred).
signal reconciled(state: Dictionary)

## The single match this debug surface drives. Created in `_ready`.
var _match: WarMatch = null
## Rolling log of recent engine events for `snapshot()` introspection. Capped
## so a long headless run does not grow unbounded.
var _event_log: Array = []
## Max retained events in `_event_log`.
const EVENT_LOG_CAP := 256


func _ready() -> void:
	_match = WarMatch.new()
	_match.name = "WarMatch"
	add_child(_match)
	_match.state_changed.connect(_on_state_changed)
	_match.event.connect(_on_event)
	_match.reconciled.connect(_on_reconciled)
	# NOTE: networking is opt-in. By default WarDebug runs the match OFFLINE
	# (optimistic-only, no validator), which is exactly what headless/LLM
	# driving and determinism tests want. Call `attach_validator()` to go online.


## Returns the owned WarMatch so advanced callers can wire signals / inject a
## validator directly. Most callers should prefer the methods below.
func match_controller() -> WarMatch:
	return _match


## --- Driving API ---------------------------------------------------------

## Deal a fresh match for `seed`. Equivalent to dispatching a "new_game" action.
## Returns true on success. Clears the event log first so `snapshot()` reflects
## only this match.
func new_game(seed: String) -> bool:
	_event_log.clear()
	return _match.new_game(seed)


## Dispatch a raw action Dictionary (the unified player/CPU action schema):
##   { "type": "start_round" }
##   { "type": "play_special", "id": "steal_tie" }
##   { "type": "flip" } / { "type": "resolve" } / { "type": "ack_war" }
## Returns true if the engine accepted the action (see WarMatch.submit_action).
func do(action: Dictionary) -> bool:
	return _match.submit_action(action)


## Convenience wrappers around WarActions so callers need not know the schema.
## Each returns the same bool as `do`.
func start_round() -> bool:
	return _match.submit_action(WarActions.start_round())

func play_special(id: String) -> bool:
	return _match.submit_action(WarActions.play_special(id))

func flip() -> bool:
	return _match.submit_action(WarActions.flip())

func resolve() -> bool:
	return _match.submit_action(WarActions.resolve())

func ack_war() -> bool:
	return _match.submit_action(WarActions.ack_war())


## --- Introspection API ---------------------------------------------------

## Deep copy of the current game state (the hashed contract Dictionary).
func get_state() -> Dictionary:
	return _match.get_state()


## 64-hex state hash of the current state. Identical to the validator's hash
## for the same state — the primary determinism assertion target.
func get_hash() -> String:
	return _match.get_hash()


## Current phase string ("dealt"|"selected"|"flipped"|"war"|"player_win"|
## "cpu_win"), or "" if no match is active.
func get_phase() -> String:
	var s := _match.get_state()
	return s.get("phase", "")


## True when the match has reached a terminal phase.
func is_over() -> bool:
	var phase := get_phase()
	return phase == "player_win" or phase == "cpu_win"


## A compact, LLM-friendly snapshot for assertions and bug reports. Includes the
## full state plus convenience derivations and the tail of the event log.
func snapshot() -> Dictionary:
	var s := _match.get_state()
	return {
		"seed": s.get("seed", ""),
		"phase": s.get("phase", ""),
		"hash": _match.get_hash(),
		"player_count": (s.get("player_deck", []) as Array).size(),
		"cpu_count": (s.get("cpu_deck", []) as Array).size(),
		"war_depth": s.get("war_depth", 0),
		"pending_special": s.get("pending_special", null),
		"is_over": is_over(),
		"state": s,
		"events_tail": _event_log.slice(maxi(0, _event_log.size() - 16)),
	}


## The full retained event log (capped at EVENT_LOG_CAP). Useful for replaying
## or asserting the exact event sequence a seed produces.
func get_event_log() -> Array:
	return _event_log.duplicate(true)


## --- Networking (opt-in) -------------------------------------------------

## Switch the owned match to ONLINE mode against the given validator client.
## Pass a fully `setup()`/`connect_validator()`-ed WarValidatorClient. Headless
## determinism tests should NOT call this — offline optimistic-only is the
## deterministic, network-free path.
func attach_validator(validator: WarValidatorClient) -> void:
	_match.set_validator(validator)


## Detach any validator and return to offline optimistic-only mode.
func detach_validator() -> void:
	_match.set_validator(null)


## --- Signal relays -------------------------------------------------------

func _on_state_changed(state: Dictionary) -> void:
	state_changed.emit(state)


func _on_event(ev: Dictionary) -> void:
	_event_log.append(ev)
	if _event_log.size() > EVENT_LOG_CAP:
		_event_log = _event_log.slice(_event_log.size() - EVENT_LOG_CAP)
	event.emit(ev)


func _on_reconciled(state: Dictionary) -> void:
	reconciled.emit(state)
