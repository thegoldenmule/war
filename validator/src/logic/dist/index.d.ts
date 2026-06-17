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
type Suit = "clubs" | "diamonds" | "hearts" | "spades";
/**
 * Game phase, advanced by the engine state machine.
 * - dealt:      a fresh round; top cards face-down, awaiting a special or a flip.
 * - selected:   a pending_special has been staged for this round.
 * - flipped:    top cards revealed; awaiting `resolve` to award the pot.
 * - war:        a tie occurred; stakes are on the table awaiting `ack_war` then `flip`.
 * - player_win: player holds all 52 cards (terminal).
 * - cpu_win:    cpu holds all 52 cards (terminal).
 */
type Phase = "dealt" | "selected" | "flipped" | "war" | "player_win" | "cpu_win";
/** A single playing card. `face_up` reflects table visibility, not deck membership. */
interface Card {
    /** 2..14 (J=11, Q=12, K=13, A=14). */
    rank: number;
    suit: Suit;
    /** Whether the card is currently revealed on the table. */
    face_up: boolean;
}
/** Serialized RNG cursor. The seed lives in {@link GameState.seed}; only the cursor is mutable. */
interface RngState {
    /** Monotonic draw counter. Combined with the seed to derive each value. */
    seq: number;
}
/** Per-side inventory of owned Special Card ids. */
interface SpecialsState {
    player: string[];
    cpu: string[];
}
/**
 * The synchronized, hashed game state. Same shape on both engines.
 * Deck index 0 = top of deck (next to flip). Pots accumulate the current
 * round's wagered cards until awarded.
 */
interface GameState {
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
interface NewGameAction {
    type: "new_game";
    seed: string;
}
/** Begin a round: ensure top cards are dealt face-down (phase -> dealt). */
interface StartRoundAction {
    type: "start_round";
}
/** Stage a Special Card for the current round (phase dealt -> selected). */
interface PlaySpecialAction {
    type: "play_special";
    id: string;
}
/** Reveal both top cards (phase dealt|selected -> flipped, or resolves a war). */
interface FlipAction {
    type: "flip";
}
/** Award the pot to the winner of a flip (phase flipped -> dealt | win), or detect a tie -> war. */
interface ResolveAction {
    type: "resolve";
}
/** Acknowledge a war: stake the face-down war cards (phase war -> war, ready to flip). */
interface AckWarAction {
    type: "ack_war";
}
/** Unified player/CPU input. The engine dispatches on `type`. */
type Action = NewGameAction | StartRoundAction | PlaySpecialAction | FlipAction | ResolveAction | AckWarAction;
/** A single observable event emitted while applying an action (for presentation/animation cues). */
interface GameEvent {
    type: string;
    [key: string]: unknown;
}
/**
 * Result of {@link apply}. `ok=false` leaves `state` equal to the input state
 * (no mutation across the hash boundary) and sets `error`.
 */
interface ApplyResult {
    ok: boolean;
    state: GameState;
    events: GameEvent[];
    error: string;
}

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

/**
 * Create a fresh dealt match from `seed`: build the ordered deck, deterministic
 * shuffle, deal DEAL_SIZE to each side. Mirrors WarEngine.new_game.
 */
declare function newGame(seed: string): GameState;
declare function apply(state: GameState, action: Action): ApplyResult;
/** The canonical state hash (64 lowercase hex chars). */
declare function stateHash(state: GameState): string;

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
/**
 * Produce the canonical JSON string for `value` per the contract rules.
 * Equivalent to json-stable-stringify(value, { space: 2 }) with null-member
 * omission.
 */
declare function canonicalStringify(value: unknown): string;
/**
 * 8-lane rolling hash over the UTF-8 bytes of `s`. See the module docstring for
 * the exact algorithm. Returns 64 lowercase hex chars.
 */
declare function hashString(s: string): string;
/** Hash an arbitrary canonical-serializable value. */
declare function hashValue(value: unknown): string;

/**
 * Deterministic RNG — parity twin of game/logic/rng.gd (`WarRng`).
 *
 * The GDScript side is CANONICAL. This file reproduces it draw-for-draw:
 *
 *   - seed_to_word(seed): FNV-1a 32-bit fold of the seed's UTF-8 bytes; if it
 *     folds to 0, substitute the fixed non-zero constant 0x9E3779B9.
 *   - _step(x): one xorshift32 step with shifts 13/17/5 (each masked to 32 bits).
 *   - _state_word_for(seed, seq): re-seed and apply _step `seq` times (a CHAIN).
 *     The 32-bit working word is NEVER serialized; only the integer cursor
 *     `{seq}` is. Restoration replays from the seed.
 *   - next_u32(seed, rng): word for seq+1; advances seq by 1.
 *   - next_below(seed, rng, n): next_u32 value taken modulo n (PLAIN modulo, NO
 *     rejection sampling — matches GDScript exactly).
 *   - shuffle(seed, array, rng): Fisher-Yates, i from last index down to 1,
 *     drawing next_below(i+1) per iteration (this exact loop order + draw count).
 *
 * All arithmetic is performed in unsigned 32-bit space using `>>> 0`, mirroring
 * the GDScript manual masking to 0xFFFFFFFF.
 */

/**
 * Fold a seed string into a non-zero 32-bit state word using FNV-1a.
 * Mirrors WarRng.seed_to_word.
 */
declare function seedToWord(seed: string): number;
/**
 * Draw the next unsigned 32-bit value and advance the cursor.
 * Returns `{ value, rng: { seq } }`. Mirrors WarRng.next_u32.
 */
declare function nextU32(seed: string, rng: RngState): {
    value: number;
    rng: RngState;
};
/**
 * Draw an integer in [0, n) via PLAIN modulo (no rejection sampling — identical
 * to GDScript). Returns `{ value, rng: { seq } }`. Mirrors WarRng.next_below.
 */
declare function nextBelow(seed: string, rng: RngState, n: number): {
    value: number;
    rng: RngState;
};
/**
 * Deterministic Fisher-Yates shuffle of `array` (returns a NEW array; does not
 * mutate the input). Iterates i from last index down to 1, swapping element i
 * with element j drawn uniformly from [0, i]. Mirrors WarRng.shuffle exactly.
 */
declare function shuffle<T>(seed: string, array: readonly T[], rng: RngState): {
    array: T[];
    rng: RngState;
};
/** Build the initial RNG cursor from a seed string. Mirrors WarRng.seed_from. */
declare function seedFrom(_seed: string): RngState;
/** Initialize a fresh serialized RNG cursor. */
declare function newRng(): RngState;

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

/** Result of resolving a special — mirrors the GDScript {ok,state,events,error}. */
interface SpecialResult {
    ok: boolean;
    state: GameState;
    events: GameEvent[];
    error: string;
}
/** All collectible special-card ids, in catalog declaration order. */
declare function ids(): string[];
/** Is `id` a known, implementable special-card id? */
declare function isValidId(id: unknown): boolean;
/**
 * Resolve `special_id` against `state`, returning { ok, state, events, error }.
 * Mirrors WarSpecialCards.resolve. Does NOT mutate the input state.
 */
declare function resolve(state: GameState, specialId: string): SpecialResult;

/**
 * Engine constants — parity twin of game/logic/constants.gd (`WarConstants`).
 *
 * These values define the deck composition, deal sizes, war staking, and the
 * Special Card catalog. The GDScript side is CANONICAL: ids, field set, and
 * numeric values here must match WarConstants exactly so resolution and hashing
 * stay identical on both engines. Insertion order of SPECIAL_CARDS is
 * load-bearing (both engines iterate the catalog by key).
 */

/** Current hashed-state schema version. Bump if the state shape changes. */
declare const STATE_VERSION: 1;
/** Lowest / highest card rank (Ace high, never wraps). */
declare const RANK_MIN: 2;
declare const RANK_MAX: 14;
/** Card ranks, low to high. J=11, Q=12, K=13, A=14. */
declare const RANKS: readonly number[];
/**
 * Suits in canonical order. The deal builds the deck in this order before
 * shuffling, so the pre-shuffle ordering is identical on both engines.
 */
declare const SUITS: readonly Suit[];
/** Total cards in a standard deck. */
declare const DECK_SIZE: 52;
/** Cards dealt to each side at the start of a match (52 / 2). */
declare const DEAL_SIZE: 26;
/**
 * Cards each side stakes face-down during a WAR before the deciding face-up
 * card. A stake of 3 plus the 1 deciding card means a war consumes 4 cards.
 * Matches WarConstants.WAR_STAKE (3).
 */
declare const WAR_STAKE: 3;
/** Phase string constants (state.phase). */
declare const PHASE_DEALT: "dealt";
declare const PHASE_SELECTED: "selected";
declare const PHASE_FLIPPED: "flipped";
declare const PHASE_WAR: "war";
declare const PHASE_PLAYER_WIN: "player_win";
declare const PHASE_CPU_WIN: "cpu_win";
/** Special-card timing windows (catalog "when" field). */
declare const WHEN_PRE_FLIP: "pre_flip";
declare const WHEN_POST_FLIP: "post_flip";
/**
 * A Special Card definition — mirrors the GDScript catalog value shape:
 * `{ name, when, desc }`. Both engines key off the catalog id.
 */
interface SpecialCardDef {
    name: string;
    when: "pre_flip" | "post_flip";
    desc: string;
}
/**
 * The Special Card catalog — byte-for-byte mirror of WarConstants.SPECIAL_CARDS.
 * Keyed by id; insertion order is load-bearing.
 */
declare const SPECIAL_CARDS: Readonly<Record<string, SpecialCardDef>>;
/** All catalog ids in declaration order (for deterministic iteration). */
declare const SPECIAL_CARD_IDS: readonly string[];

export { type AckWarAction, type Action, type ApplyResult, type Card, DEAL_SIZE, DECK_SIZE, type FlipAction, type GameEvent, type GameState, type NewGameAction, PHASE_CPU_WIN, PHASE_DEALT, PHASE_FLIPPED, PHASE_PLAYER_WIN, PHASE_SELECTED, PHASE_WAR, type Phase, type PlaySpecialAction, RANKS, RANK_MAX, RANK_MIN, type ResolveAction, type RngState, SPECIAL_CARDS, SPECIAL_CARD_IDS, STATE_VERSION, SUITS, type SpecialCardDef, type SpecialResult, type SpecialsState, type StartRoundAction, type Suit, WAR_STAKE, WHEN_POST_FLIP, WHEN_PRE_FLIP, apply, canonicalStringify, hashString, hashValue, ids, isValidId, newGame, newRng, nextBelow, nextU32, resolve, seedFrom, seedToWord, shuffle, stateHash };
