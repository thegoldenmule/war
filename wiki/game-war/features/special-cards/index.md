# Feature: Special Cards

**Status:** draft

## Summary
Special Cards are collectible, Balatro-style power-ups the player can deploy around the flip moment — the core agency and monetization hook of the game. Because cards are dealt face-down, the player has a window before the reveal to play a Special Card and tilt the round in their favor. Their effects resolve entirely inside the deterministic rules engine and are validator-authoritative, so an optimistic client play is reconciled against the server. The feature spans the WarSpecialCards engine resolver, a server-sourced card catalog with a baked client copy, an in-game "Play Special" modal, and the player's collection/inventory backed by Snapser.

## Components affected
- WarSpecialCards engine resolver
- Card catalog (validator/content/card_catalog.json + baked client copy)
- In-game "Play Special" modal
- Collection/inventory (Snapser)

## Design constraints
1. Effects must be deterministic and hash-parity-safe across the GDScript and TypeScript engines.
2. The catalog is server-sourced via Remote Config with per-match version pinning.

## Open questions
1. **Are Special Cards one-use per match, or persistent across rounds within a match?**
2. **Is timing pre-flip vs post-flip determined per card, and how is that encoded in the catalog?**
3. **How are Special Cards acquired — gacha, shop, rewards, or some combination?**

## Resolved questions
_None._

## References
_None._

## Child pages
- [Implementation plan — Special Cards](implementation-plan:mqifiji7-00dm-blq0rx)
- [Testing plan — Special Cards](testing-plan:mqifiji7-00dn-1hibfv)
- [Spec — Special Cards](feature-spec:mqifiji7-00do-xdxep4)

## Commits
_None._
