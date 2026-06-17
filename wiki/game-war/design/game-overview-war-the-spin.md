# Game Overview — War, the Spin

**Status:** active

## Body
# Game Overview — War, the Spin

This document is a design overview of **War, the Spin** — a hypercasual reimagining of the classic card game War. It covers the premise, the core loop, the two signature moments (the flip and the WAR), and the win condition.

## Premise

**War, the Spin** is a single-player, hypercasual spin on classic War. You play head-to-head against a CPU opponent in fast, snackable rounds. The twist that gives the game its name is a layer of **collectible Special Cards** — Balatro-style power-ups you can play at the decisive moment to bend the odds in your favor. The classic rules stay intact; the spin is what you bring to each reveal.

## Core loop

A match begins by shuffling a standard 52-card deck and dealing **26 cards to each player**. Each round, both players reveal the top card of their stack; the **higher rank** wins and takes both cards. The loop repeats round after round until one player holds the entire deck.

Each round advances through a small set of phases:

| **Phase** | **Meaning** |
| :--- | :--- |
| `dealt` | Both players have a face-down card on top of their stack, ready for the round. |
| `selected` | The player has chosen whether to play a Special Card before the reveal. |
| `flipped` | Both top cards are turned face-up and their ranks are compared. |
| `war` | The two face-up cards tied, triggering a WAR to break the tie. |
| `win` | One player has captured all 52 cards and the match is over. |

## The flip moment

The signature hook is that cards are dealt **face-down**. Before either top card is revealed, the player gets a beat to act: they may optionally play a **Special Card** from their collection to influence the outcome. Because the reveal has not happened yet, this is a moment of pure anticipation — commit a power-up, or hold it and let the flip decide. This optional pre-reveal decision is the core hook and the game's primary monetization surface.

## The WAR moment

When the two revealed cards share the same rank, the round escalates into a **WAR**. The WAR resolves as follows:

1. **Each player stakes 3 cards face-down** into the pot.
2. **Each player then places 1 card face-up** on top of their stake.
3. The **higher face-up card** wins the entire pot — every staked card.
4. If the face-up cards tie again, the WAR **repeats**: another 3 face-down plus 1 face-up, until the tie is broken.

The WAR is the dramatic peak of the match and is presented with a full-screen **dramatic overlay** to heighten the tension as the pot grows.

## Win condition

A match ends when one player **holds all 52 cards** — the opponent has run out. That player wins the match.

## Architecture note

Behind the presentation sits a determinism-parity architecture: the GDScript rules engine is byte-for-byte hash-identical to an authoritative TypeScript validator, so the client plays optimistically and reconciles every round against the server-of-record.

## References
_None._

## Child pages
_None._
