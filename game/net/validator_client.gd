class_name WarValidatorClient
extends Node
##
## WarValidatorClient — high-level client for the authoritative validator.
##
## Position in the stack
## ---------------------
##   WarMatch  (runtime; optimistic local apply)
##      └── WarValidatorClient   (this — RPC semantics + reconcile protocol)
##             └── WarHermesClient   (envelope transport: binary Hermes frames)
##                    └── WarSnapserAuth   (identity / token)
##
## This class exposes the validator's RPC surface
##   war.validator.v1.ValidatorService { InitMatch, ValidateAction, CompleteMatch }
## as friendly async methods, hiding the Hermes envelope plumbing. It speaks the
## SAME determinism contract as the engine: game state and actions cross the wire
## as canonical-JSON STRINGS inside proto string fields, and the validator's
## authority is expressed purely through a 64-hex state hash.
##
## Wire shape
## ----------
## Each RPC is a godobuf-serialized request message (ValidatorPb.*Request) carried
## as the snap-api-proxy payload of a Hermes ClientMessage; the reply is the
## matching *Response message inside a ServerMessage. WarHermesClient frames the
## envelope; this class builds/parses the inner proto and maps it to the result
## Dictionaries WarMatch consumes (whose shape must stay stable).
##
## Optimistic + reconcile protocol (the whole point)
## -------------------------------------------------
##   1. WarMatch applies an action LOCALLY via WarEngine.apply for instant
##      feedback and computes `predicted_hash = WarHasher.hash_value(state)`.
##   2. WarMatch calls `validate_action(action, predicted_hash)`.
##   3. The validator replays the action on its authoritative state and compares
##      hashes:
##        - MATCH  -> { ok=true, matched=true } (fast-path ACK). The client's
##          optimistic state stands; nothing to do.
##        - MISMATCH/REJECT -> { ok=true, matched=false, authoritative_state, ... }
##          OR { ok=false, ... }. The client SNAPS to authoritative_state.
##   4. `init_match(seed)` establishes the server's authoritative starting state
##      AND the match id every later RPC is bound to. The server is the seed
##      authority: pass "" to let it assign one (anti seed-shop).
##
## Offline degradation
## -------------------
## When no transport is attached (pure-offline / headless logic tests) this
## client runs "optimistic-only": every validate call ACKs the predicted hash so
## WarMatch keeps working without a server. A transport that drops mid-match also
## degrades a single validation to an ACK (the connection-level `client_error`
## drives the actual fall-back-to-offline decision higher up).
##

## Fired when InitMatch resolves. `state_json` is the canonical-JSON starting
## state the validator chose for `seed`; `hash` is its state hash.
signal match_initialized(seed: String, state_json: String, hash: String)
## Fired when the client becomes unusable (auth/transport gave up).
signal client_error(reason: String)

## godobuf-generated ValidatorService request/response bindings. Their string
## fields carry canonical-JSON state/actions — the hash domain.
const ValidatorPb := preload("res://net/proto/validator_pb.gd")

## Validator RPC names as routed through the Hermes snap-api-proxy.
const RPC_INIT_MATCH := "InitMatch"
const RPC_VALIDATE_ACTION := "ValidateAction"
const RPC_COMPLETE_MATCH := "CompleteMatch"

## How long an RPC waits for its correlated reply before giving up. Kept slightly
## above the transport's own REQUEST_TIMEOUT_SEC so the transport surfaces a
## timeout first; this is the backstop that guarantees `_call` always resolves
## (a dropped reply must never hang the caller — the online deal awaits it).
const RPC_TIMEOUT_SEC := 12.0

## How long an RPC waits for the socket to finish its handshake before giving up.
## The init-first InitMatch is fired right after connect_validator(), so the first
## RPC routinely races the connect; we wait this long (bailing fast if the connect
## outright fails) rather than instantly reporting the transport unavailable.
const CONNECT_WAIT_SEC := 6.0

## Optional transport. When null, the client runs in OFFLINE optimistic-only
## mode: validate_action always reports a match. Injected via `setup`.
var _hermes: WarHermesClient = null
## Optional identity provider; supplies the token for the transport.
var _auth: WarSnapserAuth = null

## Authoritative match id assigned by InitMatch; every ValidateAction /
## CompleteMatch is bound to it. Empty until InitMatch resolves.
var _match_id: String = ""
## Player id the validator binds this match to (echoed by InitMatch; locally the
## same self-stamped id we put in the transport's ?token=).
var _player_id: String = ""
## request_id -> reply envelope. The transport's `envelope_received` is buffered
## here (it fires regardless of who is awaiting) so `_call` can wait by polling
## with a deadline instead of blocking forever on a signal that never re-fires
## for a dropped/timed-out request.
var _replies: Dictionary = {}
## Set when the socket fails/closes so a pending connect-wait bails immediately
## (e.g. a dead port) instead of waiting out CONNECT_WAIT_SEC. Reset per connect.
var _socket_failed: bool = false


## Wire up dependencies. Either argument may be null:
##   * both null  -> permanent OFFLINE optimistic-only mode (great for tests).
##   * provided   -> ONLINE; `connect_validator()` opens the socket.
func setup(hermes: WarHermesClient = null, auth: WarSnapserAuth = null) -> void:
	_hermes = hermes
	_auth = auth
	if _hermes != null:
		_hermes.envelope_received.connect(_on_envelope)
		_hermes.disconnected.connect(_on_transport_disconnected)
		_hermes.transport_error.connect(_on_transport_error)


## True when this client will actually hit the network. False == offline mode.
func is_online() -> bool:
	return _hermes != null


## The authoritative match id (empty until InitMatch resolves).
func get_match_id() -> String:
	return _match_id


## Bring the transport up: authenticate, then open the Hermes socket. In offline
## mode this resolves immediately. Caller may `await match_initialized` (after
## init_match) regardless of mode.
func connect_validator() -> void:
	if not is_online():
		return
	_socket_failed = false
	if _auth != null:
		if not _auth.is_authenticated() or _auth.is_expired():
			_auth.authenticated.connect(_on_authenticated, CONNECT_ONE_SHOT)
			_auth.auth_failed.connect(_on_auth_failed, CONNECT_ONE_SHOT)
			_auth.login_anonymous()
			return
		_player_id = _auth.get_player_id()
		_hermes.configure(_auth.get_token())
	_hermes.connect_to_validator()


## InitMatch — ask the validator to establish authoritative starting state and a
## match id. Returns:
##   { ok:bool, state_json:String, hash:String, error:String }
##
## OFFLINE mode: returns ok=false with error "offline" — WarMatch falls back to
## its own deterministic deal (identical to the server's by the parity contract).
func init_match(seed: String) -> Dictionary:
	if not is_online():
		return {"ok": false, "state_json": "", "hash": "", "error": "offline"}
	var req := ValidatorPb.InitMatchRequest.new()
	req.set_seed(seed)
	req.set_player_id(_player_id)
	var reply := await _call(RPC_INIT_MATCH, req.to_bytes())
	if not reply.get("ok", false):
		return {"ok": false, "state_json": "", "hash": "", "error": reply.get("error", "init_failed")}
	var resp := ValidatorPb.InitMatchResponse.new()
	if resp.from_bytes(reply.get("bytes", PackedByteArray())) != ValidatorPb.PB_ERR.NO_ERRORS:
		return {"ok": false, "state_json": "", "hash": "", "error": "malformed_init_response"}
	if not resp.get_error().is_empty():
		return {"ok": false, "state_json": "", "hash": "", "error": resp.get_error()}
	# Bind every later RPC to the server-assigned match + player.
	_match_id = resp.get_match_id()
	_player_id = resp.get_player_id()
	var state_json := resp.get_state_json()
	var hash := resp.get_hash()
	# Announce the EFFECTIVE seed: when the caller passed "" the server assigned
	# one (anti seed-shop), and it lives inside the authoritative state — surface
	# that, not the caller's empty string, so consumers can correlate the match.
	var effective_seed := seed
	if effective_seed.is_empty():
		var parsed: Variant = JSON.parse_string(state_json)
		if typeof(parsed) == TYPE_DICTIONARY:
			effective_seed = str((parsed as Dictionary).get("seed", ""))
	match_initialized.emit(effective_seed, state_json, hash)
	return {"ok": true, "state_json": state_json, "hash": hash, "error": ""}


## ValidateAction — submit an action plus the client's PREDICTED state hash and
## get the authoritative verdict back. Returns the reconcile contract:
##   {
##     ok:bool,                      # action accepted (transport + rules)
##     matched:bool,                 # predicted_hash == authoritative_hash
##     authoritative_state:String,   # canonical-JSON; only set when !matched
##     authoritative_hash:String,
##     error:String,
##   }
##
## OFFLINE mode (and a dropped transport mid-match): returns matched=true so the
## optimistic local state stands.
func validate_action(action: Dictionary, predicted_hash: String) -> Dictionary:
	if not is_online():
		return _ack(predicted_hash)
	if _match_id.is_empty():
		# InitMatch has not resolved yet — stay optimistic rather than firing an
		# unbound ValidateAction the server would reject.
		push_warning("WarValidatorClient: validate before InitMatch; ACKing optimistically.")
		return _ack(predicted_hash)
	var req := ValidatorPb.ValidateActionRequest.new()
	req.set_match_id(_match_id)
	req.set_player_id(_player_id)
	req.set_action_json(_encode_action(action))
	req.set_predicted_hash(predicted_hash)
	var reply := await _call(RPC_VALIDATE_ACTION, req.to_bytes())
	if not reply.get("ok", false):
		# Transport-level failure: we cannot confirm, so trust local optimism.
		# (Connection loss surfaces separately via `client_error` -> go offline.)
		push_warning("WarValidatorClient: validate transport error (%s); ACKing optimistically." % reply.get("error", ""))
		return _ack(predicted_hash)
	var resp := ValidatorPb.ValidateActionResponse.new()
	if resp.from_bytes(reply.get("bytes", PackedByteArray())) != ValidatorPb.PB_ERR.NO_ERRORS:
		return _ack(predicted_hash)
	if not resp.get_ok():
		# Rules engine on the server rejected the move (anti-cheat / divergence).
		# Hand back the authoritative state so WarMatch can snap to it.
		return {
			"ok": false, "matched": false,
			"authoritative_state": resp.get_authoritative_state_json(),
			"authoritative_hash": resp.get_hash(),
			"error": resp.get_error(),
		}
	var matched := resp.get_hash_matched()
	return {
		"ok": true,
		"matched": matched,
		# Only carry the full state on the slow (mismatch) path to save bytes.
		"authoritative_state": "" if matched else resp.get_authoritative_state_json(),
		"authoritative_hash": resp.get_hash(),
		"error": "",
	}


## CompleteMatch — finalize the bound match (telemetry / anti-cheat). Best-effort.
## Returns { ok:bool, final_phase:String, error:String }.
func complete_match() -> Dictionary:
	if not is_online() or _match_id.is_empty():
		return {"ok": true, "final_phase": "", "error": ""}
	var req := ValidatorPb.CompleteMatchRequest.new()
	req.set_match_id(_match_id)
	req.set_player_id(_player_id)
	var reply := await _call(RPC_COMPLETE_MATCH, req.to_bytes())
	if not reply.get("ok", false):
		return {"ok": false, "final_phase": "", "error": reply.get("error", "complete_failed")}
	var resp := ValidatorPb.CompleteMatchResponse.new()
	if resp.from_bytes(reply.get("bytes", PackedByteArray())) != ValidatorPb.PB_ERR.NO_ERRORS:
		return {"ok": false, "final_phase": "", "error": "malformed_complete_response"}
	return {"ok": resp.get_error().is_empty(), "final_phase": resp.get_final_phase(), "error": resp.get_error()}


## A fast-path ACK result (optimistic state confirmed).
func _ack(predicted_hash: String) -> Dictionary:
	return {
		"ok": true, "matched": true,
		"authoritative_state": "", "authoritative_hash": predicted_hash,
		"error": "",
	}


## Issue one RPC over Hermes and await its correlated reply. `request_bytes` is
## an already-serialized request proto. Returns the transport envelope:
##   { ok:bool, status_code:int, status_message:String, bytes:PackedByteArray, error:String }
## where `ok` means the server returned status_code 0 (transport success); the
## per-method response proto is in `bytes`.
##
## The reply is buffered by `_on_envelope`; we poll for it with a deadline so a
## dropped or timed-out request resolves to a transport error instead of hanging
## the awaiting coroutine forever.
func _call(method: String, request_bytes: PackedByteArray) -> Dictionary:
	if _hermes == null:
		return _transport_err("transport_unavailable")
	var tree := get_tree()
	# The socket may still be completing its handshake (the init-first InitMatch
	# fires right after connect_validator()). Wait briefly for it to open, bailing
	# fast if the connection fails outright (dead port / refused).
	if not _hermes.is_open():
		if tree == null:
			return _transport_err("transport_unavailable")
		var connect_deadline := Time.get_ticks_msec() + int(CONNECT_WAIT_SEC * 1000.0)
		while not _hermes.is_open():
			if _socket_failed or Time.get_ticks_msec() >= connect_deadline:
				return _transport_err("transport_unavailable")
			await tree.process_frame
	var request_id := _hermes.send_rpc(method, request_bytes)
	if request_id.is_empty():
		return _transport_err("send_failed")
	if tree == null:
		# Not in the scene tree (shouldn't happen in normal use): fall back to a
		# single signal wait rather than busy-spin without a frame source.
		var got: Array = await _hermes.envelope_received
		return _normalize_reply(got[1] if got.size() > 1 else null)
	var deadline := Time.get_ticks_msec() + int(RPC_TIMEOUT_SEC * 1000.0)
	while not _replies.has(request_id):
		if Time.get_ticks_msec() >= deadline:
			return _transport_err("timeout")
		await tree.process_frame
	var payload: Variant = _replies[request_id]
	_replies.erase(request_id)
	return _normalize_reply(payload)


## Buffer an inbound reply by its correlation id so `_call` can pick it up. Drops
## replies with no usable id (e.g. a server bad-frame reply carries request_id "").
func _on_envelope(request_id: String, payload: Variant) -> void:
	if request_id.is_empty():
		return
	_replies[request_id] = payload


## Coerce a buffered reply payload into the transport-envelope contract, tagging
## a non-OK reply's `error` from its status message.
func _normalize_reply(payload: Variant) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return _transport_err("malformed_payload")
	var dict: Dictionary = payload
	if not dict.get("ok", false):
		dict["error"] = dict.get("status_message", "rpc_error")
	return dict


## A uniform transport-failure envelope (no server reply / unusable reply).
func _transport_err(reason: String) -> Dictionary:
	return {"ok": false, "status_code": -1, "status_message": reason, "bytes": PackedByteArray(), "error": reason}


## JSON-encode an action for the wire. Actions are NOT in the hash domain (only
## state is hashed); the server merely parses { type, ...args } and re-applies it
## to its authoritative state, so plain JSON round-trips the fields faithfully.
func _encode_action(action: Dictionary) -> String:
	return JSON.stringify(action)


func _on_authenticated(player_id: String, token: String) -> void:
	_player_id = player_id
	if _hermes != null:
		_hermes.configure(token)
		_hermes.connect_to_validator()


func _on_auth_failed(reason: String) -> void:
	client_error.emit("auth_failed: %s" % reason)


func _on_transport_disconnected(clean: bool) -> void:
	# A closed socket invalidates any buffered replies for the old connection and
	# releases any pending connect-wait.
	_replies.clear()
	_socket_failed = true
	if not clean:
		client_error.emit("transport_disconnected")


func _on_transport_error(reason: String) -> void:
	_socket_failed = true
	client_error.emit("transport: %s" % reason)
