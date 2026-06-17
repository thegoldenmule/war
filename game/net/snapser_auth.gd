class_name WarSnapserAuth
extends Node
##
## WarSnapserAuth — anonymous Snapser authentication for the War client.
##
## Responsibility
## --------------
## Produces the `player_id` / session token that the rest of the networking
## stack needs in order to talk to the authoritative validator:
##
##   * In PRODUCTION the token is a Snapser session token obtained via an
##     anonymous login. Snapser's gateway validates the token on every
##     request and stamps a trusted `User-Id` header that the validator binds
##     to `player_id`. The client never sets `User-Id` itself.
##
##   * LOCALLY (no Snapser gateway in front of the validator) there is no
##     real auth. We self-stamp: we generate a stable, device-local player id
##     and hand it straight to the transport, which passes it as the
##     `?token=<player-id>` query parameter on the Hermes WebSocket URL. The
##     local validator treats that query param as the (untrusted) caller
##     identity so the client has ONE codepath in both environments.
##
## This Node owns NO game logic and NO presentation. It is a thin identity
## provider consumed by `WarHermesClient` / `WarValidatorClient`.
##
## Flow (production)
## -----------------
##   1. login_anonymous()  -> POST {device_id} to the Snapser auth snap.
##   2. Snapser returns {session_token, user_id, expires_at}.
##   3. We cache them; `get_token()` returns session_token, `get_player_id()`
##      returns user_id.
##   4. Tokens expire; `is_expired()` lets the transport refresh on reconnect.
##
## Flow (local)
## ------------
##   1. login_anonymous() synthesizes a device-stable id (see
##      `_make_local_player_id`) and uses it as BOTH player id and token.
##   2. No network call is made; the signal fires on the next idle frame so
##      callers can `await` it uniformly with the production path.
##

## Emitted when a login attempt resolves successfully. `player_id` is the
## identity the validator will bind actions to.
signal authenticated(player_id: String, token: String)

## Emitted when a login attempt fails (network error, rejected device, etc).
signal auth_failed(reason: String)

## Selects which identity strategy `login_anonymous()` uses. Local mode never
## hits the network; remote mode talks to the Snapser auth snap.
enum Mode { LOCAL, REMOTE }

## Default Snapser auth endpoint (overridden per deployment). Only consulted
## in REMOTE mode. The local validator does not use this.
const DEFAULT_AUTH_BASE_URL := "https://gateway.snapser.example/v1/auth"

## Persisted device-id key so the same machine reuses one anonymous identity
## across launches (keeps local matches/saves stable).
const _DEVICE_ID_SETTING := "war/device_id"

@export var mode: Mode = Mode.LOCAL
@export var auth_base_url: String = DEFAULT_AUTH_BASE_URL

## Last successful identity. Empty until `login_anonymous()` resolves.
var _player_id: String = ""
var _token: String = ""
## Unix seconds at which `_token` stops being valid (0 == never / local).
var _expires_at: int = 0


## Returns the current player id, or "" if not yet authenticated.
func get_player_id() -> String:
	return _player_id


## Returns the current session token (REMOTE) or the self-stamped player id
## (LOCAL). This is exactly the value the transport places in `?token=`.
func get_token() -> String:
	return _token


## True once we hold a usable identity. Transport should gate connects on this.
func is_authenticated() -> bool:
	return not _token.is_empty()


## True when a REMOTE token has aged out and a refresh is required. LOCAL
## tokens never expire (returns false).
func is_expired() -> bool:
	if mode == Mode.LOCAL or _expires_at == 0:
		return false
	return Time.get_unix_time_from_system() >= float(_expires_at)


## Begin (or refresh) an anonymous login. Idempotent-ish: if already
## authenticated and not expired, re-emits the cached identity. The caller may
## `await authenticated` in both LOCAL and REMOTE modes.
func login_anonymous() -> void:
	if is_authenticated() and not is_expired():
		# Re-announce cached identity on the next frame for await-symmetry.
		_emit_authenticated_deferred()
		return
	if mode == Mode.LOCAL:
		_login_local()
	else:
		_login_remote()


## LOCAL: synthesize a device-stable id and use it as the token verbatim.
func _login_local() -> void:
	_player_id = _make_local_player_id()
	_token = _player_id
	_expires_at = 0
	_emit_authenticated_deferred()


## REMOTE: anonymous login against the Snapser auth snap.
##
## The wire shape is intentionally documented here so the transport author and
## the validator author agree on it; the actual HTTPRequest is deferred.
func _login_remote() -> void:
	# TODO(skeleton): perform the anonymous login HTTP exchange:
	#   POST {auth_base_url}/anonymous
	#     body: { "device_id": <stable device id> }
	#     resp: { "session_token": String, "user_id": String, "expires_at": int }
	# On success:
	#   _player_id = resp.user_id
	#   _token     = resp.session_token
	#   _expires_at= resp.expires_at
	#   authenticated.emit(_player_id, _token)
	# On failure:
	#   auth_failed.emit(<reason>)
	#
	# Until wired, fail loudly rather than silently behaving like LOCAL so we
	# never ship a build that thinks it authenticated when it did not.
	push_warning("WarSnapserAuth: REMOTE login not yet wired; see TODO(skeleton).")
	auth_failed.emit("remote_auth_not_implemented")


## Build a stable, device-local anonymous player id of the form
## "local-<8 hex>". Persisted into project settings so it survives relaunch.
func _make_local_player_id() -> String:
	if ProjectSettings.has_setting(_DEVICE_ID_SETTING):
		var existing: String = str(ProjectSettings.get_setting(_DEVICE_ID_SETTING))
		if not existing.is_empty():
			return existing
	# Derive from a fresh GUID so two devices never collide.
	var raw := str(Time.get_unix_time_from_system()) + "-" + str(randi())
	var suffix := str(hash(raw)).replace("-", "")
	var pid := "local-" + suffix.substr(0, 8)
	ProjectSettings.set_setting(_DEVICE_ID_SETTING, pid)
	return pid


## Fire `authenticated` on the next idle frame so LOCAL and REMOTE callers can
## `await` it identically.
func _emit_authenticated_deferred() -> void:
	authenticated.emit.call_deferred(_player_id, _token)
