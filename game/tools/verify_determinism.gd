extends SceneTree
## VERIFY determinism — the GDScript half of the byte-for-byte parity contract.
##
## Builds a known game (fixed seed), applies the SHARED scripted action sequence
## through WarEngine.apply, prints each step's 64-hex state hash as
## "GD_HASH <step> <hash>" (compared line-by-line against the TS parity-dump.ts
## "TS_HASH <step> <hash>" output), and asserts the result against the committed
## golden vector at res://tests/golden/determinism_golden.json.
##
## The golden vector is GENERATED from the canonical TS dist scenario
## (validator/src/logic/tools/parity-dump.ts) — never hand-typed. When the golden
## file is missing this verifier degrades to an internal-consistency pass and
## prints the live hashes so a human can seed the golden file.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_determinism.gd

# Canonical fixed seed for the determinism parity vector. MUST match the seed in
# validator/src/logic/tools/parity-dump.ts.
const FIXED_SEED := "WAR-PARITY-1"

# The committed golden vector, generated from the canonical TS dist scenario.
const GOLDEN_PATH := "res://tests/golden/determinism_golden.json"

# Shared scripted action sequence applied after new_game (9 applies). MUST match
# parity-dump.ts step-for-step.
const SCRIPT := [
	{"type": "start_round"},
	{"type": "flip"},
	{"type": "resolve"},
	{"type": "start_round"},
	{"type": "flip"},
	{"type": "resolve"},
	{"type": "start_round"},
	{"type": "flip"},
	{"type": "resolve"},
]


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY determinism: PASS")
	else:
		print("VERIFY determinism: FAIL %s" % reason)
	quit()


## Returns "" on success, or a human-readable failure reason.
func _run() -> String:
	var Engine_: Variant = _load_logic("res://logic/engine.gd", "WarEngine")
	if Engine_ == null:
		return "WarEngine not found at res://logic/engine.gd"
	var Hasher: Variant = _load_logic("res://logic/hasher.gd", "WarHasher")
	if Hasher == null:
		return "WarHasher not found at res://logic/hasher.gd"

	# Run the shared scenario, collecting per-step hashes (step 0 = after new_game).
	var hashes: Array = []
	var res: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": FIXED_SEED})
	if not _ok(res):
		return "new_game rejected: %s" % _err_of(res)
	var state: Dictionary = res["state"]
	var h0: String = Hasher.hash_value(state)
	hashes.append(h0)
	print("GD_HASH 0 %s" % h0)

	var step_index := 1
	for action in SCRIPT:
		res = Engine_.apply(state, action)
		if not _ok(res):
			return "scripted action %d (%s) rejected: %s" % [step_index, action.get("type", "?"), _err_of(res)]
		state = res["state"]
		var h: String = Hasher.hash_value(state)
		hashes.append(h)
		print("GD_HASH %d %s" % [step_index, h])
		step_index += 1

	# Internal-consistency checks on the final hash.
	var final_hash: String = hashes[hashes.size() - 1]
	if typeof(final_hash) != TYPE_STRING or final_hash.length() != 64:
		return "final hash is not 64 hex chars"
	if not _is_lower_hex(final_hash):
		return "final hash contains non lowercase-hex chars: %s" % final_hash

	# Determinism: replaying the whole sequence yields the SAME per-step hashes.
	var replay: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": FIXED_SEED})["state"]
	if Hasher.hash_value(replay) != hashes[0]:
		return "non-deterministic: replay step 0 hash differs"
	var ri := 1
	for action in SCRIPT:
		replay = Engine_.apply(replay, action)["state"]
		if Hasher.hash_value(replay) != hashes[ri]:
			return "non-deterministic: replay step %d hash differs" % ri
		ri += 1

	# Canonical empty-container contract: empties must be "[]" / "{}" (single line).
	if Hasher.canonical_stringify([]) != "[]":
		return "canonical_stringify([]) != \"[]\": %s" % Hasher.canonical_stringify([])
	if Hasher.canonical_stringify({}) != "{}":
		return "canonical_stringify({}) != \"{}\": %s" % Hasher.canonical_stringify({})

	# Canonical null-omission + key-sort spot-checks.
	var canon: String = Hasher.canonical_stringify({"b": 1, "a": 2, "z": null})
	if canon.find("\"z\"") != -1:
		return "canonical_stringify did not omit null-valued key: %s" % canon
	if canon.find("\"a\"") > canon.find("\"b\""):
		return "canonical_stringify keys not lexicographically sorted: %s" % canon

	# Golden-vector comparison (authoritative; generated from the TS dist scenario).
	if FileAccess.file_exists(GOLDEN_PATH):
		var f := FileAccess.open(GOLDEN_PATH, FileAccess.READ)
		if f == null:
			return "golden file present but unreadable: %s" % GOLDEN_PATH
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) != TYPE_DICTIONARY:
			return "golden file is not a JSON object: %s" % GOLDEN_PATH
		var golden: Dictionary = parsed
		if str(golden.get("seed", "")) != FIXED_SEED:
			return "golden seed mismatch (%s vs %s) — regenerate from TS dist" % [golden.get("seed", ""), FIXED_SEED]
		var expected: Array = golden.get("hashes", [])
		if expected.size() != hashes.size():
			return "golden hash count mismatch (%d vs %d)" % [expected.size(), hashes.size()]
		for i in range(hashes.size()):
			if str(expected[i]) != hashes[i]:
				return "PARITY BREAK at step %d: GDScript %s != golden %s" % [i, hashes[i], expected[i]]
	else:
		print("  note: no golden vector at %s; consistency-only pass." % GOLDEN_PATH)

	return ""


# --- helpers ---------------------------------------------------------------

func _load_logic(path: String, _class_hint: String) -> Variant:
	if not ResourceLoader.exists(path):
		return null
	return load(path)


func _ok(res: Variant) -> bool:
	return typeof(res) == TYPE_DICTIONARY and bool(res.get("ok", false))


func _err_of(res: Variant) -> String:
	if typeof(res) == TYPE_DICTIONARY:
		return str(res.get("error", "<no error string>"))
	return "<engine returned non-dictionary>"


func _is_lower_hex(s: String) -> bool:
	for i in s.length():
		var c := s[i]
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return false
	return true
