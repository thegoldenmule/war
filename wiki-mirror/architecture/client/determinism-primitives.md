# Determinism Primitives

**Status:** current

## Kind
component

## Summary
*WarHasher* and *WarRng* are the two pure static utilities that form the determinism parity substrate of the rules engine: a canonical JSON serializer plus 8-lane rolling state hash, and a seeded RNG whose cursor serializes into game state. Both are headless-loadable with zero Node or scene dependencies and exist as byte-for-byte identical twins in GDScript and TypeScript.

## Purpose
These primitives let the optimistic client and the authoritative validator compute the *same 64-hex state hash* for the same game state, which is what makes optimistic play and reconciliation possible. *WarHasher* turns any state Variant into a stable canonical string and then a comparable hash; *WarRng* supplies deterministic, replayable randomness (deck shuffles, draws) so both engines evolve state identically. The entire contract exists to ensure GDScript and TypeScript never silently diverge.

## Design notes
Float formatting is a known GDScript hazard. str(float) caps at roughly 14 significant digits and will not round-trip a value like 4528.410562653503, so the hasher uses a shortest-round-trip formatter: integer-valued floats below 1e15 print with no decimal point (matching JS), otherwise it searches precision 1..17 via String.num until the string parses back to the exact same double. Keeping integral state values typed as int avoids the issue entirely on the hot path.

WarRng exposes seed_from(seed) returning the initial cursor {seq:0}; next_u32(seed, rng) drawing the next unsigned 32-bit value and returning the advanced cursor; next_below(seed, rng, n) for an index in [0,n) via plain modulo (bias is negligible for the small deck indices used); and shuffle(seed, array, rng) which performs a deterministic Fisher-Yates shuffle returning a NEW array plus the advanced cursor. The exact loop order (i from last index down to 1, j drawn from [0,i]) and per-iteration draw count must be mirrored in TypeScript.

Both modules are reproduced verbatim from the Moveborne reference port; the replay-N-draws cursor model and the 8-lane hash come straight from that lineage. TypeScript parity points are explicit: x|0 / >>> 0 to mirror the signed/unsigned 32-bit wraps in the hash, and Math.imul plus >>> 0 to mirror the FNV-1a multiply in the RNG seed fold.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarHasher` in `game/logic/hasher.gd`
- function `canonical_stringify` in `game/logic/hasher.gd`
- function `hash_string` in `game/logic/hasher.gd`
- class `WarRng` in `game/logic/rng.gd`
- function `shuffle` in `game/logic/rng.gd`
- `validator/src/logic/src/hashing.ts`
- `validator/src/logic/src/rng.ts`

## Data model
*WarHasher* holds no instance state — only the constants IV (the eight SHA-256 initialization vectors) and SHIFTS [5,7,11,13,17,19,23,29]. *WarRng* is likewise stateless; the only serialized, hashable cursor is the RNG state stored on game state as state.rng = {seq:int}, the number of draws taken. The 32-bit xorshift32 working word is NOT serialized — it is recomputed on demand by re-seeding from the match seed (state.seed) and replaying seq draws, keeping the hash domain a single small integer.

## Usage
_None._

## Invariants & constraints
- GDScript and the TypeScript twin (validator/src/logic/src/hashing.ts and rng.ts) MUST be byte-for-byte identical: same canonical JSON output, same RNG draw order and count, and the same 64-hex-char hash for any given value.
- canonical_stringify must match json-stable-stringify(value, {space:2}) exactly — keys sorted lexicographically at every depth, 2-space indentation, arrays preserved in order, dictionary keys whose value is null OMITTED (mirroring JS dropping undefined-valued fields), and floats rendered as the shortest decimal string that round-trips to the same IEEE-754 double.
- hash_string is an 8-lane rolling hash: lanes initialized to the SHA-256 IVs, per-byte update h[lane] = toInt32((h[lane] << SHIFTS[lane]) - h[lane] + b) wrapping like JS x|0, output as each lane formatted %08x and concatenated to 64 lowercase hex chars. It is NOT cryptographic — it is only a fast comparison hash for optimistic reconcile.
- xorshift32 must never be seeded with 0: seed_to_word folds the seed string via FNV-1a and substitutes a fixed non-zero constant if the fold yields 0. Because only seq is serialized, restoring the working word always re-seeds from state.seed and replays exactly seq draws — both engines must agree on draw count and order (e.g. the Fisher-Yates loop in shuffle).

## Synced commit
_None._
