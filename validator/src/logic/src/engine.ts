/**
 * War rules engine — parity twin of game/logic/engine.gd (`WarEngine`).
 * The GDScript side is CANONICAL.
 *
 * PURE & DETERMINISTIC. {@link apply} returns a NEW state (never mutates the
 * input across the hash boundary). Every transition mirrors WarEngine step-for-
 * step so the two engines compute identical states, hashes, and events.
 *
 * PHASE MACHINE (mirrors WarEngine / WarValidation):
 *   dealt    --start_round--> selected   (stage top card face-down on each side)
 *   selected --play_special(pre_flip)--> selected
 *   selected --flip--> flipped           (reveal; a TIE goes straight to "war")
 *   flipped  --play_special(post_flip)--> flipped
 *   flipped  --resolve--> dealt          (award the pot to the higher rank)
 *   war      --ack_war/resolve--> dealt | war
 *   any non-terminal --(deck emptied)--> player_win | cpu_win
 */

import {
  DEAL_SIZE,
  PHASE_CPU_WIN,
  PHASE_DEALT,
  PHASE_FLIPPED,
  PHASE_PLAYER_WIN,
  PHASE_SELECTED,
  PHASE_WAR,
  RANKS,
  STATE_VERSION,
  SUITS,
  WAR_STAKE,
  WHEN_PRE_FLIP,
  SPECIAL_CARDS,
} from "./constants.js";
import { seedFrom, shuffle } from "./rng.js";
import { resolve as resolveSpecial } from "./special-cards.js";
import type {
  Action,
  ApplyResult,
  Card,
  GameEvent,
  GameState,
  RngState,
} from "./types.js";

// --------------------------------------------------------------------------
// Small pure helpers
// --------------------------------------------------------------------------

function cloneCard(c: Card): Card {
  return { rank: c.rank, suit: c.suit, face_up: c.face_up };
}

function cloneCards(cs: Card[]): Card[] {
  return cs.map(cloneCard);
}

/** Deep-clone a state (matches GDScript state.duplicate(true)). */
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

/** Build the ordered 52-card deck (suit-major, rank-minor), all face-down. */
function buildDeck(): Card[] {
  const deck: Card[] = [];
  for (const suit of SUITS) {
    for (const rank of RANKS) {
      deck.push({ rank, suit, face_up: false });
    }
  }
  return deck;
}

function makeResult(
  ok: boolean,
  state: GameState,
  events: GameEvent[],
  error: string,
): ApplyResult {
  return { ok, state, events, error };
}

/** Failure result: echoes the input state unchanged. */
function fail(state: GameState, error: string): ApplyResult {
  return makeResult(false, state, [], error);
}

// --------------------------------------------------------------------------
// New game
// --------------------------------------------------------------------------

/**
 * Create a fresh dealt match from `seed`: build the ordered deck, deterministic
 * shuffle, deal DEAL_SIZE to each side. Mirrors WarEngine.new_game.
 */
export function newGame(seed: string): GameState {
  let rng: RngState = seedFrom(seed);
  const deck0 = buildDeck();
  const shuffled = shuffle(seed, deck0, rng);
  const deck = shuffled.array;
  rng = shuffled.rng;

  const player_deck = deck.slice(0, DEAL_SIZE);
  const cpu_deck = deck.slice(DEAL_SIZE, DEAL_SIZE * 2);

  return {
    version: STATE_VERSION,
    seed,
    phase: PHASE_DEALT,
    player_deck,
    cpu_deck,
    player_pot: [],
    cpu_pot: [],
    rng,
    specials: { player: [], cpu: [] },
    pending_special: null,
    war_depth: 0,
  };
}

// --------------------------------------------------------------------------
// Phase-legality gate (mirrors WarValidation.check)
// --------------------------------------------------------------------------

function checkLegal(state: GameState, action: Action): string {
  const type = action.type;
  const phase = state.phase;

  if (type === "new_game") {
    return "";
  }

  if (phase === PHASE_PLAYER_WIN || phase === PHASE_CPU_WIN) {
    return "game_over";
  }

  switch (type) {
    case "start_round":
      if (phase !== PHASE_DEALT) {
        return "start_round_wrong_phase";
      }
      if (state.player_deck.length === 0 || state.cpu_deck.length === 0) {
        return "start_round_empty_deck";
      }
      return "";
    case "play_special": {
      const id = action.id;
      if (!Object.prototype.hasOwnProperty.call(SPECIAL_CARDS, id)) {
        return "unknown_special";
      }
      if (!state.specials.player.includes(id)) {
        return "special_not_owned";
      }
      if (state.pending_special !== null) {
        return "special_already_pending";
      }
      const when = SPECIAL_CARDS[id]!.when;
      if (when === WHEN_PRE_FLIP) {
        if (phase !== PHASE_DEALT && phase !== PHASE_SELECTED) {
          return "pre_flip_wrong_phase";
        }
      } else {
        if (phase !== PHASE_FLIPPED && phase !== PHASE_WAR) {
          return "post_flip_wrong_phase";
        }
      }
      return "";
    }
    case "flip":
      if (phase !== PHASE_SELECTED) {
        return "flip_wrong_phase";
      }
      return "";
    case "resolve":
      if (phase !== PHASE_FLIPPED && phase !== PHASE_WAR) {
        return "resolve_wrong_phase";
      }
      return "";
    case "ack_war":
      if (phase !== PHASE_WAR) {
        return "ack_war_wrong_phase";
      }
      return "";
    default:
      return "unknown_action";
  }
}

// --------------------------------------------------------------------------
// Public entry (mirrors WarEngine.apply)
// --------------------------------------------------------------------------

export function apply(state: GameState, action: Action): ApplyResult {
  if (action.type === "new_game") {
    return makeResult(
      true,
      newGame(action.seed),
      [{ type: "new_game", seed: action.seed }],
      "",
    );
  }

  const legalError = checkLegal(state, action);
  if (legalError !== "") {
    return fail(state, legalError);
  }

  const next = cloneState(state);

  switch (action.type) {
    case "start_round":
      return startRound(next);
    case "play_special":
      return playSpecial(next, action.id);
    case "flip":
      return flip(next);
    case "resolve":
      if (next.phase === PHASE_WAR) {
        return ackWar(next);
      }
      return resolveRound(next);
    case "ack_war":
      return ackWar(next);
    default:
      return fail(state, "unknown_action");
  }
}

// --------------------------------------------------------------------------
// start_round: stage the top card of each deck into the pots (face_down)
// --------------------------------------------------------------------------

function startRound(next: GameState): ApplyResult {
  const pCard = next.player_deck.shift() as Card;
  const cCard = next.cpu_deck.shift() as Card;
  pCard.face_up = false;
  cCard.face_up = false;
  next.player_pot.push(pCard);
  next.cpu_pot.push(cCard);
  next.war_depth = 0;
  next.pending_special = null;
  next.phase = PHASE_SELECTED;
  return makeResult(true, next, [{ type: "round_staged" }], "");
}

// --------------------------------------------------------------------------
// play_special: delegate to special-cards
// --------------------------------------------------------------------------

function playSpecial(next: GameState, id: string): ApplyResult {
  const res = resolveSpecial(next, id);
  if (!res.ok) {
    return fail(next, res.error);
  }
  return makeResult(true, res.state, res.events, "");
}

// --------------------------------------------------------------------------
// flip: reveal both staged top cards; a tie escalates immediately to WAR
// --------------------------------------------------------------------------

function flip(next: GameState): ApplyResult {
  const pp = next.player_pot;
  const cp = next.cpu_pot;
  const pTop = pp[pp.length - 1] as Card;
  const cTop = cp[cp.length - 1] as Card;
  pTop.face_up = true;
  cTop.face_up = true;
  const pRank = pTop.rank;
  const cRank = cTop.rank;
  const events: GameEvent[] = [
    {
      type: "flip",
      player: topSummary(pp),
      cpu: topSummary(cp),
    },
  ];
  if (pRank === cRank && next.pending_special !== "steal_tie") {
    events.push({ type: "tie", rank: pRank });
    next.war_depth = 1;
    next.phase = PHASE_WAR;
  } else {
    next.phase = PHASE_FLIPPED;
  }
  return makeResult(true, next, events, "");
}

// --------------------------------------------------------------------------
// resolve: award the revealed (flipped) round to the higher rank
// --------------------------------------------------------------------------

function resolveRound(next: GameState): ApplyResult {
  const pp = next.player_pot;
  const cp = next.cpu_pot;
  const pRank = (pp[pp.length - 1] as Card).rank;
  const cRank = (cp[cp.length - 1] as Card).rank;
  const events: GameEvent[] = [];

  if (pRank > cRank) {
    awardPotsTo(next, "player", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else if (cRank > pRank) {
    awardPotsTo(next, "cpu", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else {
    if (next.pending_special === "steal_tie") {
      events.push({ type: "steal_tie_fired" });
      awardPotsTo(next, "player", events);
      next.pending_special = null;
      next.war_depth = 0;
      return finishRound(next, events);
    }
    events.push({ type: "tie", rank: pRank });
    next.pending_special = null;
    next.war_depth = Math.max(1, next.war_depth);
    next.phase = PHASE_WAR;
    return makeResult(true, next, events, "");
  }
}

// --------------------------------------------------------------------------
// ack_war: stake WAR_STAKE face-down + 1 face-up per side; compare deciders
// --------------------------------------------------------------------------

function ackWar(next: GameState): ApplyResult {
  const pd = next.player_deck;
  const cd = next.cpu_deck;

  const need = WAR_STAKE + 1;
  const pShort = pd.length < need;
  const cShort = cd.length < need;
  const events: GameEvent[] = [];

  if (pShort || cShort) {
    let winner: "player" | "cpu";
    if (pShort && cShort) {
      winner = pd.length > cd.length ? "player" : "cpu";
    } else if (pShort) {
      winner = "cpu";
    } else {
      winner = "player";
    }
    events.push({ type: "war_forfeit", winner });
    awardPotsTo(next, winner, events);
    next.pending_special = null;
    next.war_depth = 0;
    next.phase = winner === "player" ? PHASE_PLAYER_WIN : PHASE_CPU_WIN;
    events.push({ type: "game_over", winner });
    return makeResult(true, next, events, "");
  }

  for (let i = 0; i < WAR_STAKE; i++) {
    const pfd = pd.shift() as Card;
    const cfd = cd.shift() as Card;
    pfd.face_up = false;
    cfd.face_up = false;
    next.player_pot.push(pfd);
    next.cpu_pot.push(cfd);
  }

  const pDec = pd.shift() as Card;
  const cDec = cd.shift() as Card;
  pDec.face_up = true;
  cDec.face_up = true;
  next.player_pot.push(pDec);
  next.cpu_pot.push(cDec);
  next.war_depth = next.war_depth + 1;

  const pRank = pDec.rank;
  const cRank = cDec.rank;
  events.push({
    type: "war_decide",
    depth: next.war_depth,
    player: pRank,
    cpu: cRank,
  });

  if (pRank > cRank) {
    awardPotsTo(next, "player", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else if (cRank > pRank) {
    awardPotsTo(next, "cpu", events);
    next.pending_special = null;
    next.war_depth = 0;
    return finishRound(next, events);
  } else {
    events.push({ type: "tie", rank: pRank });
    next.phase = PHASE_WAR;
    return makeResult(true, next, events, "");
  }
}

// --------------------------------------------------------------------------
// Award / round-finish helpers
// --------------------------------------------------------------------------

/**
 * Move BOTH pots to the bottom of `winner`'s deck (winner's pot first, then the
 * loser's pot), face_down. Clears both pots. Mirrors WarEngine._award_pots_to.
 */
function awardPotsTo(
  next: GameState,
  winner: "player" | "cpu",
  events: GameEvent[],
): void {
  const winnerDeck = winner === "player" ? next.player_deck : next.cpu_deck;
  let won = 0;
  for (const card of next.player_pot) {
    card.face_up = false;
    winnerDeck.push(card);
    won += 1;
  }
  for (const card of next.cpu_pot) {
    card.face_up = false;
    winnerDeck.push(card);
    won += 1;
  }
  next.player_pot = [];
  next.cpu_pot = [];
  events.push({ type: "award", winner, cards: won });
}

/** Set the resting phase and check for a terminal win. */
function finishRound(next: GameState, events: GameEvent[]): ApplyResult {
  next.phase = PHASE_DEALT;
  return checkWin(next, events);
}

/** Detect a terminal state: one side holds all cards (other empty). */
function checkWin(next: GameState, events: GameEvent[]): ApplyResult {
  const p = next.player_deck.length;
  const c = next.cpu_deck.length;
  if (c === 0 && p > 0) {
    next.phase = PHASE_PLAYER_WIN;
    events.push({ type: "game_over", winner: "player" });
  } else if (p === 0 && c > 0) {
    next.phase = PHASE_CPU_WIN;
    events.push({ type: "game_over", winner: "cpu" });
  }
  return makeResult(true, next, events, "");
}

/** A compact {rank, suit} summary of a pot's top card (for events). */
function topSummary(pot: Card[]): Record<string, unknown> {
  if (pot.length === 0) {
    return {};
  }
  const top = pot[pot.length - 1] as Card;
  return { rank: top.rank, suit: top.suit };
}

// --------------------------------------------------------------------------
// Determinism hash entry (re-exported via index)
// --------------------------------------------------------------------------

import { hashValue } from "./hashing.js";

/** The canonical state hash (64 lowercase hex chars). */
export function stateHash(state: GameState): string {
  return hashValue(state);
}
