local addonName, TTB = ...

TTB.scanState = { running = false, phase = "idle", status = "No scan started", progress = 0, source = nil }

local function currentMS()
  if debugprofilestop then return debugprofilestop() end
  return 0
end

local function makeItemKey(itemID)
  if C_AuctionHouse and type(C_AuctionHouse.MakeItemKey) == "function" then
    local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
    if ok and type(key) == "table" then return key end
  end
  return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function priceSorts()
  if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price ~= nil then
    return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  end
  return {}
end


local function parseItemSuffixFromLink(link)
  if type(link) ~= "string" or link == "" then return 0 end
  local itemString = string.match(link, "|Hitem:([^|]+)|h") or string.match(link, "^item:(.+)$")
  if not itemString then return 0 end

  -- Modern hyperlink field layout begins:
  -- itemID:enchant:gem1:gem2:gem3:gem4:suffixID:uniqueID:...
  -- Forever exposes modern AH APIs, so field 7 cleanly isolates random-stat suffixes.
  local fields = {}
  local startAt = 1
  for i = 1, 7 do
    local pos = string.find(itemString, ":", startAt, true)
    if pos then
      fields[i] = string.sub(itemString, startAt, pos - 1)
      startAt = pos + 1
    else
      fields[i] = string.sub(itemString, startAt)
      break
    end
  end
  return tonumber(fields[7]) or 0
end

local function getReplicateVariant(i, itemID)
  local suffix = 0
  local link = nil
  if type(C_AuctionHouse.GetReplicateItemLink) == "function" then
    local ok, value = pcall(C_AuctionHouse.GetReplicateItemLink, i)
    if ok and type(value) == "string" then
      link = value
      suffix = parseItemSuffixFromLink(value)
    end
  end
  local key = itemID
  if suffix ~= 0 then key = tostring(itemID) .. ":s" .. tostring(suffix) end
  return key, suffix, link
end

function TTB:SetScanStatus(status, progress)
  self.scanState.status = status or self.scanState.status
  if progress ~= nil then self.scanState.progress = math.max(0, math.min(1, tonumber(progress) or 0)) end
  if self.RefreshUI then self:RefreshUI() end
end

function TTB:CanUseAuctionHouse()
  return self.ahOpen and type(C_AuctionHouse) == "table"
end

function TTB:RequestFreshScan()
  if self.scanState.running then self:Print("A scan is already running."); return end
  if not self:CanUseAuctionHouse() then self:Print("Open the Auction House first."); return end
  if type(C_AuctionHouse.ReplicateItems) ~= "function" then
    self:Log("SCAN", "ReplicateItems is not exposed by this client")
    self:Print("This client does not expose C_AuctionHouse.ReplicateItems.")
    return
  end

  local remain = self:GetSecondsUntilFreshScanAllowed()
  if remain > 0 then
    self:Print("Local safety timer: fresh full scan available in " .. self:FormatDuration(remain) .. ". Your saved market database is still available.")
    return
  end

  self.scanState.running = true
  self.scanState.phase = "waiting"
  self.scanState.source = "fresh replicate request"
  self.scanState.progress = 0.02
  self.scanState.requestedAt = time()
  self.db.lastFreshScanRequestAt = time()
  self:SetScanStatus("Fresh snapshot requested; waiting for Blizzard", 0.02)

  local ok, err = pcall(C_AuctionHouse.ReplicateItems)
  if not ok then
    self.db.lastFreshScanRequestAt = 0
    self.scanState.running = false
    self.scanState.phase = "error"
    self:SetScanStatus("ReplicateItems failed: " .. tostring(err), 0)
    self:Log("SCAN ERROR", "ReplicateItems: " .. tostring(err))
    return
  end

  self:Log("SCAN", "Called C_AuctionHouse.ReplicateItems()")
  C_Timer.After(12, function()
    if TTB.scanState.running and TTB.scanState.phase == "waiting" then
      TTB.scanState.running = false
      TTB.scanState.phase = "timeout"
      TTB:SetScanStatus("No replicate update received. Possible account-wide throttle. Saved database remains usable.", 0)
      TTB:Log("SCAN", "Fresh snapshot timed out waiting for REPLICATE_ITEM_LIST_UPDATE")
    end
  end)
end

function TTB:AnalyzeCachedSnapshot()
  if self.scanState.running then self:Print("A scan is already running."); return end
  if not self:CanUseAuctionHouse() then self:Print("Open the Auction House first."); return end
  if type(C_AuctionHouse.GetNumReplicateItems) ~= "function" or type(C_AuctionHouse.GetReplicateItemInfo) ~= "function" then
    self:Print("Cached replicate APIs are unavailable on this client."); return
  end
  local ok, total = pcall(C_AuctionHouse.GetNumReplicateItems)
  total = ok and tonumber(total) or 0
  if not total or total <= 0 then
    self:Print("Blizzard's temporary replicate cache is empty. Your Taliaa Trade market database is still intact.")
    self:Log("SCAN", "Analyze Cached requested but cache count was zero")
    return
  end
  self:StartSnapshotProcessing(total, "cached snapshot")
end

function TTB:StartSnapshotProcessing(total, source)
  if self.scanState.running and self.scanState.phase == "processing" then return end

  self.scanState.running = true
  self.scanState.phase = "processing"
  self.scanState.source = source
  self.scanState.progress = 0.05
  self.scanState.total = total
  self.scanState.processed = 0
  self.scanState.startedMS = currentMS()
  self.scanState.startedAt = time()

  local grouped = {}
  local baseItemsSeen = {}
  local index, validRows, totalQuantity, invalidRecords, incompleteRecords = 0, 0, 0, 0, 0
  local variantRows, variantMarkets = 0, 0
  local chunkSize = 140
  self:SetScanStatus("Processing " .. tostring(total) .. " auction rows into market database", 0.05)

  local function addRow(i)
    local ok, name, texture, count, quality, canUse, level, levelType, minBid, minIncrement, buyoutPrice,
      bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo =
      pcall(C_AuctionHouse.GetReplicateItemInfo, i)

    if not ok then invalidRecords = invalidRecords + 1; return end
    itemID = tonumber(itemID)
    count = math.max(1, tonumber(count) or 1)
    buyoutPrice = tonumber(buyoutPrice) or 0
    saleStatus = tonumber(saleStatus) or 0
    if not hasAllInfo then incompleteRecords = incompleteRecords + 1 end
    if not itemID or itemID <= 0 or buyoutPrice <= 0 or saleStatus ~= 0 then invalidRecords = invalidRecords + 1; return end

    local unitPrice = buyoutPrice / count
    if unitPrice <= 0 then invalidRecords = invalidRecords + 1; return end

    validRows = validRows + 1
    totalQuantity = totalQuantity + count
    baseItemsSeen[itemID] = true

    -- Random-stat gear must not share a price model with every other suffix of the
    -- same base item. Unsuffixed items retain the numeric itemID key so all v0.2.0
    -- history is preserved. Suffixed variants get an isolated market key.
    local marketKey, itemSuffix = getReplicateVariant(i, itemID)
    if itemSuffix ~= 0 then variantRows = variantRows + 1 end
    local g = grouped[marketKey]
    if not g then
      g = {
        marketKey = marketKey, itemID = itemID, itemSuffix = itemSuffix, name = name, texture = texture, quality = quality, level = level,
        listings = 0, quantity = 0, floorUnitPrice = unitPrice, ceilingUnitPrice = unitPrice, priceLevels = {},
      }
      grouped[marketKey] = g
      if itemSuffix ~= 0 then variantMarkets = variantMarkets + 1 end
    end
    if (not g.name or g.name == "") and name and name ~= "" then g.name = name end
    g.listings = g.listings + 1
    g.quantity = g.quantity + count
    if unitPrice < g.floorUnitPrice then g.floorUnitPrice = unitPrice end
    if unitPrice > g.ceilingUnitPrice then g.ceilingUnitPrice = unitPrice end
    g.priceLevels[unitPrice] = (g.priceLevels[unitPrice] or 0) + count
  end

  local function finish()
    local items = {}
    for _, g in pairs(grouped) do items[#items + 1] = g end
    table.sort(items, function(a, b)
      if a.listings == b.listings then return a.quantity > b.quantity end
      return a.listings > b.listings
    end)

    local baseItemCount = 0
    for _ in pairs(baseItemsSeen) do baseItemCount = baseItemCount + 1 end

    local elapsed = currentMS() - (TTB.scanState.startedMS or currentMS())
    local summary = {
      source = source, startedAt = TTB.scanState.startedAt, completedAt = time(), rawRows = total,
      auctionsProcessed = validRows, uniqueItems = #items, uniqueBaseItems = baseItemCount, variantMarkets = variantMarkets, variantRows = variantRows,
      totalQuantity = totalQuantity, invalidRecords = invalidRecords, incompleteRecords = incompleteRecords,
      processingMS = math.floor(elapsed + 0.5), topItems = {},
    }

    for i = 1, math.min(30, #items) do
      local g = items[i]
      summary.topItems[i] = {
        itemID = g.itemID, itemSuffix = g.itemSuffix or 0, marketKey = g.marketKey, name = g.name, quantity = g.quantity, listings = g.listings,
        floorUnitPrice = math.floor(g.floorUnitPrice + 0.5), ceilingUnitPrice = math.floor(g.ceilingUnitPrice + 0.5),
      }
    end

    if TTB.FinalizeMarketScan then
      local ok, modelResult = pcall(TTB.FinalizeMarketScan, TTB, grouped, summary)
      if ok and modelResult then
        summary.marketScanID = modelResult.scanID
        summary.marketOpportunities = #(modelResult.opportunities or {})
      else
        TTB:Log("MODEL ERROR", tostring(modelResult))
      end
    end

    TTB.db.latestScan = summary
    table.insert(TTB.db.scans, summary)
    while #TTB.db.scans > 20 do table.remove(TTB.db.scans, 1) end

    TTB.scanState.running = false
    TTB.scanState.phase = "done"
    TTB.scanState.progress = 1
    TTB.scanState.processed = total
    local top = TTB.db.opportunities and TTB.db.opportunities[1]
    TTB.suggestedTestItemID = top and top.itemID or (summary.topItems[1] and summary.topItems[1].itemID or nil)
    TTB:SetScanStatus(string.format("Complete: %d auctions -> %d markets (%d base items, %d suffix variants) -> %d candidates",
      validRows, #items, baseItemCount, variantMarkets, summary.marketOpportunities or 0), 1)
    TTB:Log("SCAN", string.format("%s complete: raw=%d valid=%d markets=%d base=%d variants=%d variantRows=%d incomplete=%d invalid=%d model=%d ms=%d",
      source, total, validRows, #items, baseItemCount, variantMarkets, variantRows, incompleteRecords, invalidRecords, summary.marketOpportunities or 0, summary.processingMS))
    if TTB.SetView then TTB:SetView("opportunities", true) end
  end

  local function processChunk()
    if not TTB.scanState.running or TTB.scanState.phase ~= "processing" then return end
    local stopAt = math.min(total, index + chunkSize)
    while index < stopAt do addRow(index); index = index + 1 end
    TTB.scanState.processed = index
    local fraction = total > 0 and (index / total) or 1
    TTB.scanState.status = string.format("Processing snapshot: %d / %d", index, total)
    TTB.scanState.progress = 0.05 + fraction * 0.93
    if index >= total then finish() else C_Timer.After(0.01, processChunk) end
  end

  processChunk()
end

function TTB:RequestItemQuery(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then self:Print("Enter a valid numeric item ID."); return end
  if not self:CanUseAuctionHouse() then self:Print("Open the Auction House first."); return end
  if type(C_AuctionHouse.SendSearchQuery) ~= "function" then self:Print("SendSearchQuery is unavailable on this client."); return end
  if self.lastQueryRequestAt and (GetTime() - self.lastQueryRequestAt) < 2 then self:Print("Wait two seconds between item queries."); return end

  local itemKey = makeItemKey(itemID)
  self.pendingQuery = { itemID = itemID, itemKey = itemKey, startedAt = time() }
  self.lastQueryRequestAt = GetTime()
  local ok, err = pcall(C_AuctionHouse.SendSearchQuery, itemKey, priceSorts(), false)
  if not ok then
    self.pendingQuery = nil
    self:Log("QUERY ERROR", "SendSearchQuery itemID=" .. itemID .. ": " .. tostring(err))
    self:Print("Search query failed; see diagnostic log.")
    return
  end
  self:Log("QUERY", "Sent search query for itemID=" .. tostring(itemID))
  if self.RefreshUI then self:RefreshUI() end
end

function TTB:CaptureCommodityQuery(itemID)
  if not self.pendingQuery or tonumber(self.pendingQuery.itemID) ~= tonumber(itemID) then return end
  local count = 0
  if type(C_AuctionHouse.GetNumCommoditySearchResults) == "function" then
    local ok, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID); if ok then count = tonumber(n) or 0 end
  end
  local totalQuantity, floorPrice, sampled = 0, nil, 0
  if type(C_AuctionHouse.GetCommoditySearchResultInfo) == "function" then
    for i = 1, count do
      local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
      if ok and type(info) == "table" then
        local qty, price = tonumber(info.quantity) or 0, tonumber(info.unitPrice) or 0
        totalQuantity = totalQuantity + qty
        if price > 0 and (not floorPrice or price < floorPrice) then floorPrice = price end
        sampled = sampled + 1
      end
    end
  end
  local hasFull = nil
  if type(C_AuctionHouse.HasFullCommoditySearchResults) == "function" then
    local ok, value = pcall(C_AuctionHouse.HasFullCommoditySearchResults, itemID); if ok then hasFull = value and true or false end
  end
  local q = { itemID = itemID, resultType = "commodity", resultCount = count, sampledResults = sampled, totalQuantity = totalQuantity, floorPrice = floorPrice or 0, hasFullResults = hasFull, completedAt = time() }
  self.pendingQuery = nil
  self.db.latestQuery = q; table.insert(self.db.queries, q); while #self.db.queries > 30 do table.remove(self.db.queries, 1) end
  self:Log("QUERY", string.format("Commodity itemID=%d results=%d qty=%d floor=%s full=%s", itemID, count, totalQuantity, self:Money(q.floorPrice), tostring(hasFull)))
  if self.RefreshUI then self:RefreshUI() end
end

function TTB:CaptureItemQuery(itemKey)
  local itemID = type(itemKey) == "table" and tonumber(itemKey.itemID) or nil
  if not self.pendingQuery or itemID ~= tonumber(self.pendingQuery.itemID) then return end
  local count = 0
  if type(C_AuctionHouse.GetNumItemSearchResults) == "function" then
    local ok, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey); if ok then count = tonumber(n) or 0 end
  end
  local totalQuantity, floorPrice, sampled = 0, nil, 0
  if type(C_AuctionHouse.GetItemSearchResultInfo) == "function" then
    for i = 1, count do
      local ok, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
      if ok and type(info) == "table" then
        local qty, price = tonumber(info.quantity) or 1, tonumber(info.buyoutAmount) or 0
        totalQuantity = totalQuantity + qty
        if price > 0 and (not floorPrice or price < floorPrice) then floorPrice = price end
        sampled = sampled + 1
      end
    end
  end
  local hasFull = nil
  if type(C_AuctionHouse.HasFullItemSearchResults) == "function" then
    local ok, value = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey); if ok then hasFull = value and true or false end
  end
  local q = { itemID = itemID, resultType = "item", resultCount = count, sampledResults = sampled, totalQuantity = totalQuantity, floorPrice = floorPrice or 0, hasFullResults = hasFull, completedAt = time() }
  self.pendingQuery = nil
  self.db.latestQuery = q; table.insert(self.db.queries, q); while #self.db.queries > 30 do table.remove(self.db.queries, 1) end
  self:Log("QUERY", string.format("Item itemID=%d results=%d qty=%d floor=%s full=%s", itemID or 0, count, totalQuantity, self:Money(q.floorPrice), tostring(hasFull)))
  if self.RefreshUI then self:RefreshUI() end
end

function TTB:RequestOwnedAuctionsDiagnostic()
  if not self:CanUseAuctionHouse() then self:Print("Open the Auction House first."); return end
  if type(C_AuctionHouse.QueryOwnedAuctions) ~= "function" then self:Print("QueryOwnedAuctions is unavailable on this client."); return end
  local sorts = {}
  if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.TimeRemaining ~= nil then
    sorts = { { sortOrder = Enum.AuctionHouseSortOrder.TimeRemaining, reverseSort = false } }
  end
  self.pendingOwnedQueryAt = time()
  local ok, err = pcall(C_AuctionHouse.QueryOwnedAuctions, sorts)
  if not ok then self:Log("OWNED ERROR", tostring(err)); self:Print("Owned-auction query failed; see log."); return end
  self:Log("OWNED", "Sent QueryOwnedAuctions diagnostic")
end

function TTB:CaptureOwnedAuctions()
  if not self.pendingOwnedQueryAt then return end
  local count = 0
  if type(C_AuctionHouse.GetNumOwnedAuctions) == "function" then
    local ok, n = pcall(C_AuctionHouse.GetNumOwnedAuctions); if ok then count = tonumber(n) or 0 end
  elseif type(C_AuctionHouse.GetOwnedAuctions) == "function" then
    local ok, rows = pcall(C_AuctionHouse.GetOwnedAuctions); if ok and type(rows) == "table" then count = #rows end
  end
  local q = { requestedAt = self.pendingOwnedQueryAt, completedAt = time(), count = count }
  self.pendingOwnedQueryAt = nil
  self.db.latestOwnedQuery = q; table.insert(self.db.ownedQueries, q); while #self.db.ownedQueries > 20 do table.remove(self.db.ownedQueries, 1) end
  self:Log("OWNED", "Owned auctions returned: " .. tostring(count))
  if self.RefreshUI then self:RefreshUI() end
end

TTB:RegisterHandler("REPLICATE_ITEM_LIST_UPDATE", function(self)
  if not self.scanState.running or self.scanState.phase ~= "waiting" then return end
  local ok, total = pcall(C_AuctionHouse.GetNumReplicateItems)
  total = ok and tonumber(total) or 0
  if not total or total <= 0 then
    self.scanState.running = false; self.scanState.phase = "error"
    self:SetScanStatus("Replicate update fired but Blizzard cache count is zero", 0)
    self:Log("SCAN ERROR", "Replicate update arrived with zero cached rows")
    return
  end
  self:Log("SCAN", "REPLICATE_ITEM_LIST_UPDATE received with " .. tostring(total) .. " rows")
  self:StartSnapshotProcessing(total, "fresh replicate request")
end)

TTB:RegisterHandler("COMMODITY_SEARCH_RESULTS_UPDATED", function(self, _, itemID) self:CaptureCommodityQuery(itemID) end)
TTB:RegisterHandler("ITEM_SEARCH_RESULTS_UPDATED", function(self, _, itemKey) self:CaptureItemQuery(itemKey) end)
TTB:RegisterHandler("OWNED_AUCTIONS_UPDATED", function(self) self:CaptureOwnedAuctions() end)
