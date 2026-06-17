/**
 * service.ts — ValidatorService: the authoritative core of @war/validator.
 *
 * This is the ONE place where War's rules are enforced on the server. Every
 * transport (gRPC, Hermes WS, MCP debug) funnels through these methods. The
 * service owns NO rules of its own — it re-runs @war/logic (the same engine the
 * client runs) and trusts that engine's verdict. Its job is:
 *   1. bind matches to players (auth),
 *   2. re-apply each action over the authoritative state,
 *   3. compare the recomputed hash to the client's predicted hash, and
 *   4. hand back the authoritative state so a mismatched client can snap to it.
 *
 * Determinism parity is the whole point: because @war/logic (TS) is byte-for-
 * byte equivalent to game/logic (GDScript), a correct client prediction always
 * yields hashMatched === true and the fast path is taken.
 */

import {
  applyAction,
  isTerminalPhase,
  newGame,
  parseAction,
  parseState,
  phaseOf,
  stateHash,
  canonicalStringify,
} from "./logic.ts";
import { matchStore, MatchStore } from "./store/match-store.ts";
import type {
  CompleteResult,
  GameState,
  InitResult,
  MatchSummary,
  ValidateResult,
} from "./types.ts";

/** Error carrying a machine-readable code for transport-layer mapping. */
export class ServiceError extends Error {
  constructor(
    message: string,
    readonly code: "INVALID_ARGUMENT" | "NOT_FOUND" | "PERMISSION_DENIED" | "FAILED_PRECONDITION",
  ) {
    super(message);
    this.name = "ServiceError";
  }
}

/** Generate an opaque, sortable-ish match id. */
function makeMatchId(): string {
  const rand = Math.random().toString(36).slice(2, 10);
  return `m_${Date.now().toString(36)}_${rand}`;
}

export class ValidatorService {
  constructor(private readonly store: MatchStore = matchStore) {}

  /**
   * InitMatch — deal a fresh deterministic game for `playerId` from `seed`.
   * The seed drives @war/logic's seeded shuffle, so (seed) fully determines the
   * initial 26/26 deal. Returns the canonical initial state + its hash; the
   * client mirrors this exact state to begin its optimistic loop.
   */
  initMatch(seed: string, playerId: string): InitResult {
    if (!seed || typeof seed !== "string") {
      throw new ServiceError("seed must be a non-empty string", "INVALID_ARGUMENT");
    }
    if (!playerId || typeof playerId !== "string") {
      throw new ServiceError("playerId must be a non-empty string", "INVALID_ARGUMENT");
    }

    const initialState = newGame(seed);
    const matchId = makeMatchId();
    const record = this.store.init(matchId, playerId, seed, initialState);

    return {
      matchId: record.matchId,
      playerId: record.playerId,
      stateJson: record.stateJson,
      hash: record.hash,
    };
  }

  /**
   * ValidateAction — the authoritative reconcile step.
   *
   * @param matchId        match to act on
   * @param playerId       caller identity; must match the bound player
   * @param actionJson     canonical-JSON action string ({ type, ...args })
   * @param predictedHash  the client's optimistically-computed next-state hash
   *
   * Flow: load authoritative state -> @war/logic.apply -> on reject, return
   * ok:false with the UNCHANGED authoritative state; on accept, persist the new
   * state, compare its hash to predictedHash, and return the authoritative
   * state + hash plus whether the prediction matched.
   */
  validateAction(
    matchId: string,
    playerId: string,
    actionJson: string,
    predictedHash: string,
  ): ValidateResult {
    const record = this.requireOpenMatch(matchId, playerId);

    let action;
    try {
      action = parseAction(actionJson);
    } catch (e) {
      throw new ServiceError(`malformed action JSON: ${(e as Error).message}`, "INVALID_ARGUMENT");
    }

    // Re-run the rules over the authoritative state. The engine is pure; we
    // pass a parsed copy of the persisted state so nothing is mutated across
    // the hash boundary even if the engine were to misbehave.
    const baseState: GameState = parseState(record.stateJson);
    const result = applyAction(baseState, action);

    if (!result.ok) {
      // Illegal move: keep authoritative state, do not advance.
      return {
        ok: false,
        hashMatched: false,
        authoritativeStateJson: record.stateJson,
        hash: record.hash,
        events: result.events,
        error: result.error || "action rejected by rules engine",
      };
    }

    // Legal move: persist and answer.
    const updated = this.store.applyAndPersist(matchId, playerId, result.state);
    const hashMatched = predictedHash !== "" && predictedHash === updated.hash;

    // Auto-complete on a terminal phase so the lifecycle is self-closing.
    if (isTerminalPhase(phaseOf(updated.state))) {
      this.store.complete(matchId, playerId);
    }

    return {
      ok: true,
      hashMatched,
      authoritativeStateJson: updated.stateJson,
      hash: updated.hash,
      events: result.events,
      error: "",
    };
  }

  /**
   * CompleteMatch — finalize a match (records terminal phase, retains record).
   * Safe to call even if already auto-completed via a terminal phase.
   */
  completeMatch(matchId: string, playerId: string): CompleteResult {
    const record = this.store.getForPlayer(matchId, playerId);
    const completed = this.store.complete(matchId, playerId);
    return {
      matchId: completed.matchId,
      finalPhase: completed.finalPhase ?? phaseOf(record.state),
      hash: completed.hash,
    };
  }

  // ---- read / debug helpers (used by MCP + history routes) ----------------

  /** All match summaries. */
  listMatches(): MatchSummary[] {
    return this.store.summaries();
  }

  /** Full canonical state JSON for a match (debug). */
  getMatchStateJson(matchId: string): string {
    return this.store.get(matchId).stateJson;
  }

  /** Summary for one match. */
  getMatchSummary(matchId: string): MatchSummary {
    return this.store.toSummary(this.store.get(matchId));
  }

  /**
   * Dry-run an action against a match WITHOUT persisting (debug/MCP).
   * Lets tools preview the engine verdict + resulting hash without mutating the
   * authoritative timeline.
   */
  simulateAction(matchId: string, actionJson: string): ValidateResult {
    const record = this.store.get(matchId);
    const action = parseAction(actionJson);
    const result = applyAction(parseState(record.stateJson), action);
    if (!result.ok) {
      return {
        ok: false,
        hashMatched: false,
        authoritativeStateJson: record.stateJson,
        hash: record.hash,
        events: result.events,
        error: result.error || "action rejected by rules engine",
      };
    }
    const json = canonicalStringify(result.state);
    return {
      ok: true,
      hashMatched: false, // simulation does not advance, so nothing matched
      authoritativeStateJson: json,
      hash: stateHash(result.state),
      events: result.events,
      error: "",
    };
  }

  /** Remove a match (debug/MCP). */
  clearMatch(matchId: string): boolean {
    return this.store.delete(matchId);
  }

  // ---- internals ----------------------------------------------------------

  /** Load a match for a player and assert it is still open. */
  private requireOpenMatch(matchId: string, playerId: string) {
    const record = this.store.getForPlayer(matchId, playerId);
    if (record.completed) {
      throw new ServiceError(`match already completed: ${matchId}`, "FAILED_PRECONDITION");
    }
    return record;
  }
}

/** Process-wide singleton service over the singleton store. */
export const validatorService = new ValidatorService();
