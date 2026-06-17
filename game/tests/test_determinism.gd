extends RefCounted
## Editor-suite tests for the DETERMINISM / hash parity contract.
##
## Designed to run under the godot-ai `test_run` MCP (McpTestSuite): the runner
## discovers test_*.gd in res://tests/, instantiates this RefCounted, and invokes
## every `test_*` method. This suite is intentionally self-contained — it does NOT
## extend a (possibly-absent) McpTestSuite base; it uses assert() for failures so it
## runs identically with or without that addon. Mirrors tools/verify_determinism.gd.
##
## Parity reminder: the canonical JSON + 64-hex state hash produced here by WarHasher
## MUST equal what validator/src/logic (TypeScript) produces for the same input. The
## authoritative expected hash is the committed golden vector (tests/golden/), which
## is GENERATED from the TS dist and never hand-typed.

const FIXED_SEED := "war-determinism-vector-0001"
const GOLDEN_PATH := "res://tests/golden/determinism_v1.json"
const SCRIPT := [
	{"type": "start_round"}, {"type": "flip"}, {"type": "resolve"},
	{"type": "start_round"}, {"type": "flip"}, {"type": "resolve"},
]


func _engine() -> Variant:
	assert(ResourceLoader.exists("res://logic/engine.gd"), "WarEngine missing at res://logic/engine.gd")
	return load("res://logic/engine.gd")


func _hasher() -> Variant:
	assert(ResourceLoader.exists("res://logic/hasher.gd"), "WarHasher missing at res://logic/hasher.gd")
	return load("res://logic/hasher.gd")


func _play_script() -> Dictionary:
	var Engine_: Variant = _engine()
	var state: Dictionary = Engine_.apply({}, {"type": "new_game", "seed": FIXED_SEED})["state"]
	for action in SCRIPT:
		var res: Dictionary = Engine_.apply(state, action)
		assert(bool(res.get("ok", false)), "scripted action rejected: %s" % str(action))
		state = res["state"]
	return state


## hash_value returns 64 lowercase-hex chars.
func test_hash_is_64_lowercase_hex() -> void:
	var Hasher: Variant = _hasher()
	var h: String = Hasher.hash_value(_play_script())
	assert(h.length() == 64, "hash length %d != 64" % h.length())
	for i in h.length():
		var c: String = h[i]
		assert((c >= "0" and c <= "9") or (c >= "a" and c <= "f"), "non lowercase-hex char in hash: %s" % c)


## Re-hashing the same value is stable.
func test_hash_stable_across_calls() -> void:
	var Hasher: Variant = _hasher()
	var state := _play_script()
	assert(Hasher.hash_value(state) == Hasher.hash_value(state), "hash not stable across calls")


## Replaying the whole sequence from scratch yields the same hash (determinism).
func test_replay_is_deterministic() -> void:
	var Hasher: Variant = _hasher()
	var a: String = Hasher.hash_value(_play_script())
	var b: String = Hasher.hash_value(_play_script())
	assert(a == b, "replay produced a different hash: %s != %s" % [a, b])


## Mutating one field changes the hash (guards a constant-output bug).
func test_hash_is_sensitive_to_mutation() -> void:
	var Hasher: Variant = _hasher()
	var state := _play_script()
	var base_hash: String = Hasher.hash_value(state)
	var mutated := state.duplicate(true)
	mutated["war_depth"] = int(mutated.get("war_depth", 0)) + 1
	assert(Hasher.hash_value(mutated) != base_hash, "hash insensitive to war_depth mutation")


## canonical_stringify omits null-valued keys and sorts keys lexicographically.
func test_canonical_stringify_contract() -> void:
	var Hasher: Variant = _hasher()
	var canon: String = Hasher.canonical_stringify({"b": 1, "a": 2, "z": null})
	assert(canon.find("\"z\"") == -1, "null-valued key 'z' not omitted: %s" % canon)
	assert(canon.find("\"a\"") < canon.find("\"b\""), "keys not lexicographically sorted: %s" % canon)


## When a golden vector is committed, the live hash MUST match it (TS parity).
func test_matches_golden_vector_when_present() -> void:
	if not FileAccess.file_exists(GOLDEN_PATH):
		return  # skeleton phase: no committed vector yet — see tests/golden/README.md
	var Hasher: Variant = _hasher()
	var f := FileAccess.open(GOLDEN_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	assert(typeof(parsed) == TYPE_DICTIONARY, "golden file is not a JSON object")
	var golden: Dictionary = parsed
	assert(str(golden.get("seed", "")) == FIXED_SEED, "golden seed mismatch — regenerate from TS dist")
	assert(str(golden.get("hash", "")) == Hasher.hash_value(_play_script()), "PARITY BREAK: GDScript hash != TS golden")
