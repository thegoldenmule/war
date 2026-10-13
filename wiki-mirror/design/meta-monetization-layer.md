# Meta & Monetization Layer

**Status:** active

## Body
# Meta & Monetization Layer

This document is a planning skeleton for the live-ops and meta layer that wraps the core _War_ game loop. The match itself stays small and deterministic; the meta layer is where retention, progression, and monetization live. The hook we are selling against is **the flip moment** — cards are dealt face-down, so before each reveal the player may spend a collectible Special Card. Special Cards are therefore both the headline collectible and the primary thing players spend currency to acquire. Everything below is provisional and intended to be refined; see Open questions at the end for the decisions still outstanding.

## Currencies (Gems)

**Gems** are the single soft currency for v1. We deliberately avoid a second hard/premium currency at launch to keep the economy legible; IAP grants Gems directly rather than a parallel token. Gems are earned through play (round wins, match wins, daily login, challenges, level-ups, events) and spent on the collection and shop.

Primary Gem sinks and sources are summarized below. Exact numbers are placeholders pending an economy spreadsheet.

| **Flow** | **Source / Sink** | **Notes** |
| :--- | :--- | :--- |
| Source | Match win | Small per-win drip; scales lightly with margin of victory. |
| Source | Daily login + streak | Largest predictable daily faucet (see Daily login). |
| Source | Daily challenges | Bonus on top of the login bonus; rotating. |
| Source | XP level-up | One-time grant per level milestone. |
| Source | IAP / bundles | Hard-currency purchase converted to Gems. |
| Sink | Special-Card pulls | Primary sink — gacha unlocks. |
| Sink | Shop bundles | Direct purchase of specific cards / cosmetics. |
| Sink | Continues / retries | Open question — see below. |

## Special-Card Collection (gacha-style unlocks)

Special Cards are the collectible power-ups played during the flip moment. The collection is the heart of the meta layer: it is the long-tail goal, the gacha surface, and the thing that differentiates one player's deck of options from another's. Cards are grouped by rarity (e.g. Common / Rare / Epic / Legendary) with drop weights tuned per pool.

Acquisition is gacha-style: players spend Gems on a pull from a pool and receive a card weighted by rarity. Duplicates should convert into something useful (shards toward upgrades, or a small Gem refund) so pulls never feel wholly wasted. A pity / guarantee mechanic on a featured pool is desirable to cap bad luck.

Core collection mechanics to design:

- **Rarity tiers** — fixed set with published-ish drop rates; legendary reserved for marquee effects.
- **Pools** — a standard pool plus rotating featured pools tied to events / battlepass.
- **Pity / guarantee** — guaranteed rare-or-better every N pulls; soft pity on featured.
- **Duplicates** — convert to shards or Gems; possible card-level upgrades.
- **Collection book** — browsable gallery with completion rewards per set.

## Shop + IAP

The shop is the storefront for both Gem purchases (IAP) and Gem-priced bundles. It hosts a small, curated set of offers rather than an endless catalog. The headline real-money products at launch are a one-time starter pack, rotating value bundles, and a permanent ad-removal purchase.

- **Starter pack** — one-time, deeply-valued first purchase: Gems + a guaranteed Special Card. The classic new-payer conversion offer.
- **Gem bundles** — tiered IAP ($0.99 → $99.99) granting Gems, with the usual better-value-at-higher-tiers curve.
- **Themed bundles** — rotating, often event-tied; a fixed set of cards / cosmetics + Gems at a discount vs. buying separately.
- **Ad removal** — one-time purchase that removes interstitial / banner ads (rewarded ads, if any, stay opt-in). See ad-gating open question.

## Daily Login Bonus + Weekly Streak

A 7-day login calendar grants escalating rewards (Gems, pulls, occasionally a guaranteed card on day 7). The streak is the cheapest, highest-leverage retention tool we have. A break in the streak resets to day 1; we may offer a one-tap streak-restore (ad or small Gem cost) as a forgiveness mechanic.

Open design point: whether the weekly cycle is a fixed calendar (everyone on the same day index) or a personal rolling streak. This interacts with the universal-vs-per-user reset question below.

## Daily Challenges

A small rotating set of daily challenges (target 3 active per day) gives players a reason to come back and a structured Gem faucet. One slot is always the same anchor challenge so there is a guaranteed, friction-free completion every day.

- **“Play 3”** — _always present_. Play 3 matches today. The dependable daily anchor.
- **Win N matches** — rotating; difficulty scales with the player's recent win rate.
- **Win a WAR** — trigger and win a tie-break WAR this session.
- **Play a Special Card** — use any collectible during a flip moment (funnels toward the core hook).
- **Rank-specific goals** — e.g. win a round with a face card; rotating flavor.

## Leaderboards

Leaderboards give competitive players a reason to keep playing past collection completion. Because the game is single-player vs CPU, ranking is on derived metrics rather than head-to-head results: e.g. longest win streak, fastest 52-card sweep, most WARs won, or a weekly points ladder. The authoritative validator is the source of truth for any score that gates a reward, preventing client-side tampering. Boards reset on a cadence (weekly / seasonal) with reward tiers at the top.

## Seasonal Events / Battlepass

Seasons (roughly monthly) frame the live-ops calendar. Each season ships a themed featured card pool, themed daily challenges, and a battlepass: a dual-track (free + premium) reward ladder advanced by earning season XP through play and challenges. The premium track is a recurring monetization surface and the main vehicle for seasonal exclusive Special Cards and cosmetics. Limited-time events (weekend modifiers, double-Gem windows) layer on top of the season for spikes in engagement.

## XP & Levels

A persistent account level, advanced by XP earned from matches, challenges, and events, provides the always-on progression spine independent of any single season. Level-ups grant Gems and may gate features or unlock pools. Season XP (battlepass) is tracked separately from account XP so that seasonal resets do not erase long-term account progress.

## Open Questions

Decisions still outstanding before this skeleton becomes a spec:

- **Lives / energy?** Do we gate session length with a lives or energy system, or keep play unlimited? Unlimited is friendlier to the hypercasual feel but removes a monetization lever.
- **Ad gating between sessions?** Do we show an interstitial between matches, and at what frequency? How does this interact with the ad-removal IAP and any rewarded-ad faucets?
- **Universal vs. per-user daily reset?** Does the daily clock tick at a fixed UTC hour for everyone, or roll per-user from first login? Affects login streak, challenges, and leaderboards.
- **What do Gems unlock?** Confirm the full Gem sink list: pulls only, or also continues/retries, streak restores, challenge re-rolls, and battlepass tiers?
- **Single vs. dual currency?** Stay single-currency (Gems), or split into earned-soft + bought-hard? Single is simpler; dual is the genre norm and protects perceived IAP value.
- **Duplicate handling** Shards-to-upgrade vs. flat Gem refund vs. both — which best supports long-tail collection without trivializing pulls?

## References
_None._

## Child pages
_None._
