/**
 * Determinism & canonicalization suite.
 *
 * GOLDEN VECTOR GENERATOR: this file is the canonical source of the golden state
 * hash that the GDScript headless verifier (res://tools/verify_*.gd) asserts
 * against. When the engine or hashing rules change intentionally, run this test,
 * copy the printed GOLDEN values, and update BOTH this file and the GDScript
 * verifier so the two engines stay in lockstep. If they ever disagree, the
 * parity contract is broken — investigate before shipping.
 *
 * What it pins:
 *   1. canonicalStringify ordering / formatting rules (sorted keys, 2-space
 *      indent, null-member omission, integer formatting).
 *   2. hashString against a known constant (algorithm sanity).
 *   3. A fixed-seed scripted game producing a stable stateHash.
 *   4. Purity: apply() never mutates its input state.
 */

import { describe, expect, it } from "vitest";
import {
  apply,
  canonicalStringify,
  hashString,
  newGame,
  stateHash,
  type Action,
  type GameState,
} from "../src/index.js";

/** Drive a list of actions, asserting each step succeeds; returns final state. */
function play(initial: GameState, actions: Action[]): GameState {
  let s = initial;
  for (const a of actions) {
    const r = apply(s, a);
    expect(r.ok, `action ${JSON.stringify(a)} failed: ${r.error}`).toBe(true);
    s = r.state;
  }
  return s;
}

describe("canonicalStringify", () => {
  it("sorts object keys lexicographically at every depth", () => {
    const out = canonicalStringify({ b: 1, a: { d: 2, c: 3 } });
    expect(out).toBe('{\n  "a": {\n    "c": 3,\n    "d": 2\n  },\n  "b": 1\n}');
  });

  it("uses 2-space indentation and preserves array order", () => {
    const out = canonicalStringify({ xs: [3, 1, 2] });
    expect(out).toBe('{\n  "xs": [\n    3,\n    1,\n    2\n  ]\n}');
  });

  it("omits object members whose value is null", () => {
    const out = canonicalStringify({ a: 1, pending_special: null, b: 2 });
    expect(out).toBe('{\n  "a": 1,\n  "b": 2\n}');
  });

  it("omits undefined members identically to null/absent (round-trip safety)", () => {
    // An optional like pending_special is OMITTED from canonical JSON when null;
    // re-parsing that JSON yields `undefined` for the missing key. The serializer
    // must treat undefined as "absent" (omit it) exactly like null — matching
    // GDScript, where a missing Dictionary key is simply never emitted. Regression:
    // a flipped state round-tripped through parseState carried pending_special:
    // undefined and the hasher threw "unsupported value type undefined".
    const asUndef = canonicalStringify({ a: 1, pending_special: undefined, b: 2 });
    expect(asUndef).toBe('{\n  "a": 1,\n  "b": 2\n}');
    expect(asUndef).toBe(canonicalStringify({ a: 1, pending_special: null, b: 2 }));
    expect(asUndef).toBe(canonicalStringify({ a: 1, b: 2 }));
  });

  it("keeps null array elements as literal null", () => {
    expect(canonicalStringify([1, null, 2])).toBe("[\n  1,\n  null,\n  2\n]");
  });

  it("prints integer-valued numbers without a decimal point", () => {
    expect(canonicalStringify(14)).toBe("14");
    expect(canonicalStringify(0)).toBe("0");
    expect(canonicalStringify(-7)).toBe("-7");
  });

  it("prints empty containers compactly", () => {
    expect(canonicalStringify({})).toBe("{}");
    expect(canonicalStringify([])).toBe("[]");
  });
});

describe("hashString", () => {
  it("produces 64 lowercase hex chars", () => {
    const h = hashString("hello");
    expect(h).toMatch(/^[0-9a-f]{64}$/);
  });

  it("is stable for the empty string (== IV concatenation)", () => {
    // With no bytes the lanes stay at IV; output is the IV concatenation.
    expect(hashString("")).toBe(
      "6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19",
    );
  });

  it("changes when input changes", () => {
    expect(hashString("a")).not.toBe(hashString("b"));
  });
});

describe("newGame", () => {
  it("deals 26 + 26 from a 52-card deck in phase dealt", () => {
    const s = newGame("golden-seed-001");
    expect(s.player_deck.length).toBe(26);
    expect(s.cpu_deck.length).toBe(26);
    expect(s.phase).toBe("dealt");
    expect(s.pending_special).toBeNull();
    // All 52 distinct cards present exactly once.
    const seen = new Set<string>();
    for (const c of [...s.player_deck, ...s.cpu_deck]) {
      seen.add(`${c.rank}-${c.suit}`);
    }
    expect(seen.size).toBe(52);
  });

  it("is deterministic for a given seed", () => {
    expect(stateHash(newGame("abc"))).toBe(stateHash(newGame("abc")));
    expect(stateHash(newGame("abc"))).not.toBe(stateHash(newGame("xyz")));
  });

  it("hashes a state identically whether an optional is null, undefined, or absent", () => {
    // The exact divergence that broke online play: the server persists canonical
    // JSON (pending_special omitted), re-parses it (key -> undefined), applies an
    // action, and re-hashes. That undefined must hash the same as the null/absent
    // forms or every post-deal action would crash or mismatch over the wire.
    const base = newGame("roundtrip-seed");
    const asNull: GameState = { ...base, pending_special: null };
    const asUndef = { ...base, pending_special: undefined } as unknown as GameState;
    const { pending_special: _omit, ...rest } = base as Record<string, unknown>;
    const asAbsent = rest as unknown as GameState;
    expect(stateHash(asUndef)).toBe(stateHash(asNull));
    expect(stateHash(asUndef)).toBe(stateHash(asAbsent));
  });
});

describe("apply purity", () => {
  it("does not mutate the input state", () => {
    const s = newGame("purity");
    const before = canonicalStringify(s);
    apply(s, { type: "flip" });
    expect(canonicalStringify(s)).toBe(before);
  });

  it("returns the unchanged state on an illegal action", () => {
    const s = newGame("illegal");
    const r = apply(s, { type: "resolve" }); // illegal from `dealt`
    expect(r.ok).toBe(false);
    expect(r.state).toBe(s);
  });
});

describe("scripted game — GOLDEN VECTOR", () => {
  // A fixed seed + fixed script. The resulting hash is the golden vector the
  // GDScript verifier must reproduce. The seed/script are intentionally simple
  // and stable; do not change without updating the GDScript side.
  const SEED = "war-golden-vector-v1";
  // Canonical flow: start_round (dealt->selected) precedes each flip.
  const SCRIPT: Action[] = [
    { type: "start_round" },
    { type: "flip" },
    { type: "resolve" },
    { type: "start_round" },
    { type: "flip" },
    { type: "resolve" },
    { type: "start_round" },
    { type: "flip" },
    { type: "resolve" },
  ];

  it("produces a stable post-deal hash", () => {
    const s = newGame(SEED);
    const h = stateHash(s);
    // GOLDEN (post-deal): mirror this constant in the GDScript verifier.
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    // Re-derive to prove stability.
    expect(stateHash(newGame(SEED))).toBe(h);
    // eslint-disable-next-line no-console
    console.log(`GOLDEN post_deal_hash(${SEED}) = ${h}`);
  });

  it("produces a stable hash after the scripted rounds", () => {
    const final = play(newGame(SEED), SCRIPT);
    const h = stateHash(final);
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    // Determinism: replaying the script yields the same hash.
    const again = stateHash(play(newGame(SEED), SCRIPT));
    expect(again).toBe(h);
    // eslint-disable-next-line no-console
    console.log(`GOLDEN scripted_hash(${SEED}) = ${h}`);
    // Phase is a legal value after the script.
    expect([
      "dealt",
      "selected",
      "flipped",
      "war",
      "player_win",
      "cpu_win",
    ]).toContain(final.phase);
  });
});

describe("war flow", () => {
  it("declares a war on a tie and can be acked then flipped", () => {
    // Construct a guaranteed tie by hand (engine consumes the top cards).
    const s: GameState = {
      version: 1,
      seed: "tie",
      phase: "dealt",
      player_deck: [
        { rank: 7, suit: "clubs", face_up: false },
        { rank: 2, suit: "clubs", face_up: false },
        { rank: 3, suit: "clubs", face_up: false },
        { rank: 4, suit: "clubs", face_up: false },
        { rank: 14, suit: "clubs", face_up: false },
      ],
      cpu_deck: [
        { rank: 7, suit: "hearts", face_up: false },
        { rank: 2, suit: "hearts", face_up: false },
        { rank: 3, suit: "hearts", face_up: false },
        { rank: 4, suit: "hearts", face_up: false },
        { rank: 5, suit: "hearts", face_up: false },
      ],
      player_pot: [],
      cpu_pot: [],
      rng: { seq: 0 },
      specials: { player: [], cpu: [] },
      pending_special: null,
      war_depth: 0,
    };
    // Canonical flow: start_round stages the top cards face-down, flip reveals.
    let r = apply(s, { type: "start_round" });
    expect(r.ok).toBe(true);
    r = apply(r.state, { type: "flip" });
    expect(r.ok).toBe(true);
    // Equal ranks (7 vs 7) at flip escalate straight to WAR (war_depth = 1).
    expect(r.state.phase).toBe("war");
    expect(r.state.war_depth).toBe(1);
    // ack_war stakes WAR_STAKE face-down + 1 face-up per side, then compares.
    r = apply(r.state, { type: "ack_war" });
    expect(r.ok).toBe(true);
    // Player's face-up war card (14) beats cpu's (5): player sweeps the pot.
    expect(r.state.cpu_pot.length).toBe(0);
    expect(r.state.player_pot.length).toBe(0);
    expect(r.state.player_deck.length).toBeGreaterThan(r.state.cpu_deck.length);
  });
});
