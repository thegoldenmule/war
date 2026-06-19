# Feature: The I-Declare-War Moment

**Status:** draft

## Summary
The I-Declare-War moment is the dramatic tie-breaker at the heart of the game's core loop. When both players reveal cards of matching rank, a full-screen WAR overlay plays. Each side then stakes 3 cards face-down plus 1 card face-up; the higher face-up card wins the entire pot. If the face-up cards tie again, the war repeats at an incremented war_depth, stacking the pot until one side wins or can no longer complete a war. The WarEngine resolves staking, win determination, and edge cases deterministically so the GDScript and TypeScript engines stay hash-identical, while the overlay scene reads engine state only and never mutates it.

As built (presentation pass, parity-safe): the WAR card mechanic was already implemented and golden-vector-locked in WarEngine, so this pass shipped PRESENTATION only and hung off the existing WAR_BANNER / WAR_PROMPT / WAR_REVEALING beats with ZERO engine, Round-Director, or hash change (verify_determinism stays PASS). Delivered: the "IT'S WAR!" prompt modal (DECLARE WAR commit), the "I DECLARE WAR!" reveal (WAR_STAKE face-down backs + 1 face-up decider per side, painted rank-only from the war_decide event, winner outlined green / loser red, with a staggered pop-in and CONTINUE / tap-anywhere to advance), and the reusable "Using a Special Card" carousel (catalog name + description, N/total paging, USE SPECIAL) wired to the flip-moment USE SPECIAL. New presentation files: ui/modals/special_card_carousel.gd + WarCardVisual.paint_rank; verified by verify_war_moment.gd and verify_special_carousel.gd. Two pieces are deferred behind feature flags as clean hooks: the BET wager (WAR_BET_ENABLED — economy/meta, out of the hash) and war-time Special-Card play (WAR_SPECIAL_ENABLED — a hash-domain change still pending the open mid-war-special question below). The prompt/reveal wording follows the spec mock ("IT'S WAR!" / "I DECLARE WAR!") rather than the older "I. DECLARE. WAR." banner.

## Components affected
- WarEngine war staking + win/edge-case handling
- WAR overlay scene + animation
- Optional Special-Card play during a war

## Design constraints
1. The can-not-complete-a-war loss edge case (a player lacking enough cards to stake the full 3 face-down + 1 face-up) must be resolved deterministically and identically in both the GDScript and TypeScript engines.
2. The WAR overlay reads engine state only; it must never mutate game state.
3. The BET / war wager is an economy-meta concern and must stay OUT of the hashed game state (ADR-6): the engine never sees a wager. The IT'S WAR! modal reserves a flag-gated BET row (WAR_BET_ENABLED=false) so the wager can drop in later without touching the determinism contract.
4. PACING (supersedes the earlier timer-auto-advance pacing answer): the "I DECLARE WAR!" reveal must be PLAYER-GATED — it holds with no auto-timer and advances only on the player's CONTINUE (or a tap-anywhere on the locked beat), so the staked 3-down + 1-up cards stay readable. The Round Director marks WAR_REVEALING via _is_gated_beat and holds it with _hold() (no SceneTreeTimer); request_skip advances it. Presentation-only + determinism-neutral: the engine has already resolved the war and the reveal submits no action (verify_determinism + verify_play_loop stay PASS). Deep wars (war_depth > WAR_AUTO_DEPTH=3) still auto-ack the DECLARE step, but the reveal stays gated. Open follow-up: a game-WINNING war still short-circuits to GAME_OVER without showing its reveal.
5. REVEAL shows ALL staked cards, not just the deciders. The war_decide event carries the full staked cards per side (player_cards / cpu_cards = the 3 face-down spoils + the deciding card, each {rank,suit}) so the UI can flip every card. This is presentation metadata on the (UN-HASHED) EVENTS, mirrored byte-for-byte in engine.gd + engine.ts via _card_summary/cardSummary — the canonical state / JSON / hash is UNCHANGED (verify_determinism + the TS golden vectors stay PASS; no golden regeneration). The reveal flips the cards pair by pair (CPU + YOU per column), the deciding pair last, then a big "YOU WIN THE WAR!" / "CPU WINS THE WAR!" / "WAR AGAIN!" banner; the gated WAR_REVEALING beat holds until CONTINUE, and a tap mid-sequence fast-forwards to the winner. New presentation: WAR_REVEAL_CARD_SIZE + the flip/victory tweens in table.gd; verify_war_moment asserts the built cards, fast-forward, banner, and gating.

## Open questions
1. **Should a player be allowed to play a Special Card mid-war, and if so at which stake step (before the face-up reveal of each war round, or only at the initial tie)?**

## Resolved questions
1. **What is the right WAR overlay animation length to balance dramatic payoff against game pacing, especially across repeated deep wars (high war_depth)?** — _Resolved (presentation pass): the reveal reuses the existing WAR_REVEALING tempo — war_stake 0.45s scaled by the war_depth decay (×0.6 per level, clamped at ×0.30) — with a ~0.16s staggered card pop-in that fits inside that window, and the IT'S WAR! prompt holds for war_banner 1.10s (same decay) before DECLARE WAR. Deep wars (war_depth > WAR_AUTO_DEPTH=3) auto-advance past the prompt so repeated wars don't drag. All of this is presentation-tier TEMPO only (hash-neutral), so future dramatic tuning never touches parity._

## References
_None._

## Child pages
- [Implementation plan — The I-Declare-War Moment](implementation-plan:mqifja8m-00du-ly4mjg)
- [Testing plan — The I-Declare-War Moment](testing-plan:mqifja8m-00dv-sj5yan)
- [Spec — The I-Declare-War Moment](feature-spec:mqifja8m-00dw-a6xnve)

## Commits
_None._
