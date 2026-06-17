/**
 * Special Card resolution — parity twin of game/logic/special_cards.gd
 * (`WarSpecialCards`). The GDScript side is CANONICAL.
 *
 * resolve(state, special_id) -> { ok, state, events, error }
 *   Applies `special_id`'s effect to a COPY of `state` (never mutates the input
 *   across the hash boundary) and consumes the card from specials.player.
 *
 * Two kinds of effect, by catalog `when`:
 *   pre_flip  — resolves immediately and fully here (e.g. "peek" reveals the
 *               player's staged top card early). pending_special is cleared.
 *   post_flip — sets state.pending_special = id (engine honors it at resolve),
 *               and applies any immediate sub-effect (e.g. rank_boost mutates the
 *               staged card rank now).
 */

import { RANK_MAX, RANK_MIN, SPECIAL_CARDS } from "./constants.js";
import type { Card, GameEvent, GameState } from "./types.js";

/** Result of resolving a special — mirrors the GDScript {ok,state,events,error}. */
export interface SpecialResult {
  ok: boolean;
  state: GameState;
  events: GameEvent[];
  error: string;
}

/** Deep-clone a card. */
function cloneCard(c: Card): Card {
  return { rank: c.rank, suit: c.suit, face_up: c.face_up };
}

/** Deep-clone a card array. */
function cloneCards(cs: Card[]): Card[] {
  return cs.map(cloneCard);
}

/** Deep-clone a state so resolution never mutates the caller's object. */
function cloneState(s: GameState): GameState {
  return {
    version: s.version,
    seed: s.seed,
    phase: s.phase,
    player_deck: cloneCards(s.player_deck),
    cpu_deck: cloneCards(s.cpu_deck),
    player_pot: cloneCards(s.player_pot),
    cpu_pot: cloneCards(s.cpu_pot),
    rng: { seq: s.rng.seq },
    specials: {
      player: s.specials.player.slice(),
      cpu: s.specials.cpu.slice(),
    },
    pending_special: s.pending_special,
    war_depth: s.war_depth,
  };
}

function result(
  ok: boolean,
  state: GameState,
  events: GameEvent[],
  error: string,
): SpecialResult {
  return { ok, state, events, error };
}

/** All collectible special-card ids, in catalog declaration order. */
export function ids(): string[] {
  return Object.keys(SPECIAL_CARDS);
}

/** Is `id` a known, implementable special-card id? */
export function isValidId(id: unknown): boolean {
  return typeof id === "string" && Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, id);
}

/** Remove the first occurrence of `id` from state.specials.player. */
function consumeOwned(state: GameState, id: string): boolean {
  const owned = state.specials.player;
  const idx = owned.indexOf(id);
  if (idx < 0) {
    return false;
  }
  owned.splice(idx, 1);
  return true;
}

/**
 * Resolve `special_id` against `state`, returning { ok, state, events, error }.
 * Mirrors WarSpecialCards.resolve. Does NOT mutate the input state.
 */
export function resolve(state: GameState, specialId: string): SpecialResult {
  if (!Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, specialId)) {
    return result(false, state, [], "unknown_special");
  }

  const next = cloneState(state);
  const events: GameEvent[] = [];

  if (!consumeOwned(next, specialId)) {
    return result(false, state, [], "special_not_owned");
  }

  return applyEffect(next, specialId, events);
}

/** Per-id effect dispatch. Mirrors WarSpecialCards._apply. */
function applyEffect(
  next: GameState,
  specialId: string,
  events: GameEvent[],
): SpecialResult {
  switch (specialId) {
    case "peek": {
      const pot = next.player_pot;
      if (pot.length === 0) {
        return result(false, next, [], "peek_no_card");
      }
      const top = pot[pot.length - 1] as Card;
      top.face_up = true;
      events.push({
        type: "special_peek",
        card: { rank: top.rank, suit: top.suit },
      });
      next.pending_special = null;
      return result(true, next, events, "");
    }
    case "rank_boost": {
      const pot = next.player_pot;
      if (pot.length === 0) {
        return result(false, next, [], "rank_boost_no_card");
      }
      const card = pot[pot.length - 1] as Card;
      const oldRank = card.rank ?? RANK_MIN;
      const newRank = Math.min(oldRank + 2, RANK_MAX);
      card.rank = newRank;
      events.push({ type: "special_rank_boost", from: oldRank, to: newRank });
      next.pending_special = null;
      return result(true, next, events, "");
    }
    case "steal_tie": {
      next.pending_special = "steal_tie";
      events.push({ type: "special_steal_tie_armed" });
      return result(true, next, events, "");
    }
    default:
      return result(false, next, [], "special_not_implemented");
  }
}
