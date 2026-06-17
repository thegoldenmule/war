@tool
class_name WarConstants
extends RefCounted

## Static game constants for "War" — the deck definition, deal sizes, phase
## string constants, action-type tokens, and the SPECIAL_CARDS catalog.
##
## This file is the single source of truth for the rules-engine vocabulary. It
## MUST stay byte-for-byte equivalent (same values, same insertion order) with
## the TypeScript validator/src/logic/constants.ts so that determinism parity
## holds: insertion order of SPECIAL_CARDS is load-bearing because the engine
## and validator iterate the catalog by key, and any drift would change hashes.
##
## Pure constants only — zero Node / scene dependencies, headless-loadable.

# ---------------------------------------------------------------------------
# Deck definition
# ---------------------------------------------------------------------------

## Card ranks, ascending. 2..10 are pip cards; J=11, Q=12, K=13, A=14.
## Rank comparison is a plain integer compare; Ace is high (14) and never wraps.
const RANK_MIN := 2
const RANK_MAX := 14
const RANKS := [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]

## Suits in canonical order. Order is load-bearing: new_game() builds the
## ordered 52-card deck as (for each suit, for each rank) before shuffling, so
## both engines must enumerate suits identically to produce identical decks.
const SUIT_CLUBS := "clubs"
const SUIT_DIAMONDS := "diamonds"
const SUIT_HEARTS := "hearts"
const SUIT_SPADES := "spades"
const SUITS := ["clubs", "diamonds", "hearts", "spades"]

## Total cards in a standard deck (len(RANKS) * len(SUITS)).
const DECK_SIZE := 52

## Cards dealt to each side at the start of a match. 26 + 26 = 52.
const DEAL_SIZE := 26

## Cards each player stakes face-down during a WAR before the deciding face-up
## card. A stake of 3 plus the 1 deciding card means a war consumes 4 cards.
const WAR_STAKE := 3

# ---------------------------------------------------------------------------
# State version
# ---------------------------------------------------------------------------

## Schema version embedded in every state. Bump when the state shape changes in
## a way that would alter the canonical serialization / hash domain.
const STATE_VERSION := 1

# ---------------------------------------------------------------------------
# Phases (state.phase)
# ---------------------------------------------------------------------------

## "dealt"     — round not yet started; decks dealt or previous round resolved.
## "selected"  — a pre-flip special has been queued (pending_special set).
## "flipped"   — both top cards are face-up, awaiting resolve.
## "war"       — a tie occurred; players are staking war cards.
## "player_win"— player holds all 52 cards (terminal).
## "cpu_win"   — cpu holds all 52 cards (terminal).
const PHASE_DEALT := "dealt"
const PHASE_SELECTED := "selected"
const PHASE_FLIPPED := "flipped"
const PHASE_WAR := "war"
const PHASE_PLAYER_WIN := "player_win"
const PHASE_CPU_WIN := "cpu_win"

## Convenience set of terminal phases.
const TERMINAL_PHASES := ["player_win", "cpu_win"]

# ---------------------------------------------------------------------------
# Action types (action.type)
# ---------------------------------------------------------------------------

const ACTION_NEW_GAME := "new_game"
const ACTION_START_ROUND := "start_round"
const ACTION_PLAY_SPECIAL := "play_special"
const ACTION_FLIP := "flip"
const ACTION_RESOLVE := "resolve"
const ACTION_ACK_WAR := "ack_war"

const ACTION_TYPES := [
	"new_game",
	"start_round",
	"play_special",
	"flip",
	"resolve",
	"ack_war",
]

# ---------------------------------------------------------------------------
# Special-card timing windows (catalog "when" field)
# ---------------------------------------------------------------------------

## A special played BEFORE the flip is revealed (the Balatro-style hook).
const WHEN_PRE_FLIP := "pre_flip"
## A special played AFTER cards are revealed (e.g. to alter resolution).
const WHEN_POST_FLIP := "post_flip"

# ---------------------------------------------------------------------------
# Special Cards catalog (id -> {name, when, desc})
# ---------------------------------------------------------------------------
#
# Collectible power-ups played around a flip. The catalog is the contract: ids
# here are the only legal `play_special` ids, and WarSpecialCards.resolve()
# implements the effects. Insertion order is load-bearing (see file header).
# `when` controls which phase the special may be queued/played in.
#
# Effects are validator-authoritative and resolve inside the deterministic
# engine; this dict carries only the metadata (no behavior).

const SPECIAL_CARDS := {
	"peek": {
		"name": "Scrying Peek",
		"when": "pre_flip",
		"desc": "Before the flip, glimpse your own top card (reveals it face-up early). Pure information; does not change deck order.",
	},
	"rank_boost": {
		"name": "Rank Surge",
		"when": "post_flip",
		"desc": "After the flip, add +2 to the rank of your revealed card for this round's comparison only (does not persist on the card).",
	},
	"steal_tie": {
		"name": "Tie Thief",
		"when": "post_flip",
		"desc": "If this round is a tie, you win the pot outright instead of triggering a WAR.",
	},
}

## All catalog ids in declaration order (for deterministic iteration).
const SPECIAL_CARD_IDS := ["peek", "rank_boost", "steal_tie"]
