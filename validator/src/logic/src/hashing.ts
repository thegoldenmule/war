/**
 * Canonical serialization + deterministic state hashing.
 *
 * PARITY CONTRACT — this module MUST produce byte-for-byte identical output to
 * the GDScript `WarHasher` (game/logic/hasher.gd). Any divergence breaks the
 * optimistic-reconcile fast path and the golden vectors.
 *
 * canonicalStringify(value):
 *   JSON identical to json-stable-stringify(x, { space: 2 }) with these rules:
 *     - object keys sorted lexicographically (by UTF-16 code unit) at every depth
 *     - 2-space indentation
 *     - arrays kept in order
 *     - object keys whose value is `null` are OMITTED entirely
 *     - integer-valued numbers print with NO decimal point (e.g. `14`, not `14.0`)
 *     - other floats print as the shortest decimal that round-trips to the same
 *       IEEE-754 double (JavaScript's default Number->string already does this)
 *
 * hashString(s):
 *   8-lane rolling hash over the UTF-8 bytes of `s`.
 *     lanes init to IV = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
 *                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
 *     SHIFTS = [5, 7, 11, 13, 17, 19, 23, 29]
 *     for each byte b, for each lane:
 *       h[lane] = toInt32((h[lane] << SHIFTS[lane]) - h[lane] + b)
 *     where toInt32 wraps to a signed 32-bit int (JS `x | 0`).
 *   Output: each lane formatted as %08x of its UNSIGNED 32-bit value,
 *   concatenated => 64 lowercase hex chars.
 */

/** Initialization vector for the 8 hash lanes (SHA-256 fractional constants). */
const IV: readonly number[] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
  0x1f83d9ab, 0x5be0cd19,
];

/** Per-lane left-shift amounts. */
const SHIFTS: readonly number[] = [5, 7, 11, 13, 17, 19, 23, 29];

/**
 * Format a finite number exactly as the canonical contract requires:
 * integer-valued numbers have no decimal point; all others use the shortest
 * round-tripping decimal (JS default). GDScript must mirror: print ints without
 * ".0", and floats via str()/the shortest representation.
 */
function formatNumber(n: number): string {
  if (!Number.isFinite(n)) {
    // Non-finite numbers are never part of the hashed state; guard defensively.
    throw new Error(`canonicalStringify: non-finite number ${String(n)}`);
  }
  if (Number.isInteger(n)) {
    // Normalize -0 to 0 so both engines agree.
    return String(n === 0 ? 0 : n);
  }
  return String(n);
}

/** Escape a string into a JSON string literal (including surrounding quotes). */
function quoteString(s: string): string {
  // JSON.stringify of a primitive string yields the exact, spec-compliant
  // escaping (control chars, quotes, backslashes, \uXXXX). GDScript mirrors
  // this with its JSON.stringify on a bare string.
  return JSON.stringify(s);
}

/**
 * Serialize a value to canonical JSON. `indent` is the current nesting depth's
 * indentation string; nested levels add two spaces.
 *
 * Returns `null` (the JS value) for entries that must be OMITTED by the caller
 * (i.e. object members whose value is JSON `null`). Array elements that are
 * `null` are serialized as the literal `null` (only OBJECT members are dropped),
 * matching json-stable-stringify semantics.
 */
function encode(value: unknown, indent: string): string {
  if (value === null) {
    return "null";
  }
  const t = typeof value;
  if (t === "string") {
    return quoteString(value as string);
  }
  if (t === "number") {
    return formatNumber(value as number);
  }
  if (t === "boolean") {
    return value ? "true" : "false";
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "[]";
    }
    const childIndent = indent + "  ";
    const parts = value.map((el) => childIndent + encode(el, childIndent));
    return "[\n" + parts.join(",\n") + "\n" + indent + "]";
  }
  if (t === "object") {
    const obj = value as Record<string, unknown>;
    const childIndent = indent + "  ";
    // Sort keys lexicographically by UTF-16 code unit (matches GDScript's
    // ascending string sort and json-stable-stringify's default comparator).
    const keys = Object.keys(obj)
      // OMIT null/undefined-valued members. The contract omits null keys; a key
      // that is `undefined` (e.g. an optional like pending_special that was
      // omitted from canonical JSON and so re-parses as undefined) is the same
      // "absent" state and must serialize identically — matching GDScript, where
      // a missing Dictionary key is simply never emitted. (Only `undefined` is
      // newly handled here; it previously threw, so no existing hash changes.)
      .filter((k) => obj[k] !== null && obj[k] !== undefined)
      .sort();
    if (keys.length === 0) {
      return "{}";
    }
    const parts = keys.map(
      (k) => childIndent + quoteString(k) + ": " + encode(obj[k], childIndent),
    );
    return "{\n" + parts.join(",\n") + "\n" + indent + "}";
  }
  // undefined / function / symbol are not part of the hash domain.
  throw new Error(`canonicalStringify: unsupported value type ${t}`);
}

/**
 * Produce the canonical JSON string for `value` per the contract rules.
 * Equivalent to json-stable-stringify(value, { space: 2 }) with null-member
 * omission.
 */
export function canonicalStringify(value: unknown): string {
  return encode(value, "");
}

/** Wrap a number to a signed 32-bit integer (JS `x | 0`). */
function toInt32(x: number): number {
  return x | 0;
}

/** Format a 32-bit lane as 8 lowercase hex digits of its UNSIGNED value. */
function laneHex(lane: number): string {
  // `>>> 0` reinterprets the signed int32 as unsigned for formatting.
  return (lane >>> 0).toString(16).padStart(8, "0");
}

/**
 * 8-lane rolling hash over the UTF-8 bytes of `s`. See the module docstring for
 * the exact algorithm. Returns 64 lowercase hex chars.
 */
export function hashString(s: string): string {
  const lanes = IV.slice();
  // Encode to UTF-8 bytes. TextEncoder yields the same byte sequence the
  // GDScript side gets from String.to_utf8_buffer().
  const bytes = new TextEncoder().encode(s);
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i] as number;
    for (let lane = 0; lane < 8; lane++) {
      const h = lanes[lane] as number;
      const shift = SHIFTS[lane] as number;
      // (h << shift) - h + b, wrapped to int32 at each step.
      lanes[lane] = toInt32(toInt32(h << shift) - h + b);
    }
  }
  let out = "";
  for (let lane = 0; lane < 8; lane++) {
    out += laneHex(lanes[lane] as number);
  }
  return out;
}

/** Hash an arbitrary canonical-serializable value. */
export function hashValue(value: unknown): string {
  return hashString(canonicalStringify(value));
}

/** Convenience: the canonical state hash. Alias of {@link hashValue} for game state. */
export function stateHash(state: unknown): string {
  return hashValue(state);
}
