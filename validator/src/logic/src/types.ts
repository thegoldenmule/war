/**
 * Shared state & action types for the War rules engine.
 *
 * These types are the TypeScript projection of the SHARED CONTRACT state and
 * action schemas. The GDScript twin (game/logic) uses untyped Dictionaries of
 * the IDENTICAL shape — when serialized via {@link canonicalStringify} the two
 * sides produce byte-for-byte equal JSON, and therefore equal state hashes.
 *
 * IMPORTANT (hash domain): the canonical hash is computed over the JSON of a
 * GameState. Any field whose value is `null` is OMITTED from the canonical
 * JSON (see hashing.ts). `pending_special` is therefore `null` when no special
 * is staged, and simply absent from the hashed bytes in that case.
 */

/** A suit identifier. Lexicographic order matters nowhere in logic but is fixed for determinism. */
export type Suit = "clubs" | "diamonds" | "hearts" | "spades";

/**
 * Game phase, advanced by the engine state machine.
 * - dealt:      a fresh round; top cards face-down, awaiting a special or a flip.
 * - selected:   a pending_special has been staged for this round.
 * - flipped:    top cards revealed; awaiting `resolve` to award the pot.
 * - war:        a tie occurred; stakes are on the table awaiting `ack_war` then `flip`.
 * - player_win: player holds all 52 cards (terminal).
 * - cpu_win:    cpu holds all 52 cards (terminal).
 */
export type Phase =
  | "dealt"
  | "selected"
  | "flipped"
  | "war"
  | "player_win"
  | "cpu_win";

/** A single playing card. `face_up` reflects table visibility, not deck membership. */
export interface Card {
  /** 2..14 (J=11, Q=12, K=13, A=14). */
  rank: number;
  suit: Suit;
  /** Whether the card is currently revealed on the table. */
  face_up: boolean;
}

/** Serialized RNG cursor. The seed lives in {@link GameState.seed}; only the cursor is mutable. */
export interface RngState {
  /** Monotonic draw counter. Combined with the seed to derive each value. */
  seq: number;
}

/** Per-side inventory of owned Special Card ids. */
export interface SpecialsState {
  player: string[];
  cpu: string[];
}

/**
 * The synchronized, hashed game state. Same shape on both engines.
 * Deck index 0 = top of deck (next to flip). Pots accumulate the current
 * round's wagered cards until awarded.
 */
export interface GameState {
  /** Schema version; bumped if the hashed shape changes. */
  version: number;
  /** Match seed string; drives the deterministic deal and all RNG. */
  seed: string;
  phase: Phase;
  player_deck: Card[];
  cpu_deck: Card[];
  /** Cards the player has wagered into the current round/war (not yet awarded). */
  player_pot: Card[];
  /** Cards the cpu has wagered into the current round/war (not yet awarded). */
  cpu_pot: Card[];
  rng: RngState;
  specials: SpecialsState;
  /** Id of the special staged for this round, or null if none. OMITTED from canonical JSON when null. */
  pending_special: string | null;
  /** How many nested wars are currently stacked (0 = no war). */
  war_depth: number;
}

/** New game: deal a fresh 52-card match from `seed`. */
export interface NewGameAction {
  type: "new_game";
  seed: string;
}
/** Begin a round: ensure top cards are dealt face-down (phase -> dealt). */
export interface StartRoundAction {
  type: "start_round";
}
/** Stage a Special Card for the current round (phase dealt -> selected). */
export interface PlaySpecialAction {
  type: "play_special";
  id: string;
}
/** Reveal both top cards (phase dealt|selected -> flipped, or resolves a war). */
export interface FlipAction {
  type: "flip";
}
/** Award the pot to the winner of a flip (phase flipped -> dealt | win), or detect a tie -> war. */
export interface ResolveAction {
  type: "resolve";
}
/** Acknowledge a war: stake the face-down war cards (phase war -> war, ready to flip). */
export interface AckWarAction {
  type: "ack_war";
}

/** Unified player/CPU input. The engine dispatches on `type`. */
export type Action =
  | NewGameAction
  | StartRoundAction
  | PlaySpecialAction
  | FlipAction
  | ResolveAction
  | AckWarAction;

/** A single observable event emitted while applying an action (for presentation/animation cues). */
export interface GameEvent {
  type: string;
  [key: string]: unknown;
}

/**
 * Result of {@link apply}. `ok=false` leaves `state` equal to the input state
 * (no mutation across the hash boundary) and sets `error`.
 */
export interface ApplyResult {
  ok: boolean;
  state: GameState;
  events: GameEvent[];
  error: string;
}
