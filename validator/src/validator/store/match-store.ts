/**
 * store/match-store.ts — in-memory authoritative match store.
 *
 * Holds the server's source-of-truth state for every live match, keyed by
 * match id, with a bound player id. This is intentionally a process-local
 * Map for the skeleton; a deployed validator would back this with a durable
 * store. The store does NOT know the rules — it asks @war/logic (via the
 * service) to compute new states and only persists the results.
 *
 * Player binding: each match remembers the playerId it was created for.
 * `apply` and `complete` require the caller to present the same playerId,
 * mirroring the gateway-stamped User-Id auth model. A mismatch is rejected.
 */

import { canonicalStringify, phaseOf, stateHash } from "../logic.ts";
import type { GameState, MatchRecord, MatchSummary } from "../types.ts";

/** Thrown when a caller's identity does not match the match's bound player. */
export class PlayerBindingError extends Error {
  constructor(matchId: string) {
    super(`player not authorized for match ${matchId}`);
    this.name = "PlayerBindingError";
  }
}

/** Thrown when a match id is unknown. */
export class MatchNotFoundError extends Error {
  constructor(matchId: string) {
    super(`match not found: ${matchId}`);
    this.name = "MatchNotFoundError";
  }
}

export class MatchStore {
  private readonly matches = new Map<string, MatchRecord>();

  /**
   * Create + persist a new match from an already-computed initial state.
   * The service computes the state via @war/logic and hands it here; the store
   * caches its canonical JSON + hash so reads are cheap.
   */
  init(matchId: string, playerId: string, seed: string, initialState: GameState): MatchRecord {
    if (this.matches.has(matchId)) {
      throw new Error(`match already exists: ${matchId}`);
    }
    const now = Date.now();
    const record: MatchRecord = {
      matchId,
      playerId,
      seed,
      state: initialState,
      stateJson: canonicalStringify(initialState),
      hash: stateHash(initialState),
      appliedCount: 0,
      completed: false,
      createdAt: now,
      updatedAt: now,
    };
    this.matches.set(matchId, record);
    return record;
  }

  /** Fetch a record or throw MatchNotFoundError. */
  get(matchId: string): MatchRecord {
    const r = this.matches.get(matchId);
    if (!r) throw new MatchNotFoundError(matchId);
    return r;
  }

  /** Fetch a record, asserting the player binding. */
  getForPlayer(matchId: string, playerId: string): MatchRecord {
    const r = this.get(matchId);
    if (r.playerId !== playerId) throw new PlayerBindingError(matchId);
    return r;
  }

  /** Non-throwing existence check (used by MCP/debug). */
  has(matchId: string): boolean {
    return this.matches.has(matchId);
  }

  /**
   * Persist a new authoritative state for a match after the service has run
   * the engine. Updates the cached JSON/hash and bumps the applied counter.
   * Enforces player binding. Returns the updated record.
   */
  applyAndPersist(matchId: string, playerId: string, nextState: GameState): MatchRecord {
    const r = this.getForPlayer(matchId, playerId);
    r.state = nextState;
    r.stateJson = canonicalStringify(nextState);
    r.hash = stateHash(nextState);
    r.appliedCount += 1;
    r.updatedAt = Date.now();
    return r;
  }

  /**
   * Mark a match complete. Idempotent. Records the terminal phase. Enforces
   * player binding. The record is retained (not deleted) so history endpoints
   * and post-match completion can still read it.
   */
  complete(matchId: string, playerId: string): MatchRecord {
    const r = this.getForPlayer(matchId, playerId);
    r.completed = true;
    r.finalPhase = phaseOf(r.state);
    r.updatedAt = Date.now();
    return r;
  }

  /** Remove a match entirely (debug/MCP clear_match). */
  delete(matchId: string): boolean {
    return this.matches.delete(matchId);
  }

  /** All match records (debug/history). */
  all(): MatchRecord[] {
    return [...this.matches.values()];
  }

  /** Lightweight summaries for list/history surfaces. */
  summaries(): MatchSummary[] {
    return this.all().map((r) => this.toSummary(r));
  }

  /** Project a record into its summary form. */
  toSummary(r: MatchRecord): MatchSummary {
    return {
      matchId: r.matchId,
      playerId: r.playerId,
      seed: r.seed,
      phase: phaseOf(r.state),
      hash: r.hash,
      appliedCount: r.appliedCount,
      completed: r.completed,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    };
  }

  /** Current live match count. */
  get size(): number {
    return this.matches.size;
  }
}

/** Process-wide singleton store. */
export const matchStore = new MatchStore();
