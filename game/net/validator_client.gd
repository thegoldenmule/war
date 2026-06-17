class_name WarValidatorClient
extends Node
##
## WarValidatorClient — high-level client for the authoritative validator.
##
## Position in the stack
## ---------------------
##   WarMatch  (runtime; optimistic local apply)
##      └── WarValidatorClient   (this — RPC semantics + reconcile protocol)
##             └── WarHermesClient   (envelope transport)
##                    └── WarSnapserAuth   (identity / token)
##
## This class exposes the validator's gRPC surface
##   war.validator.v1.ValidatorService { InitMatch, ValidateAction, CompleteMatch }
## as friendly async methods, hiding the Hermes envelope plumbing. It speaks
## the SAME determinism contract as the engine: game state and actions cross
## the wire as canonical-JSON STRINGS, and the validator's authority is
## expressed purely through a 64-hex state hash.
##
## Optimistic + reconcile protocol (the whole point)
## -------------------------------------------------
##   1. WarMatch applies an action LOCALLY via WarEngine.apply for instant
##      feedback and computes `predicted_hash = WarHasher.hash_value(state)`.
##   2. WarMatch calls `validate_action(action, predicted_hash)`.
##   3. The validator replays the action on its authoritative state and
##      compares hashes:
##        - MATCH  -> returns { ok=true, matched=true } (fast-path ACK). The
##          client's optimistic state stands; nothing to do.
##        - MISMATCH/REJECT -> returns { ok=true, matched=false,
##          authoritative_state, authoritative_hash } OR
##          { ok=false, error }. The client SNAPS to authoritative_state
##          (WarMatch.reconciled fires).
##   4. `init_match(seed)` establishes the server's starting state for the
##      seed so step 3 has something to diff against.
##
## The result Dictionaries returned here are the contract WarMatch consumes;
## keep their shape stable.
##
## Skeleton scope
## --------------
## RPC method names, request/response shapes, request correlation, and the
## reconcile decision logic are real. The actual byte exchange is delegated to
## WarHermesClient and remains stubbed there behind `# TODO(skeleton)`. When no
## transport is attached (pure-offline / headless logic tests) this client
## degrades gracefully to "optimistic-only" — every validate call ACKs the
## predicted hash so WarMatch keeps working without a server.
##

## Fired when InitMatch resolves. `state_json` is the canonical-JSON starting
## state the validator chose for `seed`; `hash` is its state hash.
signal match_initialized(seed: String, state_json: String, hash: String)
## Fired when the client becomes unusable (auth/transport gave up).
signal client_error(reason: String)

## Validator RPC names as routed through the Hermes snap-api-proxy.
const RPC_INIT_MATCH := "InitMatch"
const RPC_VALIDATE_ACTION := "ValidateAction"
const RPC_COMPLETE_MATCH := "CompleteMatch"

## Optional transport. When null, the client runs in OFFLINE optimistic-only
## mode: validate_action always reports a match. Injected via `setup`.
var _hermes: WarHermesClient = null
## Optional identity provider; supplies the token for the transport.
var _auth: WarSnapserAuth = null
## True once we have an open transport (or have decided to run offline).
var _ready_for_rpc: bool = false


## Wire up dependencies. Either argument may be null:
##   * both null  -> permanent OFFLINE optimistic-only mode (great for tests).
##   * provided   -> ONLINE; `connect_validator()` opens the socket.
func setup(hermes: WarHermesClient = null, auth: WarSnapserAuth = null) -> void:
	_hermes = hermes
	_auth = auth
	if _hermes != null:
		_hermes.connected.connect(_on_transport_connected)
		_hermes.disconnected.connect(_on_transport_disconnected)
		_hermes.transport_error.connect(_on_transport_error)


## True when this client will actually hit the network. False == offline mode.
func is_online() -> bool:
	return _hermes != null


## Bring the transport up: authenticate, then open the Hermes socket. In
## offline mode this resolves immediately. Caller may `await match_initialized`
## (after init_match) regardless of mode.
func connect_validator() -> void:
	if not is_online():
		_ready_for_rpc = true
		return
	if _auth != null:
		if not _auth.is_authenticated() or _auth.is_expired():
			_auth.authenticated.connect(_on_authenticated, CONNECT_ONE_SHOT)
			_auth.auth_failed.connect(_on_auth_failed, CONNECT_ONE_SHOT)
			_auth.login_anonymous()
			return
		_hermes.configure(_auth.get_token())
	_hermes.connect_to_validator()


## InitMatch — ask the validator to establish authoritative starting state for
## `seed`. Returns a result Dictionary:
##   { ok:bool, state_json:String, hash:String, error:String }
##
## OFFLINE mode: returns ok=false with error "offline" — WarMatch should fall
## back to its own deterministic deal (which, by the determinism parity
## contract, is identical to what the server would have produced).
func init_match(seed: String) -> Dictionary:
	if not is_online():
		return {"ok": false, "state_json": "", "hash": "", "error": "offline"}
	var body := {"seed": seed}
	var reply := await _rpc(RPC_INIT_MATCH, body)
	if not reply.get("ok", false):
		return {"ok": false, "state_json": "", "hash": "", "error": reply.get("error", "init_failed")}
	var state_json: String = reply.get("state_json", "")
	var hash: String = reply.get("hash", "")
	match_initialized.emit(seed, state_json, hash)
	return {"ok": true, "state_json": state_json, "hash": hash, "error": ""}


## ValidateAction — submit an action plus the client's PREDICTED state hash and
## get the authoritative verdict back. Returns the reconcile contract:
##   {
##     ok:bool,                 # transport/validation succeeded
##     matched:bool,            # predicted_hash == authoritative_hash (fast path)
##     authoritative_state:String,  # canonical-JSON; only meaningful when !matched
##     authoritative_hash:String,
##     error:String,
##   }
##
## OFFLINE mode: always returns matched=true (optimistic-only). This keeps
## WarMatch on its happy path during headless logic tests.
##
## `action` is the action Dictionary (will be canonical-JSON-encoded on the
## wire). `predicted_hash` is WarHasher.hash_value(local_state_after_apply).
func validate_action(action: Dictionary, predicted_hash: String) -> Dictionary:
	if not is_online():
		return {
			"ok": true, "matched": true,
			"authoritative_state": "", "authoritative_hash": predicted_hash,
			"error": "",
		}
	# Action travels as a canonical-JSON STRING; the validator re-parses it in
	# the hash domain. WarActions.to_json keeps client/validator encodings
	# identical so the same bytes hash the same on both sides.
	var action_json := _encode_action(action)
	var body := {"action": action_json, "predicted_hash": predicted_hash}
	var reply := await _rpc(RPC_VALIDATE_ACTION, body)
	if not reply.get("ok", false):
		return {
			"ok": false, "matched": false,
			"authoritative_state": "", "authoritative_hash": "",
			"error": reply.get("error", "validate_failed"),
		}
	var server_hash: String = reply.get("hash", "")
	var matched := server_hash == predicted_hash
	return {
		"ok": true,
		"matched": matched,
		# Only carry the full state on the slow (mismatch) path to save bytes.
		"authoritative_state": "" if matched else reply.get("state_json", ""),
		"authoritative_hash": server_hash,
		"error": "",
	}


## CompleteMatch — report terminal result for telemetry/anti-cheat. Best-effort
## (fire-and-forget semantics are fine). Returns { ok:bool, error:String }.
func complete_match(seed: String, final_hash: String, phase: String) -> Dictionary:
	if not is_online():
		return {"ok": true, "error": ""}
	var body := {"seed": seed, "final_hash": final_hash, "phase": phase}
	var reply := await _rpc(RPC_COMPLETE_MATCH, body)
	return {"ok": reply.get("ok", false), "error": reply.get("error", "")}


## Issue an RPC over Hermes and await its correlated reply. Returns the decoded
## inner payload as a Dictionary, normalized to always carry an `ok` key.
func _rpc(method: String, body: Dictionary) -> Dictionary:
	if _hermes == null or not _hermes.is_open():
		return {"ok": false, "error": "transport_unavailable"}
	var request_id := _hermes.send_envelope(method, body)
	if request_id.is_empty():
		return {"ok": false, "error": "send_failed"}
	# Await the matching reply; ignore replies for other in-flight requests.
	while true:
		var got: Array = await _hermes.envelope_received
		var got_id: String = got[0]
		var payload: Variant = got[1]
		if got_id != request_id:
			continue
		if typeof(payload) != TYPE_DICTIONARY:
			return {"ok": false, "error": "malformed_payload"}
		var dict: Dictionary = payload
		if not dict.has("ok"):
			dict["ok"] = true
		return dict
	# Unreachable; satisfies the static analyzer.
	return {"ok": false, "error": "unreachable"}


## Canonical-JSON encode an action for the wire. Prefer the shared WarActions
## encoder so client and validator agree byte-for-byte; fall back to plain
## JSON.stringify if that helper is unavailable in a stripped build.
func _encode_action(action: Dictionary) -> String:
	# TODO(skeleton): route through WarActions canonical encoder once present,
	#   e.g. return WarActions.to_canonical_json(action)
	# The contract guarantees WarActions produces json-stable-stringify output.
	return JSON.stringify(action)


func _on_authenticated(_player_id: String, token: String) -> void:
	if _hermes != null:
		_hermes.configure(token)
		_hermes.connect_to_validator()


func _on_auth_failed(reason: String) -> void:
	_ready_for_rpc = false
	client_error.emit("auth_failed: %s" % reason)


func _on_transport_connected() -> void:
	_ready_for_rpc = true


func _on_transport_disconnected(clean: bool) -> void:
	_ready_for_rpc = false
	if not clean:
		client_error.emit("transport_disconnected")


func _on_transport_error(reason: String) -> void:
	client_error.emit("transport: %s" % reason)
