# Feature: The I-Declare-War Moment

**Status:** draft

## Summary
The I-Declare-War moment is the dramatic tie-breaker at the heart of the game's core loop. When both players reveal cards of matching rank, a full-screen WAR overlay ("I. DECLARE. WAR.") plays. Each side then stakes 3 cards face-down plus 1 card face-up; the higher face-up card wins the entire pot. If the face-up cards tie again, the war repeats at an incremented war_depth, stacking the pot until one side wins or can no longer complete a war. The WarEngine resolves staking, win determination, and edge cases deterministically so the GDScript and TypeScript engines stay hash-identical, while the overlay scene reads engine state only and never mutates it.

## Components affected
- WarEngine war staking + win/edge-case handling
- WAR overlay scene + animation
- Optional Special-Card play during a war

## Design constraints
1. The can-not-complete-a-war loss edge case (a player lacking enough cards to stake the full 3 face-down + 1 face-up) must be resolved deterministically and identically in both the GDScript and TypeScript engines.
2. The WAR overlay reads engine state only; it must never mutate game state.

## Open questions
1. **Should a player be allowed to play a Special Card mid-war, and if so at which stake step (before the face-up reveal of each war round, or only at the initial tie)?**
2. **What is the right WAR overlay animation length to balance dramatic payoff against game pacing, especially across repeated deep wars (high war_depth)?**

## Resolved questions
_None._

## References
_None._

## Child pages
- [Implementation plan — The I-Declare-War Moment](implementation-plan:mqifja8m-00du-ly4mjg)
- [Testing plan — The I-Declare-War Moment](testing-plan:mqifja8m-00dv-sj5yan)
- [Spec — The I-Declare-War Moment](feature-spec:mqifja8m-00dw-a6xnve)

## Commits
_None._
