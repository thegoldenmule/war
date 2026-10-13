# Round Director

**Status:** current

## Kind
component

## Summary
**Round Director** (`game/ui/round_director.gd`, class `WarRoundDirector`) is the presentation-tier *play sequencer* that turns the rules engine's discrete legal phase transitions into a paced, animated single-player loop. It owns a `WarMatch`, auto-advances the mechanical actions the player should never tap — `start_round` to stage a round, `resolve` to award one — on short timed *beats*, and pauses for the player only at the two decision points: the *flip moment* and the *WAR ack*. It holds no authoritative state: only a cosmetic *beat* derived from the engine phase, a single armed timer, and the last state snapshot it handed the view. **Status: designed in the Core Play Loop feature; not yet implemented** — today the table drives WarMatch directly and has a known wiring bug (it calls a non-existent start_new_game and maps phase 'dealt' straight to flip).

## Purpose
It exists to keep the hard wall sharp while still giving War a dramatic, hypercasual feel. Without it, pacing logic would either leak into the pure `WarMatch` funnel or bloat the table view; the Director isolates *which legal action, and when* into one node so `table.gd` stays a pure renderer and `WarMatch` stays a pure funnel. Because the Director only schedules legal `WarActions` and never invents state, the action stream the validator re-runs stays byte-clean and the optimistic-then-reconcile model is untouched. And because War gives the opponent no choices — both top cards are forced — the single deterministic engine plays both sides, so the Director needs no CPU AI, only timing.

## Design notes
Beat vs phase. The engine phase (dealt, selected, flipped, war, player_win, cpu_win) is the source of truth; the Director's beat is pacing layered on top. On every state_changed and reconciled the Director cancels its pending timer, recomputes the resting beat from the phase, sets an input-locked flag, and re-renders through one entry point. This is why reconcile is free: a mid-animation snap can never double-apply an action or strand a phantom beat — the worst case is a skipped animation, after which the loop sits exactly where the authoritative state says.

Auto-advance policy. Exactly two actions are auto-submitted on beats: start_round when the loop rests at phase dealt (STAGING), and resolve after the reveal animation at phase flipped (REVEALING). Both are deterministic and phase-legal, so the validator re-runs them identically. Everything else — flip, play_special, ack_war — is a player intent forwarded only when it matches the awaited beat.

Two decision points. The Director waits for the player only at FLIP_MOMENT (phase selected: request_flip, or request_special then flip) and WAR_PROMPT (phase war: request_declare_war). A single primary button suffices because the engine treats a resolve submitted in phase war exactly like ack_war.

War loop and forfeit. A tie routes the engine to phase war; the Director plays the WAR_BANNER overlay, settles into WAR_PROMPT, and on declare-war submits ack_war. A repeated tie loops the war beats at the incremented war_depth; the can-not-complete-a-war forfeit is resolved entirely by the engine (it emits war_forfeit then game_over), so the Director simply routes to GAME_OVER with no special handling.

Headless caveat. The Director is presentation only and must never be required for deterministic play: the same loop is drivable through the WarDebug autoload (start_round / flip / resolve / ack_war) for the headless verifiers and LLM driving. Determinism parity is asserted by the logic verifiers, not by the Director.

```gdscript
# Pure mapping: the RESTING beat implied by an engine phase. Transient beats
# (REVEALING tail, ROUND_RESULT, WAR_BANNER, WAR_REVEALING) are layered by timers,
# but the Director can always fall back to this from authoritative state.
static func beat_for_phase(phase: String) -> Beat:
    match phase:
        "dealt":                 return Beat.STAGING      # auto: start_round
        "selected":              return Beat.FLIP_MOMENT  # await: flip / special
        "flipped":               return Beat.REVEALING    # auto: reveal -> resolve
        "war":                   return Beat.WAR_PROMPT    # await: declare war
        "player_win", "cpu_win": return Beat.GAME_OVER
        _:                       return Beat.BOOT
```

## Components
_No components._

## Dependencies
- **owns** → [Match Controller](architecture:mqiffgkq-00c5-u32a7j) — creates and drives the WarMatch funnel; submits only legal WarActions, reads state via signals
- **depends-on** → [Rules Engine](architecture:mqiff9ri-00c1-bz5lp5) — mirrors the engine phase vocabulary and builds canonical WarActions (start_round/flip/resolve/ack_war/play_special)
- **exposes** → [Presentation & VFX](architecture:mqiffsj2-00cb-jel2kh) — emits view_state(state) and beat(name, events, locked) consumed by the table view; receives player intents back

## Code references
- class `WarRoundDirector` in `game/ui/round_director.gd`
- `game/ui/screens/table.gd`
- class `WarMatch` in `game/game/match_controller.gd`

## Data model
The Director stores a cosmetic `Beat` enum value (BOOT, STAGING, FLIP_MOMENT, REVEALING, ROUND_RESULT, WAR_BANNER, WAR_PROMPT, WAR_REVEALING, GAME_OVER), a single `SceneTreeTimer` it arms for the current beat, and a deep-copied snapshot of the last state handed to the view. The resting beat is the pure function `beat_for_phase(state.phase)`; transient beats (reveal, result hold, war banner, stake reveal) are layered on by timers. No deck, no card, no hash — every truth comes from the `WarMatch` state dictionary it renders and forwards as `view_state(state)`.

## Usage
_None._

## Invariants & constraints
- Pure presentation: reads only state/events and submits only canonical WarActions through the single WarMatch funnel; never re-implements rules or mutates hashed state.
- The beat is a pure function of engine phase (beat_for_phase); the Director can always reconstruct the loop from authoritative state, which is what makes reconcile snaps safe (cancel timers, re-derive, re-render).
- Only deterministic, phase-legal actions are auto-submitted (start_round, resolve); player-chosen actions (flip, play_special, ack_war) are forwarded only when they match the awaited beat.
- Holds no authoritative state — no deck, card, or hash — only a beat, one armed timer, and a render snapshot; every visible truth comes from the WarMatch state dictionary.
- Never required for deterministic play: the loop remains fully drivable headlessly via WarDebug, and determinism parity is asserted by the logic verifiers, not the Director.

## Synced commit
_None._
