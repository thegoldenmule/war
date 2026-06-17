/**
 * Deterministic RNG — parity twin of game/logic/rng.gd (`WarRng`).
 *
 * The GDScript side is CANONICAL. This file reproduces it draw-for-draw:
 *
 *   - seed_to_word(seed): FNV-1a 32-bit fold of the seed's UTF-8 bytes; if it
 *     folds to 0, substitute the fixed non-zero constant 0x9E3779B9.
 *   - _step(x): one xorshift32 step with shifts 13/17/5 (each masked to 32 bits).
 *   - _state_word_for(seed, seq): re-seed and apply _step `seq` times (a CHAIN).
 *     The 32-bit working word is NEVER serialized; only the integer cursor
 *     `{seq}` is. Restoration replays from the seed.
 *   - next_u32(seed, rng): word for seq+1; advances seq by 1.
 *   - next_below(seed, rng, n): next_u32 value taken modulo n (PLAIN modulo, NO
 *     rejection sampling — matches GDScript exactly).
 *   - shuffle(seed, array, rng): Fisher-Yates, i from last index down to 1,
 *     drawing next_below(i+1) per iteration (this exact loop order + draw count).
 *
 * All arithmetic is performed in unsigned 32-bit space using `>>> 0`, mirroring
 * the GDScript manual masking to 0xFFFFFFFF.
 */

import type { RngState } from "./types.js";

/** Mask to unsigned 32-bit. */
const MASK32 = 0xffffffff;

/** FNV-1a 32-bit offset basis and prime, used to fold the seed string. */
const FNV_OFFSET = 0x811c9dc5;
const FNV_PRIME = 0x01000193;

/** Fallback base word when the folded seed is 0 (xorshift fixed point). */
const NONZERO_FALLBACK = 0x9e3779b9;

/** Mask a value to an unsigned 32-bit integer (mirrors GDScript `& MASK32`). */
function u32(v: number): number {
  return v >>> 0;
}

/** Multiply two u32s and return the low 32 bits (avoids JS float precision loss). */
function mulU32(a: number, b: number): number {
  return Math.imul(a, b) >>> 0;
}

/**
 * Fold a seed string into a non-zero 32-bit state word using FNV-1a.
 * Mirrors WarRng.seed_to_word.
 */
export function seedToWord(seed: string): number {
  let h = FNV_OFFSET >>> 0;
  const bytes = new TextEncoder().encode(seed);
  for (let i = 0; i < bytes.length; i++) {
    h = u32(h ^ (bytes[i] as number));
    h = mulU32(h, FNV_PRIME);
  }
  return h === 0 ? NONZERO_FALLBACK : h;
}

/** One xorshift32 step. Takes and returns an unsigned 32-bit word. */
function step(x: number): number {
  x = u32(x ^ u32(x << 13));
  x = u32(x ^ (x >>> 17));
  x = u32(x ^ u32(x << 5));
  return x;
}

/**
 * Recompute the working 32-bit state word for a given seed after `seq` draws,
 * by re-seeding and stepping `seq` times. Pure; no stored mutable state.
 */
function stateWordFor(seed: string, seq: number): number {
  let x = seedToWord(seed);
  for (let i = 0; i < seq; i++) {
    x = step(x);
  }
  return x;
}

/**
 * Draw the next unsigned 32-bit value and advance the cursor.
 * Returns `{ value, rng: { seq } }`. Mirrors WarRng.next_u32.
 */
export function nextU32(
  seed: string,
  rng: RngState,
): { value: number; rng: RngState } {
  const seq = rng.seq | 0;
  const word = stateWordFor(seed, seq + 1);
  return { value: word, rng: { seq: seq + 1 } };
}

/**
 * Draw an integer in [0, n) via PLAIN modulo (no rejection sampling — identical
 * to GDScript). Returns `{ value, rng: { seq } }`. Mirrors WarRng.next_below.
 */
export function nextBelow(
  seed: string,
  rng: RngState,
  n: number,
): { value: number; rng: RngState } {
  const s = nextU32(seed, rng);
  return { value: s.value % n, rng: s.rng };
}

/**
 * Deterministic Fisher-Yates shuffle of `array` (returns a NEW array; does not
 * mutate the input). Iterates i from last index down to 1, swapping element i
 * with element j drawn uniformly from [0, i]. Mirrors WarRng.shuffle exactly.
 */
export function shuffle<T>(
  seed: string,
  array: readonly T[],
  rng: RngState,
): { array: T[]; rng: RngState } {
  const out = array.slice();
  let cursor: RngState = { seq: rng.seq | 0 };
  let i = out.length - 1;
  while (i > 0) {
    const s = nextBelow(seed, cursor, i + 1);
    const j = s.value;
    cursor = s.rng;
    const tmp = out[i] as T;
    out[i] = out[j] as T;
    out[j] = tmp;
    i -= 1;
  }
  return { array: out, rng: cursor };
}

/** Build the initial RNG cursor from a seed string. Mirrors WarRng.seed_from. */
export function seedFrom(_seed: string): RngState {
  return { seq: 0 };
}

/** Initialize a fresh serialized RNG cursor. */
export function newRng(): RngState {
  return { seq: 0 };
}

// Keep MASK32 referenced to document the 32-bit domain even though `>>> 0`
// performs the masking inline.
void MASK32;
