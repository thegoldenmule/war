@tool
class_name WarRng
extends RefCounted

## Deterministic, seeded RNG for the War rules engine.
##
## DETERMINISM PARITY: this algorithm MUST be reproduced byte-for-byte in the
## TypeScript validator (validator/src/logic/rng.ts). Every integer operation
## below is chosen to be exactly representable and identically wrapping in both
## GDScript (64-bit ints, manual 32-bit masking) and JS (use `>>> 0` / `| 0`
## to mirror the unsigned/signed 32-bit wraps). See the per-step notes.
##
## ALGORITHM — xorshift32 over an unsigned 32-bit state word:
##   seed_from(seed): derive a non-zero 32-bit state word from the seed STRING
##     via an FNV-1a-style fold (xorshift32 must never be seeded with 0).
##   next_u32(rng): advance one xorshift32 step, return the new state as the
##     drawn value in [0, 2^32). The step is:
##       x ^= (x << 13); x ^= (x >> 17); x ^= (x << 5)
##     each ^= line masked back to 32 bits.
##
## STATE CURSOR: the serialized, hashable cursor is `{seq:int}` — the number of
## draws taken. The 32-bit working word is NOT serialized; instead it is
## recomputed by re-seeding from the match seed and replaying `seq` draws. This
## keeps the hash domain a small integer and makes restoration trivial in both
## languages (mirrors the Moveborne replay-N-draws approach).
##
## Pure static utility — zero Node / scene dependencies, headless-loadable.

const MASK32 := 0xFFFFFFFF

## FNV-1a 32-bit constants (used only to fold the seed string into a word).
const FNV_OFFSET := 0x811C9DC5
const FNV_PRIME := 0x01000193


## Mask a value to an unsigned 32-bit integer (mirrors JS `x >>> 0`).
static func _u32(v: int) -> int:
	return v & MASK32


## Build the initial RNG cursor from a seed string. Returns the SERIALIZABLE
## cursor `{seq:int}` (seq starts at 0). The working state word is derived on
## demand from the same seed via `_state_word_for(seed, seq)`.
##
## The seed is stored separately on the game state (state.seed); this cursor
## only tracks how many draws have been consumed.
static func seed_from(_seed: String) -> Dictionary:
	return {"seq": 0}


## Fold a seed string into a non-zero 32-bit state word using FNV-1a.
## Identical in TS: h = (h ^ byte) >>> 0; h = Math.imul(h, FNV_PRIME) >>> 0.
static func seed_to_word(seed: String) -> int:
	var data: PackedByteArray = seed.to_utf8_buffer()
	var h: int = FNV_OFFSET
	for idx in range(data.size()):
		var b: int = data[idx]
		h = _u32(h ^ b)
		# 32-bit multiply with wrap (JS uses Math.imul; here mask after multiply).
		h = _u32(h * FNV_PRIME)
	# xorshift32 must never start at 0 — substitute a fixed non-zero constant.
	if h == 0:
		h = 0x9E3779B9
	return h


## One xorshift32 step. Takes and returns an unsigned 32-bit word.
static func _step(x: int) -> int:
	x = _u32(x ^ _u32(x << 13))
	x = _u32(x ^ (x >> 17))
	x = _u32(x ^ _u32(x << 5))
	return x


## Recompute the working 32-bit state word for a given seed after `seq` draws,
## by re-seeding and stepping `seq` times. Pure; no stored mutable state.
static func _state_word_for(seed: String, seq: int) -> int:
	var x: int = seed_to_word(seed)
	for _i in range(seq):
		x = _step(x)
	return x


## Draw the next unsigned 32-bit value and advance the cursor.
## Returns `{value:int, rng:{seq:int}}`. Requires the originating `seed` because
## the cursor stores only `seq` (the working word is replayed from the seed).
##
## value is in [0, 2^32); callers map it into a range with modulo as needed.
static func next_u32(seed: String, rng: Dictionary) -> Dictionary:
	var seq: int = int(rng.get("seq", 0))
	var word: int = _state_word_for(seed, seq + 1)
	return {"value": word, "rng": {"seq": seq + 1}}


## Draw an integer in [0, n) without modulo bias mattering for our small n
## (deck indices). Uses the next_u32 draw and a plain modulo, which is identical
## in TS. Returns `{value:int, rng:{seq:int}}`.
static func next_below(seed: String, rng: Dictionary, n: int) -> Dictionary:
	var step: Dictionary = next_u32(seed, rng)
	var v: int = step["value"] % n
	return {"value": v, "rng": step["rng"]}


## Deterministic Fisher–Yates shuffle of `array` (returns a NEW array; does not
## mutate the input). Iterates i from last index down to 1, swapping element i
## with element j where j is drawn uniformly from [0, i]. This exact loop order
## and draw count MUST be mirrored in TS for parity.
##
## Returns `{array:Array, rng:{seq:int}}` with the advanced cursor.
static func shuffle(seed: String, array: Array, rng: Dictionary) -> Dictionary:
	var out: Array = array.duplicate(true)
	var cursor: Dictionary = {"seq": int(rng.get("seq", 0))}
	var i: int = out.size() - 1
	while i > 0:
		var step: Dictionary = next_below(seed, cursor, i + 1)
		var j: int = step["value"]
		cursor = step["rng"]
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
		i -= 1
	return {"array": out, "rng": cursor}
