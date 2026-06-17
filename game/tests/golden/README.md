# Golden vectors — the determinism parity oracle

This folder holds the **golden state-hash vectors** that pin the byte-for-byte
parity contract between the two halves of the engine:

- **GDScript** — `game/logic/*.gd` (`WarEngine`, `WarHasher`, ...), run by the
  client and by the headless verifiers in `game/tools/verify_*.gd`.
- **TypeScript** — `validator/src/logic/*`, run by the authoritative validator.

Both sides MUST produce the **identical canonical JSON** and the **identical
64-hex state hash** for the same `(seed, action-list)`. A golden vector captures
one such expected hash so a drift in *either* side trips a test.

## The one rule: never hand-write a hash

> The expected hashes here are **GENERATED from the canonical TypeScript logic
> dist** (`validator/src/logic`) and committed. They are an *oracle*, not an
> assertion authored by hand.

The TS side is the source of truth for the published value because the validator
is authoritative on the wire. Hand-typing a hash (or copying it out of a GDScript
run) would make the test tautological — it would assert the GDScript side equals
itself and could "pass" while silently diverging from the server. Always regenerate
from the TS dist.

## File shape

Each vector is a small JSON object:

```json
{
  "name": "determinism_v1",
  "seed": "war-determinism-vector-0001",
  "actions": [
    { "type": "start_round" }, { "type": "flip" }, { "type": "resolve" },
    { "type": "start_round" }, { "type": "flip" }, { "type": "resolve" }
  ],
  "hash": "<64 lowercase hex chars emitted by the TS hasher>",
  "generated_from": "validator/src/logic",
  "generated_at": "<iso-8601>"
}
```

- `seed` + `actions` exactly mirror the constants in
  `game/tools/verify_determinism.gd` and `game/tests/test_determinism.gd`
  (`FIXED_SEED` + `SCRIPT`). If you change one, regenerate the vector and update
  both GDScript files in lockstep.
- `hash` is the only authoritative field — `WarHasher.hash_value(final_state)`
  must equal it on the GDScript side.

## Who reads these

- `game/tools/verify_determinism.gd` loads `determinism_v1.json` (if present) and
  asserts `WarHasher.hash_value(...) == hash`. When the file is **absent** it
  degrades to a consistency-only PASS and prints the live GDScript hash so a human
  can seed the file from the TS generator.
- `game/tests/test_determinism.gd` mirrors that check under the editor test suite.

## Regenerating (TODO(skeleton): wire the generator)

The TS dist should ship a small generator that replays `seed` + `actions` through
`validator/src/logic` and writes the JSON here, e.g.:

```bash
# from validator/
npm run build
node dist/tools/gen_golden.js \
  --seed war-determinism-vector-0001 \
  --out ../game/tests/golden/determinism_v1.json
```

Until that generator lands, this folder intentionally contains **no** committed
hash — the verifier and the test both run green on internal consistency and emit
the live value to be promoted into the first golden vector.
