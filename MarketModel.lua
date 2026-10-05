local addonName, TTB = ...

local MAX_HISTORY_PER_ITEM = 30
local MAX_OPPORTUNITIES = 60
local AH_CUT = 0.05 -- default; configured cut used below
local MIN_BUY_OBSERVATIONS = 3
local BUY_MIN_UNIT_PROFIT = 100      -- 1 silver per unit
local BUY_MIN_DEPTH_PROFIT = 10000   -- or 1 gold across the currently cheap depth

local function clamp(v, lo, hi)
  v = tonumber(v) or 0
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v)
  return math.floor((tonumber(v) or 0) + 0.5)
end

local function safePct(delta, base)
  delta = tonumber(delta) or 0
  base = tonumber(base) or 0
  if base == 0 then return 0 end
  return delta / base
end

local function sortedPrices(levels)
  local prices = {}
  for price in pairs(levels or {}) do
    price = tonumber(price)
    if price and price > 0 then prices[#prices + 1] = price end
  end
  table.sort(prices)
  return prices
end

local function weightedQuantile(levels, totalQuantity, pct, prices)
  totalQuantity = tonumber(totalQuantity) or 0
  if totalQuantity <= 0 then return 0 end
  prices = prices or sortedPrices(levels)
  if #prices == 0 then return 0 end

  local target = math.max(1, totalQuantity * clamp(pct, 0, 1))
  local running = 0
  for _, price in ipairs(prices) do
    running = running + (tonumber(levels[price]) or 0)
    if running >= target then return price end
  end
  return prices[#prices]
end

local function mean(values)
  if not values or #values == 0 then return 0 end
  local total = 0
  for _, v in ipairs(values) do total = total + (tonumber(v) or 0) end
  return total / #values
end

local function median(values)
  if not values or #values == 0 then return 0 end
  local copy = {}
  for i, v in ipairs(values) do copy[i] = tonumber(v) or 0 end
  table.sort(copy)
  local n = #copy
  if n % 2 == 1 then return copy[(n + 1) / 2] end
  return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

local function volatilityFromHistory(history, currentMedian)
  local values = {}
  local startAt = math.max(1, #(history or {}) - 9)
  for i = startAt, #(history or {}) do
    local v = tonumber(history[i].median) or 0
    if v > 0 then values[#values + 1] = v end
  end
  if (tonumber(currentMedian) or 0) > 0 then values[#values + 1] = currentMedian end
  if #values < 2 then return 0 end

  local center = median(values)
  if center <= 0 then return 0 end
  local deviations = {}
  for _, v in ipairs(values) do deviations[#deviations + 1] = math.abs(v - center) / center end
  return clamp(mean(deviations), 0, 2)
end

local function historicalFair(history)
  history = history or {}
  if #history == 0 then return 0, 0 end

  local values = {}
  local startAt = math.max(1, #history - 11)
  for i = startAt, #history do
    local v = tonumber(history[i].depthValue or history[i].median) or 0
    if v > 0 then values[#values + 1] = v end
  end
  if #values == 0 then return 0, 0 end

  local center = median(values)
  if center <= 0 then return 0, #values end

  -- Winsorize history so one strange/manipulated snapshot cannot dominate the model.
  local weightedTotal, weightTotal, age = 0, 0, 0
  for i = #values, 1, -1 do
    local v = clamp(values[i], center * 0.45, center * 2.20)
    local weight = math.pow(0.84, age)
    weightedTotal = weightedTotal + v * weight
    weightTotal = weightTotal + weight
    age = age + 1
  end
  if weightTotal <= 0 then return center, #values end
  return weightedTotal / weightTotal, #values
end

local function getVendorValue(itemID)
  if type(GetItemInfo) ~= "function" then return 0 end
  local ok, _, _, _, _, _, _, _, _, _, _, sellPrice = pcall(GetItemInfo, itemID)
  if ok then return tonumber(sellPrice) or 0 end
  return 0
end

local function confidenceLabel(score)
  if score >= 85 then return "High Confidence" end
  if score >= 70 then return "Established" end
  if score >= 55 then return "Moderate" end
  if score >= 32 then return "Developing" end
  return "New"
end

local function liquidityLabel(score)
  if score >= 75 then return "Very High" end
  if score >= 55 then return "High" end
  if score >= 32 then return "Moderate" end
  if score >= 15 then return "Low" end
  return "Very Low"
end

local function computeActivityProxy(history, currentQty, listings)
  local churn = {}
  local startAt = math.max(2, #(history or {}) - 7)
  for i = startAt, #(history or {}) do
    local a = tonumber(history[i - 1].quantity) or 0
    local b = tonumber(history[i].quantity) or 0
    if a > 0 then churn[#churn + 1] = math.min(1.5, math.abs(b - a) / a) end
  end

  local churnScore = math.min(45, mean(churn) * 100)
  local listingScore = math.min(28, math.log(math.max(1, tonumber(listings) or 0) + 1) * 6.5)
  local quantityScore = math.min(27, math.log(math.max(1, tonumber(currentQty) or 0) + 1) * 3.9)
  return clamp(churnScore + listingScore + quantityScore, 0, 100)
end

local function variantKey(itemID, itemSuffix)
  itemID = tonumber(itemID)
  itemSuffix = tonumber(itemSuffix) or 0
  if not itemID then return nil end
  if itemSuffix ~= 0 then return tostring(itemID) .. ":s" .. tostring(itemSuffix) end
  return itemID -- preserves all existing v0.2.0 unsuffixed history
end

local function buildReasonsAndRisks(market, obs)
  local reasons, risks = {}, {}

  if market.vendorPrice > 0 and obs.floor > 0 and obs.floor < market.vendorPrice then
    reasons[#reasons + 1] = "floor is below vendor value"
  end
  if market.priceAdvantage >= 0.15 then
    reasons[#reasons + 1] = string.format("floor is %.0f%% below modeled fair value", market.priceAdvantage * 100)
  end
  if obs.floor < obs.q10 and obs.floorQuantity <= math.max(2, obs.quantity * 0.03) then
    reasons[#reasons + 1] = "floor is an isolated undercut below the first 10% of supply"
  end
  if obs.cheapQuantity > 0 then
    reasons[#reasons + 1] = string.format("%d units are materially below fair value; modeled depth profit %s", obs.cheapQuantity, TTB:Money(market.estimatedCheapNet))
  end
  if market.itemSuffix and market.itemSuffix ~= 0 then
    reasons[#reasons + 1] = "random-stat suffix is tracked as its own market"
  end

  if market.observations < MIN_BUY_OBSERVATIONS then
    risks[#risks + 1] = string.format("history gate: %d/%d observations; BUY label is locked", market.observations, MIN_BUY_OBSERVATIONS)
  elseif market.observations < 6 then
    risks[#risks + 1] = "history is still developing"
  end
  if obs.listings <= 3 then
    risks[#risks + 1] = "extremely thin market"
  elseif obs.listings <= 6 then
    risks[#risks + 1] = "thin market"
  end
  if obs.cheapQuantity <= 1 and market.priceAdvantage >= 0.25 then
    risks[#risks + 1] = "discount depends on only one cheap unit"
  end
  if obs.spreadRatio >= 8 then
    risks[#risks + 1] = "extreme price spread / strong outlier risk"
  elseif obs.spreadRatio >= 4 then
    risks[#risks + 1] = "wide price distribution / outlier risk"
  end
  if market.volatility >= 0.30 then
    risks[#risks + 1] = "high observed price volatility"
  elseif market.volatility >= 0.15 then
    risks[#risks + 1] = "moderate observed price volatility"
  end
  if obs.quantity >= 2000 then risks[#risks + 1] = "very large current supply" end
  if market.supplyChangePct >= 0.50 then risks[#risks + 1] = "supply recently increased sharply" end
  if market.activityScore < 18 then risks[#risks + 1] = "low market-activity proxy" end
  if market.estimatedNetUnit > 0 and market.estimatedNetUnit < 100 and market.estimatedCheapNet < BUY_MIN_DEPTH_PROFIT then
    risks[#risks + 1] = "very small absolute profit despite attractive percentage spread"
  end
  if market.vendorPrice == 0 then risks[#risks + 1] = "vendor value unavailable/not cached" end

  if #reasons == 0 then reasons[1] = "price/depth model found a relative discount" end
  if #risks == 0 then risks[1] = "snapshot data cannot prove future demand or completed sales" end
  return reasons, risks
end

function TTB:BuildMarketObservation(group, scanID, completedAt)
  local prices = sortedPrices(group.priceLevels)
  local qty = tonumber(group.quantity) or 0
  local floor = math.ceil(group.floorUnitPrice)
  local floorQty = round(group.priceLevels[group.floorUnitPrice] or group.priceLevels[floor] or 0)

  local q10 = round(weightedQuantile(group.priceLevels, qty, 0.10, prices))
  local q25 = round(weightedQuantile(group.priceLevels, qty, 0.25, prices))
  local q50 = round(weightedQuantile(group.priceLevels, qty, 0.50, prices))
  local q75 = round(weightedQuantile(group.priceLevels, qty, 0.75, prices))
  local q90 = round(weightedQuantile(group.priceLevels, qty, 0.90, prices))

  -- Current depth value deliberately ignores the absolute floor and leans on the
  -- lower-middle of the book, making isolated undercuts less able to redefine fair value.
  local depthValue = round((q25 * 0.45) + (q50 * 0.55))
  if depthValue <= 0 then depthValue = q50 > 0 and q50 or floor end

  local cheapThreshold = depthValue * 0.82
  local cheapQuantity, cheapCost = 0, 0
  for _, price in ipairs(prices) do
    if price <= cheapThreshold then
      local levelQty = tonumber(group.priceLevels[price]) or 0
      cheapQuantity = cheapQuantity + levelQty
      cheapCost = cheapCost + levelQty * price
    else
      break
    end
  end

  local spreadRatio = 0
  if q10 > 0 and q90 > 0 then spreadRatio = q90 / q10 end

  return {
    scanID = scanID,
    at = completedAt,
    listings = tonumber(group.listings) or 0,
    quantity = qty,
    floor = floor,
    floorQuantity = floorQty,
    meaningfulFloor = q10,
    tiers = #prices,
    ceiling = round(group.ceilingUnitPrice),
    q10 = q10,
    q25 = q25,
    median = q50,
    q75 = q75,
    q90 = q90,
    depthValue = depthValue,
    cheapQuantity = round(cheapQuantity),
    cheapCost = round(cheapCost),
    spreadRatio = spreadRatio,
  }
end

function TTB:UpdateMarketFromGroup(group, scanID, completedAt)
  self.db.market = self.db.market or {}
  local itemID = tonumber(group.itemID)
  if not itemID then return nil end

  local itemSuffix = tonumber(group.itemSuffix) or 0
  local key = group.marketKey or variantKey(itemID, itemSuffix)
  if key == nil then return nil end

  local market = self.db.market[key]
  if not market then
    market = { itemID = itemID, itemSuffix = itemSuffix, marketKey = key, history = {} }
    self.db.market[key] = market
  end
  market.history = market.history or {}

  local previous = market.history[#market.history]
  if previous and completedAt-(tonumber(previous.at) or 0)<900 then return market end
  local obs = self:BuildMarketObservation(group, scanID, completedAt)

  market.itemID = itemID
  market.itemSuffix = itemSuffix
  market.marketKey = key
  market.name = group.name or market.name or ("Item " .. tostring(itemID))
  market.quality = group.quality or market.quality
  market.level = group.level or market.level
  market.texture = group.texture or market.texture
  market.vendorPrice = getVendorValue(group.itemLink or itemID)
  market.itemLink = group.itemLink or market.itemLink
  market.archived = nil
  market.analysisIncomplete = nil
  market.firstSeen = market.firstSeen or completedAt
  market.lastSeen = completedAt

  local recentHistory = {}
  for _, h in ipairs(market.history) do
    if type(h)=="table" and (tonumber(h.at) or 0)>=completedAt-30*86400 then recentHistory[#recentHistory+1]=h end
  end
  local histFair, histCount = historicalFair(recentHistory)
  local current = obs.depthValue
  local historyWeight
  if histCount <= 0 then historyWeight = 0
  elseif histCount == 1 then historyWeight = 0.18
  elseif histCount == 2 then historyWeight = 0.27
  elseif histCount <= 4 then historyWeight = 0.36
  elseif histCount <= 8 then historyWeight = 0.46
  else historyWeight = 0.55 end

  local fairValue = current
  if histFair > 0 then fairValue = current * (1 - historyWeight) + histFair * historyWeight end
  -- Reviewed seller invoices can inform the model, but cannot dominate depth.
  local saleSum,saleWeight,saleCount=0,0,0
  for _,sale in ipairs(market.bookedSales or {}) do
    if (sale.at or 0)>=completedAt-30*86400 and (sale.quantity or 0)>0 then
      local w=math.min(10,sale.quantity)
      saleSum=saleSum+clamp(sale.price,current*0.6,current*1.5)*w; saleWeight=saleWeight+w; saleCount=saleCount+1
    end
  end
  if saleCount>=3 and saleWeight>0 then fairValue=fairValue*0.85+(saleSum/saleWeight)*0.15 end
  market.recordedSaleSamples=saleCount
  fairValue = round(fairValue)

  local volatility = volatilityFromHistory(market.history, obs.median)
  market.totalObservations = (tonumber(market.totalObservations) or #market.history) + 1
  local observations = #recentHistory + 1
  local sampleScore = math.min(46, observations * 7.5)
  local listingScore = math.min(24, math.log(math.max(1, obs.listings) + 1) * 6)
  local quantityScore = math.min(18, math.log(math.max(1, obs.quantity) + 1) * 2.9)
  local stabilityScore = math.max(0, 12 - volatility * 30)
  local confidenceScore = clamp(sampleScore + listingScore + quantityScore + stabilityScore, 0, 100)

  -- Hard caps stop one busy snapshot from pretending to be well-established history.
  if observations <= 1 then confidenceScore = math.min(confidenceScore, 30)
  elseif observations == 2 then confidenceScore = math.min(confidenceScore, 48)
  elseif observations == 3 then confidenceScore = math.min(confidenceScore, 62) end
  local span = #recentHistory>0 and completedAt-(tonumber(recentHistory[1].at) or completedAt) or 0
  if span<86400 then confidenceScore=math.min(confidenceScore,62)
  elseif span<7*86400 then confidenceScore=math.min(confidenceScore,80) end

  local supplyChange, supplyChangePct, medianMovePct, floorMovePct = 0, 0, 0, 0
  if previous then
    supplyChange = obs.quantity - (tonumber(previous.quantity) or 0)
    supplyChangePct = safePct(supplyChange, previous.quantity)
    medianMovePct = safePct(obs.median - (tonumber(previous.median) or 0), previous.median)
    floorMovePct = safePct(obs.floor - (tonumber(previous.floor) or 0), previous.floor)
  end

  table.insert(market.history, obs)
  while #market.history > MAX_HISTORY_PER_ITEM do table.remove(market.history, 1) end

  local activityScore = computeActivityProxy(market.history, obs.quantity, obs.listings)
  if #market.history < 2 then activityScore = math.min(activityScore, 35)
  elseif #market.history < 3 then activityScore = math.min(activityScore, 50) end

  local priceAdvantage = fairValue > 0 and (fairValue - obs.floor) / fairValue or 0
  local estimatedNetUnit = round(fairValue * (1 - (self.db.settings.ahCut or AH_CUT)) - obs.floor)
  local estimatedNetPct = obs.floor > 0 and estimatedNetUnit / obs.floor or 0
  local estimatedCheapNet = round(math.max(0, (fairValue * (1 - (self.db.settings.ahCut or AH_CUT)) * obs.cheapQuantity) - obs.cheapCost))
  local estimatedCheapROI = obs.cheapCost > 0 and estimatedCheapNet / obs.cheapCost or 0

  market.latest = obs
  market.modelReason=string.format("Current depth = 45%% lower quartile + 55%% median; historical weight %.0f%% (%d recent samples)",historyWeight*100,histCount)
  market.observations = observations
  market.fairValue = fairValue
  market.historicalFair = round(histFair)
  market.historyWeight = historyWeight
  market.freshLaunchWeight = 1 - historyWeight
  market.volatility = volatility
  market.confidenceScore = round(confidenceScore)
  market.confidence = confidenceLabel(confidenceScore)
  market.activityScore = round(activityScore)
  market.activity = liquidityLabel(activityScore)
  market.supplyChange = round(supplyChange)
  market.supplyChangePct = supplyChangePct
  market.medianMovePct = medianMovePct
  market.floorMovePct = floorMovePct
  market.priceAdvantage = priceAdvantage
  market.estimatedNetUnit = estimatedNetUnit
  market.estimatedNetPct = estimatedNetPct
  market.estimatedCheapNet = estimatedCheapNet
  market.estimatedCheapROI = estimatedCheapROI
  market.capitalAtRisk = obs.cheapCost

  local vendorArb = market.vendorPrice > 0 and obs.floor > 0 and obs.floor < market.vendorPrice
  local thinFloor = obs.floor < obs.q10 and obs.floorQuantity <= math.max(2, obs.quantity * 0.03)
  local absoluteProfitGate = estimatedNetUnit >= BUY_MIN_UNIT_PROFIT or estimatedCheapNet >= BUY_MIN_DEPTH_PROFIT

  -- v0.2.1 ranking: percentage discount is only one component. Absolute profit,
  -- available cheap depth, history, and thin-market/outlier risk now matter heavily.
  local advantageScore = clamp(priceAdvantage, 0, 0.80) * 55
  local unitProfitScore = estimatedNetUnit > 0 and math.min(15, math.log(1 + estimatedNetUnit / 100) * 3.3) or -20
  local depthProfitScore = estimatedCheapNet > 0 and math.min(18, math.log(1 + estimatedCheapNet / 100) * 3.5) or 0
  local roiScore = estimatedNetPct > 0 and math.min(8, estimatedNetPct * 3.0) or 0
  local confidenceBoost = confidenceScore * 0.12
  local activityBoost = activityScore * 0.07
  local vendorBoost = vendorArb and 18 or 0
  local volatilityPenalty = volatility * 38
  local supplyPenalty = supplyChangePct > 0 and math.min(10, supplyChangePct * 8) or 0
  local historyPenalty = observations <= 1 and 18 or (observations == 2 and 8 or 0)
  local thinMarketPenalty = 0
  if obs.listings <= 3 then thinMarketPenalty = thinMarketPenalty + 18
  elseif obs.listings <= 5 then thinMarketPenalty = thinMarketPenalty + 10
  elseif obs.listings <= 8 then thinMarketPenalty = thinMarketPenalty + 5 end
  if obs.cheapQuantity <= 1 and priceAdvantage >= 0.25 then thinMarketPenalty = thinMarketPenalty + 6 end
  if obs.spreadRatio >= 8 then thinMarketPenalty = thinMarketPenalty + 14
  elseif obs.spreadRatio >= 4 then thinMarketPenalty = thinMarketPenalty + 8 end
  if priceAdvantage >= 0.80 and observations < MIN_BUY_OBSERVATIONS then thinMarketPenalty = thinMarketPenalty + 12 end

  local pennyPenalty = 0
  if estimatedNetUnit > 0 and estimatedNetUnit < 25 then pennyPenalty = 10
  elseif estimatedNetUnit > 0 and estimatedNetUnit < 100 then pennyPenalty = 6 end
  if estimatedCheapNet >= BUY_MIN_DEPTH_PROFIT then pennyPenalty = pennyPenalty * 0.35 end

  local score = clamp(advantageScore + unitProfitScore + depthProfitScore + roiScore + confidenceBoost + activityBoost + vendorBoost
    - volatilityPenalty - supplyPenalty - historyPenalty - thinMarketPenalty - pennyPenalty, 0, 100)

  market.opportunityScore = round(score)
  market.vendorArbitrage = vendorArb
  market.thinFloor = thinFloor
  market.absoluteProfitGate = absoluteProfitGate
  market.minBuyObservations = MIN_BUY_OBSERVATIONS

  local basicOpportunity = (priceAdvantage >= 0.12 and estimatedNetUnit > 0) or vendorArb
  if not basicOpportunity then
    market.signal = "PASS"
  elseif observations < MIN_BUY_OBSERVATIONS then
    market.signal = vendorArb and "WATCH - VENDOR" or "WATCH - UNPROVEN"
  elseif vendorArb and score >= 45 then
    market.signal = "BUY CANDIDATE"
  elseif priceAdvantage >= 0.22 and estimatedNetUnit > 0 and absoluteProfitGate and confidenceScore >= 42 and score >= 52 then
    market.signal = "BUY CANDIDATE"
  else
    market.signal = "WATCH"
  end

  market.reasons, market.risks = buildReasonsAndRisks(market, obs)
  return market
end

