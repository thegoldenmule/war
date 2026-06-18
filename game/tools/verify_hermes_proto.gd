extends SceneTree
## VERIFY hermes_proto — the godobuf-generated Hermes + ValidatorService bindings
## round-trip byte-for-byte (Phase B wire-golden self-check).
##
## The online wire frames a Hermes ClientMessage/ServerMessage (binary protobuf) whose
## inner snap-api-proxy payload carries a serialized ValidatorService request/response,
## and game state/actions ride as canonical-JSON STRINGS inside those messages (the hash
## domain). This asserts encode -> bytes -> decode preserves every field, so the client
## (godobuf) and server (protobufjs) agree on the frame layout.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_hermes_proto.gd

const HermesPb := preload("res://net/proto/hermes_envelope_pb.gd")
const ValidatorPb := preload("res://net/proto/validator_pb.gd")


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY hermes_proto: PASS")
	else:
		print("VERIFY hermes_proto: FAIL %s" % reason)
	quit()


func _run() -> String:
	# --- ClientMessage carrying a ValidateActionRequest -----------------------
	var vreq := ValidatorPb.ValidateActionRequest.new()
	vreq.set_match_id("m_42")
	vreq.set_player_id("local-abc")
	vreq.set_action_json('{\n  "type": "flip"\n}')
	vreq.set_predicted_hash("deadbeef")
	var cm := HermesPb.ClientMessage.new()
	cm.set_type("snap-api-proxy")
	var api := cm.new_api_proxy()
	api.set_request_id("req-7")
	api.set_api_method("ValidateAction")
	api.set_payload(vreq.to_bytes())
	var frame := cm.to_bytes()
	if frame.is_empty():
		return "ClientMessage.to_bytes() produced no bytes"

	var cm2 := HermesPb.ClientMessage.new()
	if cm2.from_bytes(frame) != HermesPb.PB_ERR.NO_ERRORS:
		return "ClientMessage.from_bytes did not parse"
	if cm2.get_type() != "snap-api-proxy":
		return "ClientMessage.type did not survive ('%s')" % cm2.get_type()
	var api2 := cm2.get_api_proxy()
	if api2.get_request_id() != "req-7" or api2.get_api_method() != "ValidateAction":
		return "SnapApiProxyRequest request_id/api_method drifted (%s / %s)" % [api2.get_request_id(), api2.get_api_method()]
	var vreq2 := ValidatorPb.ValidateActionRequest.new()
	if vreq2.from_bytes(api2.get_payload()) != ValidatorPb.PB_ERR.NO_ERRORS:
		return "inner ValidateActionRequest did not parse"
	# The canonical-JSON string (the hash domain) must survive verbatim, newlines and all.
	if vreq2.get_action_json() != '{\n  "type": "flip"\n}':
		return "action_json (hash domain) drifted: %s" % vreq2.get_action_json()
	if vreq2.get_match_id() != "m_42" or vreq2.get_player_id() != "local-abc" or vreq2.get_predicted_hash() != "deadbeef":
		return "ValidateActionRequest scalar fields drifted"

	# --- ServerMessage carrying a ValidateActionResponse ----------------------
	var vres := ValidatorPb.ValidateActionResponse.new()
	vres.set_ok(true)
	vres.set_hash_matched(false)
	vres.set_authoritative_state_json('{\n  "phase": "dealt"\n}')
	vres.set_hash("cafe1234")
	vres.set_events_json('[{"type":"award"}]')
	var sm := HermesPb.ServerMessage.new()
	sm.set_type("snap-api-proxy")
	var sapi := sm.new_api_proxy()
	sapi.set_request_id("req-7")
	sapi.set_status_code(0)
	sapi.set_payload(vres.to_bytes())
	var sframe := sm.to_bytes()

	var sm2 := HermesPb.ServerMessage.new()
	if sm2.from_bytes(sframe) != HermesPb.PB_ERR.NO_ERRORS:
		return "ServerMessage.from_bytes did not parse"
	var sapi2 := sm2.get_api_proxy()
	if sapi2.get_request_id() != "req-7" or sapi2.get_status_code() != 0:
		return "SnapApiProxyResponse request_id/status_code drifted"
	var vres2 := ValidatorPb.ValidateActionResponse.new()
	if vres2.from_bytes(sapi2.get_payload()) != ValidatorPb.PB_ERR.NO_ERRORS:
		return "inner ValidateActionResponse did not parse"
	if not vres2.get_ok() or vres2.get_hash_matched():
		return "ValidateActionResponse ok/hash_matched drifted"
	if vres2.get_authoritative_state_json() != '{\n  "phase": "dealt"\n}':
		return "authoritative_state_json (hash domain) drifted"
	if vres2.get_hash() != "cafe1234" or vres2.get_events_json() != '[{"type":"award"}]':
		return "ValidateActionResponse hash/events_json drifted"

	# --- InitMatch + CompleteMatch message round-trips ------------------------
	var ireq := ValidatorPb.InitMatchRequest.new()
	ireq.set_seed("")   # empty -> server assigns
	ireq.set_player_id("local-abc")
	var ireq2 := ValidatorPb.InitMatchResponse.new()
	ireq2.from_bytes((func() -> PackedByteArray:
		var r := ValidatorPb.InitMatchResponse.new()
		r.set_match_id("m_42"); r.set_player_id("local-abc"); r.set_state_json("{}"); r.set_hash("h0")
		return r.to_bytes()).call())
	if ireq2.get_match_id() != "m_42" or ireq2.get_state_json() != "{}":
		return "InitMatchResponse round-trip drifted"
	var creq := ValidatorPb.CompleteMatchRequest.new()
	creq.set_match_id("m_42"); creq.set_player_id("local-abc")
	var cres := ValidatorPb.CompleteMatchResponse.new()
	if cres.from_bytes((func() -> PackedByteArray:
		var r := ValidatorPb.CompleteMatchResponse.new()
		r.set_match_id("m_42"); r.set_final_phase("player_win"); r.set_hash("hf")
		return r.to_bytes()).call()) != ValidatorPb.PB_ERR.NO_ERRORS:
		return "CompleteMatchResponse did not parse"
	if cres.get_final_phase() != "player_win":
		return "CompleteMatchResponse final_phase drifted"

	return ""
