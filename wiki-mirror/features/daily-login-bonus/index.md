# Daily Login Bonus

**Status:** draft

## Summary
A daily login reward that grants escalating rewards across a login streak, with an additional bonus for completing a full week, to drive day-over-day retention. Each claim awards Gems and/or Special Cards, with the reward scaling by the player's current streak day. All grants are issued server-authoritatively by a Snapser-backed claim endpoint; the client surfaces a claim modal and applies the resulting currency/collection update to GameState. The streak advances on consecutive eligible days and resets when a login day is missed.

## Components affected
- Snapser-backed claim endpoint + day-boundary logic
- Client claim modal
- GameState currency update

## Design constraints
1. Grants are server-authoritative: the client never mints Gems or cards; the claim endpoint is the sole source of rewards.
2. The day boundary must be tamper-resistant (resistant to device-clock manipulation).

## Open questions
1. **Day-boundary policy: universal UTC reset vs per-user local-midnight reset?**
2. **Is there a streak-break grace period (e.g. a short window after a missed day before the streak resets), or does any missed day reset immediately?**
3. **What is the reward table (per-day Gem/card grants across the streak, and the weekly streak bonus)?**

## Resolved questions
_None._

## References
_None._

## Child pages
- [Implementation plan — Daily Login Bonus](implementation-plan:mqifjdky-00e2-xy1uqh)
- [Testing plan — Daily Login Bonus](testing-plan:mqifjdky-00e3-30vtb9)
- [Spec — Daily Login Bonus](feature-spec:mqifjdky-00e4-v8dzb3)

## Commits
_None._
