TALIAA TRADE - FOREVER MARKET PROTOTYPE
Version 0.2.1-beta

PURPOSE
This is the scoring-hardening update for the confirmed Forever Beta Auction House API foundation.
It remains a read-only market scanner/model. It is designed to be fully testable on a Beta character with ZERO GOLD.

ZERO-GOLD SAFE MODE
This build does not buy, bid, post, or cancel auctions.
StartCommoditiesPurchase, ConfirmCommoditiesPurchase, PlaceBid, PostCommodity, PostItem, and CancelAuction are NEVER called.
Those API names only appear in the diagnostic presence probe so we know what the client exposes.
Every feature in this build can be tested using full scans, saved database history, targeted LIVE QUERY results, and reports.

NEW IN 0.2.1-beta
- BUY CANDIDATE is locked until an exact market has at least 3 observations
- 1-2 observation opportunities are labeled WATCH - UNPROVEN (or WATCH - VENDOR)
- One busy snapshot can no longer produce Moderate/High confidence by itself
- Opportunity scoring now gives much more weight to absolute profit, not just percentage discount
- Adds modeled cheap-depth net profit and cheap-depth ROI
- Adds an absolute-profit gate before a normal market can become BUY CANDIDATE
- Strong penny-profit penalties unless enough cheap depth creates meaningful total profit
- Stronger penalties for 1-5 listing markets, one-unit discounts, huge price spreads, and extreme first-scan discounts
- Random-stat item suffixes are separated into their own market histories instead of contaminating the base item fair value
- Existing v0.2.0 unsuffixed history is preserved in place
- Scan diagnostics now report base item count and detected suffix-variant market count
- Top 20/report/detail views now show cheap-depth capital/profit and suffix information

MODEL RULES ADDED IN 0.2.1
BUY history gate: 3 observations minimum.
Normal BUY absolute-profit gate: at least 1 silver modeled net per unit OR at least 1 gold modeled net across current cheap depth.
These are conservative Beta-test defaults and can be tuned after we collect several scans.

IMPORTANT MODEL LIMITATION
Replicate snapshots show listings/supply, not completed sales.
A supply decrease could be a sale, cancellation, or expiration. Taliaa Trade therefore calls this an activity/liquidity proxy and never treats it as a true sell-through rate.

RANDOM-SUFFIX HANDLING
Forever's modern item hyperlink format exposes the random-stat suffix in the replicated item link.
v0.2.1 separates suffixed gear into market keys such as itemID:suffix rather than pooling all suffixes under one item ID.
The old v0.2.0 numeric item-ID market remains intact, so no SavedVariables wipe is required.

NEXT TEST
1. Replace the old TaliaaTradeBeta addon folder with this version. DO NOT delete SavedVariables.
2. /reload or log back in.
3. Open /ttb. Existing scan #1/history should still be present.
4. The old opportunities may remain displayed until the next full scan rebuilds them with the v0.2.1 model.
5. When the 15-minute full-scan timer permits it, click REQUEST FRESH SCAN.
6. COPY REPORT and send it back.

WHAT WE EXPECT AFTER THE NEXT SCAN
- Most markets carried forward from v0.2.0 should have observation #2.
- No normal market should show BUY CANDIDATE yet because the gate is 3 observations.
- Existing random-suffix gear may start new isolated histories at observation #1 because v0.2.0 mixed those variants together.
- Cheap penny items should rank lower unless the available cheap depth produces meaningful absolute profit.
- Very thin 1-unit / 1-5 listing anomalies should be penalized much harder.

VIEWS
TOP 20       Highest current WATCH/BUY model candidates.
MARKET DB    Persistent database statistics and the most-observed/largest markets.
DIAGNOSTICS  API probe, scan state, latest live query, and recent log.
DETAIL       Full model/history for an Item ID; if multiple suffix variants exist, the most recent is shown.
LIVE QUERY   Normal Blizzard SendSearchQuery comparison. It never purchases anything.

SLASH COMMANDS
/ttb             Toggle window
/ttb scan        Request a fresh ReplicateItems snapshot
/ttb cached      Analyze Blizzard's current temporary replicate cache
/ttb top         Show Top 20
/ttb db          Show Market DB
/ttb diag        Show Diagnostics
/ttb item 12345  Show saved detail for item ID 12345
/ttb probe       Refresh API probe
/ttb report      Open copyable test report

SAVED VARIABLES
WTF/Account/<ACCOUNT>/SavedVariables/TaliaaTradeBeta.lua
Schema upgrades from v0.2.0 in place. Do not delete the file if you want to preserve scan #1.
