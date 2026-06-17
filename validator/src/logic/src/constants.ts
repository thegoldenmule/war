/**
 * Engine constants — parity twin of game/logic/constants.gd (`WarConstants`).
 *
 * These values define the deck composition, deal sizes, war staking, and the
 * Special Card catalog. The GDScript side is CANONICAL: ids, field set, and
 * numeric values here must match WarConstants exactly so resolution and hashing
 * stay identical on both engines. Insertion order of SPECIAL_CARDS is
 * load-bearing (both engines iterate the catalog by key).
 */

import type { Suit } from "./types.js";

/** Current hashed-state schema version. Bump if the state shape changes. */
export const STATE_VERSION = 1 as const;

/** Lowest / highest card rank (Ace high, never wraps). */
export const RANK_MIN = 2 as const;
export const RANK_MAX = 14 as const;

/** Card ranks, low to high. J=11, Q=12, K=13, A=14. */
export const RANKS: readonly number[] = [
  2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
];

/**
 * Suits in canonical order. The deal builds the deck in this order before
 * shuffling, so the pre-shuffle ordering is identical on both engines.
 */
export const SUITS: readonly Suit[] = ["clubs", "diamonds", "hearts", "spades"];

/** Total cards in a standard deck. */
export const DECK_SIZE = 52 as const;

/** Cards dealt to each side at the start of a match (52 / 2). */
export const DEAL_SIZE = 26 as const;

/**
 * Cards each side stakes face-down during a WAR before the deciding face-up
 * card. A stake of 3 plus the 1 deciding card means a war consumes 4 cards.
 * Matches WarConstants.WAR_STAKE (3).
 */
export const WAR_STAKE = 3 as const;

/** Phase string constants (state.phase). */
export const PHASE_DEALT = "dealt" as const;
export const PHASE_SELECTED = "selected" as const;
export const PHASE_FLIPPED = "flipped" as const;
export const PHASE_WAR = "war" as const;
export const PHASE_PLAYER_WIN = "player_win" as const;
export const PHASE_CPU_WIN = "cpu_win" as const;

/** Special-card timing windows (catalog "when" field). */
export const WHEN_PRE_FLIP = "pre_flip" as const;
export const WHEN_POST_FLIP = "post_flip" as const;

/**
 * A Special Card definition — mirrors the GDScript catalog value shape:
 * `{ name, when, desc }`. Both engines key off the catalog id.
 */
export interface SpecialCardDef {
  name: string;
  when: "pre_flip" | "post_flip";
  desc: string;
}

/**
 * The Special Card catalog — byte-for-byte mirror of WarConstants.SPECIAL_CARDS.
 * Keyed by id; insertion order is load-bearing.
 */
export const SPECIAL_CARDS: Readonly<Record<string, SpecialCardDef>> = {
  peek: {
    name: "Scrying Peek",
    when: "pre_flip",
    desc: "Before the flip, glimpse your own top card (reveals it face-up early). Pure information; does not change deck order.",
  },
  rank_boost: {
    name: "Rank Surge",
    when: "post_flip",
    desc: "After the flip, add +2 to the rank of your revealed card for this round's comparison only (does not persist on the card).",
  },
  steal_tie: {
    name: "Tie Thief",
    when: "post_flip",
    desc: "If this round is a tie, you win the pot outright instead of triggering a WAR.",
  },
};

/** All catalog ids in declaration order (for deterministic iteration). */
export const SPECIAL_CARD_IDS: readonly string[] = [
  "peek",
  "rank_boost",
  "steal_tie",
];
