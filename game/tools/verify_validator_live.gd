extends SceneTree
## VERIFY validator_live — the FULL online wire, godobuf client <-> protobufjs server.
##
## Unlike verify_hermes_proto (which round-trips the bindings against THEMSELVES),
## this drives the real stack against a RUNNING validator:
##
##   WarValidatorClient -> WarHermesClient -> ws://localhost:5555/hermes/ws
##                                                  └── @war/validator (Bun/protobufjs)
##
## It proves the two protobuf implementations agree on the byte layout AND that
## determinism parity holds across the wire:
##
##   1. CONNECT   — anonymous (local) auth + Hermes socket open.
##   2. INIT      — InitMatch returns a match id + authoritative t0 state whose
##                  hash our own engine reproduces (parity at t0).
##   3. HONEST    — walk a full game; each step's locally-predicted hash must ACK
##                  (hash_matched) — the optimistic fast path end-to-end.
##   4. TAMPER    — a deliberately wrong predicted hash must be REJECTED as a
##                  mismatch, with the server's authoritative state handed back.
##   5. COMPLETE  — CompleteMatch finalizes cleanly.
##
## REQUIRES the validator running:  tools/run_validator.sh   (serves :5555)
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_validator_live.gd

const HermesClient := preload("res://net/hermes_client.gd")
const SnapserAuth := preload("res://net/snapser_auth.gd")
const ValidatorClient := preload("res://net/validator_client.gd")
const WarEngineS := preload("res://logic/engine.gd")
const WarHasherS := preload("res://logic/hasher.gd")
const WarActionsS := preload("res://logic/actions.gd")
const ValidatorPb := preload("res://net/proto/validator_pb.gd")

const VALIDATOR_URL := "ws://localhost:5555/hermes/ws"
const CONNECT_TIMEOUT_MS := 6000
## A 64-zero hex string: a syntactically valid hash that can never match a real one.
const BOGUS_HASH := "0000000000000000000000000000000000000000000000000000000000000000"


func _initialize() -> void:
	_main()


func _main() -> void:
	var reason := await _run()
	if reason == "":
		print("VERIFY validator_live: PASS")
	else:
		print("VERIFY validator_live: FAIL %s" % reason)
	quit()


func _run() -> String:
	# --- 1. CONNECT -----------------------------------------------------------
	var auth := SnapserAuth.new()
	auth.mode = SnapserAuth.Mode.LOCAL
	var hermes := HermesClient.new()
	hermes.base_url = VALIDATOR_URL
	var client := ValidatorClient.new()
	root.add_child(auth)
	root.add_child(hermes)
	root.add_child(client)
	await process_frame

	client.setup(hermes, auth)
	client.connect_validator()

	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while not hermes.is_open():
		if Time.get_ticks_msec() > deadline:
			return "transport never opened to %s — is the validator running (tools/run_validator.sh)?" % VALIDATOR_URL
		await process_frame

	# --- 2. INIT --------------------------------------------------------------
	var init_res: Dictionary = await client.init_match("live-seed-honest")
	if not init_res.get("ok", false):
		return "init_match failed: %s" % init_res.get("error", "")
	if client.get_match_id().is_empty():
		return "init_match returned an empty match_id"
	var state_json: String = init_res.get("state_json", "")
	var server_hash: String = init_res.get("hash", "")
	var t0: Variant = JSON.parse_string(state_json)
	if typeof(t0) != TYPE_DICTIONARY:
		return "init state_json did not parse to a Dictionary"
	var local_t0_hash: String = WarHasherS.hash_value(t0)
	if local_t0_hash != server_hash:
		return "t0 hash parity broke (local=%s server=%s)" % [local_t0_hash, server_hash]

	# --- 3. HONEST WALK -------------------------------------------------------
	# Drive a full game with correctly-predicted hashes; every step must ACK.
	var cur: Dictionary = t0
	var steps := 0
	for _i in 60:
		var phase: String = str(cur.get("phase", ""))
		if phase == "player_win" or phase == "cpu_win":
			break
		var action := _next_action(phase)
		if action.is_empty():
			return "no scripted action for phase '%s'" % phase
		var applied: Dictionary = WarEngineS.apply(cur, action)
		if not applied.get("ok", false):
			return "local engine rejected %s at step %d (phase %s): %s" % [action.get("type", "?"), steps, phase, applied.get("error", "")]
		var next_state: Dictionary = applied.get("state", {})
		var predicted: String = WarHasherS.hash_value(next_state)
		var vres: Dictionary = await client.validate_action(action, predicted)
		if not vres.get("ok", false):
			return "validate hard-rejected %s at step %d: %s" % [action.get("type", "?"), steps, vres.get("error", "")]
		if not vres.get("matched", false):
			return "honest MISMATCH at step %d (phase %s -> %s): server=%s predicted=%s" % [steps, phase, action.get("type", "?"), vres.get("authoritative_hash", ""), predicted]
		cur = next_state
		steps += 1
	if steps == 0:
		return "honest walk made no progress (t0 already terminal?)"

	# --- 4. TAMPER ------------------------------------------------------------
	# Fresh match; send a real action with a bogus predicted hash. The server must
	# detect the mismatch and hand back its authoritative state to snap to.
	var t_init: Dictionary = await client.init_match("live-seed-tamper")
	if not t_init.get("ok", false):
		return "tamper init_match failed: %s" % t_init.get("error", "")
	var t_state: Variant = JSON.parse_string(t_init.get("state_json", ""))
	if typeof(t_state) != TYPE_DICTIONARY:
		return "tamper init state did not parse"
	var t_action := WarActionsS.start_round()
	var tamper: Dictionary = await client.validate_action(t_action, BOGUS_HASH)
	if not tamper.get("ok", false):
		return "tamper validate was hard-rejected (expected a soft mismatch): %s" % tamper.get("error", "")
	if tamper.get("matched", false):
		return "tamper validate ACKed a bogus hash — mismatch not detected"
	var auth_json: String = tamper.get("authoritative_state", "")
	if auth_json.is_empty():
		return "tamper mismatch carried no authoritative state"
	var auth_state: Variant = JSON.parse_string(auth_json)
	if typeof(auth_state) != TYPE_DICTIONARY:
		return "tamper authoritative_state did not parse"
	# The authoritative state must be the genuine start_round result for this seed.
	var expected: Dictionary = WarEngineS.apply(t_state, t_action).get("state", {})
	if WarHasherS.hash_value(auth_state) != WarHasherS.hash_value(expected):
		return "tamper authoritative_state is not the expected start_round result"

	# --- 4b. NOT_FOUND (match-binding) ----------------------------------------
	# A ValidateAction against an unknown match must be rejected at the transport
	# (status_code != 0) — the stateful, player-bound server requires a real
	# match_id, so a missing/forged one cannot advance any match.
	var bogus := ValidatorPb.ValidateActionRequest.new()
	bogus.set_match_id("m_does_not_exist")
	bogus.set_player_id("nobody")
	bogus.set_action_json(JSON.stringify(WarActionsS.start_round()))
	bogus.set_predicted_hash(BOGUS_HASH)
	var nf_id := hermes.send_rpc("ValidateAction", bogus.to_bytes())
	if nf_id.is_empty():
		return "could not send the NOT_FOUND probe"
	var nf_rejected := false
	var nf_deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < nf_deadline:
		var got: Array = await hermes.envelope_received
		if got.size() > 1 and String(got[0]) == nf_id:
			nf_rejected = int((got[1] as Dictionary).get("status_code", 0)) != 0
			break
	if not nf_rejected:
		return "ValidateAction with an unknown match_id was not rejected (binding not enforced)"

	# --- 5. COMPLETE ----------------------------------------------------------
	var comp: Dictionary = await client.complete_match()
	if not comp.get("ok", false):
		return "complete_match failed: %s" % comp.get("error", "")

	hermes.disconnect_from_validator()
	return ""


## The single legal advancing action for each non-terminal phase (basic loop,
## no special cards). Mirrors the Round Director's phase->action mapping.
func _next_action(phase: String) -> Dictionary:
	match phase:
		"dealt":
			return WarActionsS.start_round()
		"selected":
			return WarActionsS.flip()
		"flipped":
			return WarActionsS.resolve()
		"war":
			return WarActionsS.ack_war()
		_:
			return {}
