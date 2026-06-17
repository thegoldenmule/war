/**
 * types.ts — service-level types for @war/validator.
 *
 * NOTE on the hash domain: synchronized game **state** and **actions** are
 * never modeled as structured fields on the wire. They travel as canonical-JSON
 * STRINGS (see proto.ts / the shared contract) because the determinism hash is
 * computed over that exact canonical string. Inside this service we parse them
 * into the loose shapes below only to hand them to @war/logic; we re-serialize
 * with @war/logic's canonical stringifier before hashing or returning them.
 */

/**
 * The game state object as understood by @war/logic. We keep it permissive
 * here (the logic package owns the authoritative schema); the validator treats
 * state as an opaque blob it round-trips through the engine. The documented
 * shape is:
 *   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot,
 *     rng:{seq}, specials:{player,cpu}, pending_special, war_depth }
 */
export type GameState = Record<string, unknown>;

/** A unified player/CPU input action: { type, ...args }. Validated by @war/logic. */
export type GameAction = Record<string, unknown> & { type: string };

/**
 * Authoritative per-match record held in the in-memory store.
 * The store is the single source of truth for live matches.
 */
export interface MatchRecord {
  /** Opaque match id (assigned at InitMatch). */
  readonly matchId: string;
  /** Player identity bound at InitMatch; every action is checked against it. */
  readonly playerId: string;
  /** Seed string the match was initialized with (drives the deterministic shuffle). */
  readonly seed: string;
  /** Current authoritative state object (already-applied actions). */
  state: GameState;
  /** Canonical JSON string of `state`. Cached so we don't re-stringify on reads. */
  stateJson: string;
  /** Determinism hash of `state` (hash_value(state)). */
  hash: string;
  /** Monotonic count of successfully applied actions (audit / replay cursor). */
  appliedCount: number;
  /** Match lifecycle flag set true by completeMatch. */
  completed: boolean;
  /** Terminal phase recorded at completion ("player_win" | "cpu_win" | other). */
  finalPhase?: string;
  /** Epoch millis. */
  readonly createdAt: number;
  updatedAt: number;
}

/** Result of initMatch: the freshly-dealt authoritative state + hash. */
export interface InitResult {
  readonly matchId: string;
  readonly playerId: string;
  /** Canonical JSON of the initial state. */
  readonly stateJson: string;
  /** Determinism hash of the initial state. */
  readonly hash: string;
}

/**
 * Result of validateAction — the core authoritative answer.
 *
 * Reconcile contract:
 *  - ok === true  AND hashMatched === true  => fast path; client prediction
 *    was correct, it may keep its optimistic state. (We still return the
 *    authoritative JSON for completeness.)
 *  - ok === true  AND hashMatched === false => action was legal but the
 *    client's predicted hash diverged; client MUST snap to authoritativeStateJson.
 *  - ok === false => action was illegal/rejected by @war/logic; `error`
 *    explains why and the client keeps the prior authoritative state.
 */
export interface ValidateResult {
  /** Did @war/logic accept the action? */
  readonly ok: boolean;
  /** When ok: did the client's predictedHash equal the authoritative hash? */
  readonly hashMatched: boolean;
  /** Authoritative state after applying the action (canonical JSON string). */
  readonly authoritativeStateJson: string;
  /** Determinism hash of the authoritative state. */
  readonly hash: string;
  /** Domain events emitted by the engine for this transition (UI hints). */
  readonly events: unknown[];
  /** Human-readable error when ok === false; empty otherwise. */
  readonly error: string;
}

/** Result of completeMatch. */
export interface CompleteResult {
  readonly matchId: string;
  /** Terminal phase at completion. */
  readonly finalPhase: string;
  /** Final authoritative state hash. */
  readonly hash: string;
}

/** Lightweight projection used by debug/MCP/history surfaces. */
export interface MatchSummary {
  readonly matchId: string;
  readonly playerId: string;
  readonly seed: string;
  readonly phase: string;
  readonly hash: string;
  readonly appliedCount: number;
  readonly completed: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
}
