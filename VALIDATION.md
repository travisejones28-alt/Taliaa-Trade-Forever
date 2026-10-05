# Final audit — 1.0.0-beta

**37 automated checks passed.** Full output is in `Tests/test-results.txt`.

The tests execute all 13 TOC Lua modules with a mock WoW API and create/render
every terminal tab through mock frames. They are runtime logic tests, not visual
screenshots or validation of the actual Forever server.

| Area | Evidence |
|---|---|
| Compatibility and integration | TOC load order; all modules loaded; capability probe; repeat search refresh; result-key matching; full-results requirement; pagination; request priority/dedupe; missing-response retry limit |
| Market model | Isolated low-price bait; meaningful floor; independent observations; elapsed-history confidence cap; bounded history; vendor return index; suffix identity; stale cached data; reviewed sale input |
| Transaction safety | Safe Mode; fresh validation; current risk gates; one whole auction per click; separate commodity confirmation click; higher/expired/stale quote rejection; price changes; own auctions; bogus quantity clamp; aborted-quote guard |
| Ledger/data | Idempotent legacy import; future-schema preservation; inventory moving average; unknown basis exclusion; invoice repeat suppression; winning bid versus buyout; invoice payout consistency; unknown reservations; reload alias repair; duplicate/late success |
| Performance | 50,000-row fixture with 1,500 markets and one malformed row processed across roughly 600 scheduled job ticks; bounded scan/model batches; tier/result caps; cached exposure index |
| UI/lifecycle | Native frame construction; all tabs; diagnostics copy window; AH closure cancels processing publication and preserves uncertain transaction reservation |

The frame-budget clock is synthetic. The harness does not measure WoW FPS,
network latency, real throttle behavior, actual protected-call authorization,
SavedVariables disk loading or visual layout. Those require the live test in
README.md. API presence is probed rather than assumed.

Audit fixes included: vendor-value return indexing; safe iteration of jobs that
complete and enqueue work; retaining late purchase correlation across AH closure;
preventing cached reanalysis from manufacturing confidence; capping bogus regular
auction quantities; excluding own supply; preserving unresolved-order identity
through reload; pagination deadlines and complete-result gating; quote cooldowns;
winning-bid accounting and blocking inconsistent invoice payouts.

Reference lessons incorporated:

- ForeverForge: refresh previously searched items instead of trusting cached rows;
  throttle queues; commodities have separate request/quote/result flows; correct
  per-auction quantity matters; own supply must not become a buy recommendation.
- AHledger: compact historical observations and localized system-mail subjects;
  observed mailbox data differs from inferred market disappearance; Forever
  persistence needs a live reload test. No CVar persistence workaround was adopted.

Primary-client source checked for the commodity buy flow:
https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseCommoditiesBuyFrame.lua

This source describes Blizzard's UI, not proof of the Forever beta implementation.
The supplied working prototype and Forever reference addons guide compatibility.
