extends SceneTree
## VERIFY online_lifecycle — the view-tier online connect lifecycle + degradation.
##
## Covers the Phase B steps the wire-only verifiers do not: the Round Director's
## connect_online() handshake hold, server-confirmed online play, and the
## graceful degrade-to-offline path (a dead port must never freeze the board).
##
##   1. DEAD PORT  — connect_online() against ws://127.0.0.1:9 holds input at BOOT
##                   during the handshake, then DEGRADES to a playable offline
##                   deal (DEAL_PROMPT, unlocked) — never a locked board.
##   2. ONLINE     — connect_online() against the running validator confirms
##                   online (InitMatch assigns a match id) and adopts the
##                   authoritative server-dealt t0 state.
##
## Part 2 REQUIRES the validator running:  tools/run_validator.sh  (serves :5555)
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_online_lifecycle.gd

const Director := preload("res://ui/round_director.gd")
const HermesClient := preload("res://net/hermes_client.gd")
const SnapserAuth := preload("res://net/snapser_auth.gd")
const ValidatorClient := preload("res://net/validator_client.gd")

const DEAD_PORT_WS := "ws://127.0.0.1:9"
const LOCAL_WS := "ws://localhost:5555/hermes/ws"
const SETTLE_TIMEOUT_MS := 10000


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY online_lifecycle: PASS")
	else:
		print("VERIFY online_lifecycle: FAIL %s" % reason)
	quit()


func _run() -> String:
	var r1 := await _dead_port_degrades()
	if r1 != "":
		return r1
	var r2 := await _online_confirms()
	if r2 != "":
		return r2
	var r3 := await _reconnect_reinits()
	if r3 != "":
		return r3
	return ""


## A validator client wired to `url`, parented under the tree so its socket pump
## and frame-poll run.
func _make_client(url: String) -> Node:
	var auth := SnapserAuth.new()
	auth.mode = SnapserAuth.Mode.LOCAL
	var hermes := HermesClient.new()
	hermes.base_url = url
	var client := ValidatorClient.new()
	root.add_child(auth)
	root.add_child(hermes)
	root.add_child(client)
	client.setup(hermes, auth)
	return client


# --- 1. DEAD PORT -> degrade to offline --------------------------------------
func _dead_port_degrades() -> String:
	var dir := Director.new()
	root.add_child(dir)
	var seen := {"phase": "", "beat": -1, "locked": true}
	dir.view_state.connect(func(s): seen["phase"] = String(s.get("phase", "")))
	dir.beat.connect(func(b, _e, locked): seen["beat"] = b; seen["locked"] = locked)
	await process_frame  # _ready offline-deals at DEAL_PROMPT

	dir.connect_online(_make_client(DEAD_PORT_WS))
	# connect_online holds input at BOOT synchronously before the async deal.
	if seen["beat"] != Director.Beat.BOOT or not seen["locked"]:
		return "dead-port: connect_online did not hold input at a locked BOOT (beat=%d locked=%s)" % [seen["beat"], seen["locked"]]

	# It must then degrade to a playable offline deal — never stay locked.
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MS
	while not (seen["phase"] == "dealt" and seen["beat"] == Director.Beat.DEAL_PROMPT and not seen["locked"]):
		if Time.get_ticks_msec() > deadline:
			return "dead-port: never degraded to an unlocked offline deal (beat=%d phase=%s locked=%s)" % [seen["beat"], seen["phase"], seen["locked"]]
		await process_frame
	dir.queue_free()
	return ""


# --- 2. GOOD PORT -> confirmed online ----------------------------------------
func _online_confirms() -> String:
	var dir := Director.new()
	root.add_child(dir)
	var seen := {"phase": ""}
	dir.view_state.connect(func(s): seen["phase"] = String(s.get("phase", "")))
	await process_frame

	var client := _make_client(LOCAL_WS)
	dir.connect_online(client)

	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MS
	while not (not client.get_match_id().is_empty() and seen["phase"] == "dealt"):
		if Time.get_ticks_msec() > deadline:
			return "online: InitMatch never confirmed (match_id_empty=%s phase=%s) — is the validator running?" % [client.get_match_id().is_empty(), seen["phase"]]
		await process_frame
	dir.queue_free()
	return ""


# --- 3. RECONNECT -> degrade then re-init back online ------------------------
func _reconnect_reinits() -> String:
	var dir := Director.new()
	root.add_child(dir)
	var seen := {"phase": ""}
	dir.view_state.connect(func(s): seen["phase"] = String(s.get("phase", "")))
	await process_frame

	# Go online once.
	var client_a := _make_client(LOCAL_WS)
	dir.connect_online(client_a)
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MS
	while client_a.get_match_id().is_empty():
		if Time.get_ticks_msec() > deadline:
			return "reconnect: first InitMatch never confirmed"
		await process_frame
	var match_a: String = client_a.get_match_id()

	# Degrade to offline (as on a socket drop) — the board must stay playable.
	dir.go_offline()
	await process_frame

	# Re-init back online on a fresh connection — a NEW match is established with
	# no double-apply, and play resumes at a dealt phase.
	var client_b := _make_client(LOCAL_WS)
	dir.connect_online(client_b)
	deadline = Time.get_ticks_msec() + SETTLE_TIMEOUT_MS
	while not (not client_b.get_match_id().is_empty() and seen["phase"] == "dealt"):
		if Time.get_ticks_msec() > deadline:
			return "reconnect: re-init never went back online (match_id_empty=%s phase=%s)" % [client_b.get_match_id().is_empty(), seen["phase"]]
		await process_frame
	if client_b.get_match_id() == match_a:
		return "reconnect: re-init reused the old match id (expected a fresh match)"
	dir.queue_free()
	return ""
