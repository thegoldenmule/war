/**
 * logic.ts — the @war/logic adapter (rules authority boundary).
 *
 * The validator NEVER re-implements War's rules; it delegates to @war/logic,
 * the TypeScript port that is byte-for-byte deterministic-parity with the
 * GDScript engine in game/logic/. This module is the single import site for
 * that package so the rest of the service depends on a small, stable surface
 * regardless of the exact symbol names the logic package settles on.
 *
 * Expected @war/logic surface (mirrors WarEngine / WarHasher in GDScript):
 *   - apply(state, action) -> { ok, state, events, error }   (pure; new state)
 *   - newGame(seed) / initialState(seed)                      (deal + shuffle)
 *   - stateHash(state) / hashValue(value)                     (determinism hash)
 *   - canonicalStringify(value)                               (canonical JSON)
 *
 * Because @war/logic is authored in parallel, we resolve these defensively at
 * import: we accept a handful of plausible export names and fail loudly only
 * when actually invoked with a name that is missing. This keeps the validator
 * type-checkable and runnable as a skeleton while the logic package lands.
 */

import * as WarLogic from "@war/logic";
import type { GameAction, GameState } from "./types.ts";

/** Result shape returned by the pure engine entry point. */
export interface EngineResult {
  ok: boolean;
  state: GameState;
  events: unknown[];
  error: string;
}

// The logic module is untyped from our perspective until @war/logic ships its
// .d.ts; treat it as a bag of callables and pick the first that exists.
const L = WarLogic as unknown as Record<string, unknown>;

function pick<T>(...names: string[]): T {
  for (const n of names) {
    const fn = L[n];
    if (typeof fn === "function") return fn as T;
  }
  throw new Error(
    `@war/logic is missing an expected export (tried: ${names.join(", ")}). ` +
      "This adapter must match the logic package's public API.",
  );
}

/**
 * Apply an action to a state, returning a NEW state. Pure: callers must not
 * assume the input was mutated, and must use the returned state.
 *
 * TODO(skeleton): once @war/logic publishes types, replace the defensive
 * `pick` with a direct typed import.
 */
export function applyAction(state: GameState, action: GameAction): EngineResult {
  const fn = pick<(s: GameState, a: GameAction) => EngineResult>("apply", "applyAction");
  const r = fn(state, action);
  // Normalize a few optional fields so downstream code never sees undefined.
  return {
    ok: Boolean(r?.ok),
    state: (r?.state ?? state) as GameState,
    events: Array.isArray(r?.events) ? r.events : [],
    error: typeof r?.error === "string" ? r.error : "",
  };
}

/**
 * Produce the initial dealt state for a brand-new match from a seed.
 * Equivalent to applying the "new_game" action to an empty state, but exposed
 * directly because most logic ports provide a dedicated constructor.
 */
export function newGame(seed: string): GameState {
  // Prefer a dedicated constructor; otherwise drive the engine with new_game.
  const ctor = (L["newGame"] ?? L["initialState"] ?? L["createGame"]) as
    | ((seed: string) => GameState)
    | undefined;
  if (typeof ctor === "function") return ctor(seed);

  // Fallback: apply the new_game action over a null/empty state.
  const r = applyAction({} as GameState, { type: "new_game", seed });
  if (!r.ok) throw new Error(`@war/logic could not start a new game: ${r.error}`);
  return r.state;
}

/** Determinism hash of a state (== hash_value(state) in the contract). */
export function stateHash(state: GameState): string {
  const fn = pick<(v: unknown) => string>("stateHash", "hashValue", "hashState");
  return fn(state);
}

/**
 * Canonical JSON string of a value — identical to GDScript canonical_stringify
 * and json-stable-stringify(x,{space:2}). This is the hash domain; always use
 * this (never JSON.stringify) when emitting state/action strings on the wire.
 */
export function canonicalStringify(value: unknown): string {
  const fn = pick<(v: unknown) => string>("canonicalStringify", "canonicalJson", "stableStringify");
  return fn(value);
}

/** Parse a canonical-JSON state string back into an object. */
export function parseState(json: string): GameState {
  return JSON.parse(json) as GameState;
}

/** Parse an action JSON string, asserting it carries a `type`. */
export function parseAction(json: string): GameAction {
  const a = JSON.parse(json) as Record<string, unknown>;
  if (typeof a?.type !== "string") {
    throw new Error("action JSON missing string `type` field");
  }
  return a as GameAction;
}

/** Read the `phase` field defensively for summaries/lifecycle checks. */
export function phaseOf(state: GameState): string {
  const p = (state as Record<string, unknown>)?.phase;
  return typeof p === "string" ? p : "unknown";
}

/** True when a phase is terminal (one side holds all 52 cards). */
export function isTerminalPhase(phase: string): boolean {
  return phase === "player_win" || phase === "cpu_win";
}
