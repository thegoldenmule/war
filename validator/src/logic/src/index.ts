/**
 * @war/logic — public API.
 *
 * The byte-for-byte parity twin of the GDScript `game/logic` engine (which is
 * CANONICAL). For any (state, action) sequence this engine produces states whose
 * {@link stateHash} equals the GDScript `WarHasher` output for the equivalent
 * sequence.
 */

// Engine
export { newGame, apply, stateHash } from "./engine.js";

// Hashing (canonicalization + 8-lane rolling hash)
export {
  canonicalStringify,
  hashString,
  hashValue,
} from "./hashing.js";

// RNG (exposed for tooling / parity tests)
export {
  seedToWord,
  nextU32,
  nextBelow,
  shuffle,
  seedFrom,
  newRng,
} from "./rng.js";

// Special cards
export { resolve, ids, isValidId } from "./special-cards.js";
export type { SpecialResult } from "./special-cards.js";

// Constants / catalog
export {
  STATE_VERSION,
  RANK_MIN,
  RANK_MAX,
  RANKS,
  SUITS,
  DECK_SIZE,
  DEAL_SIZE,
  WAR_STAKE,
  PHASE_DEALT,
  PHASE_SELECTED,
  PHASE_FLIPPED,
  PHASE_WAR,
  PHASE_PLAYER_WIN,
  PHASE_CPU_WIN,
  WHEN_PRE_FLIP,
  WHEN_POST_FLIP,
  SPECIAL_CARDS,
  SPECIAL_CARD_IDS,
} from "./constants.js";
export type { SpecialCardDef } from "./constants.js";

// Types
export type {
  Suit,
  Phase,
  Card,
  RngState,
  SpecialsState,
  GameState,
  Action,
  NewGameAction,
  StartRoundAction,
  PlaySpecialAction,
  FlipAction,
  ResolveAction,
  AckWarAction,
  GameEvent,
  ApplyResult,
} from "./types.js";
