local addonName, TTB = ...

local API_SPECS = {
  { "C_AuctionHouse.ReplicateItems", "READ/SCAN - full AH snapshot request" },
  { "C_AuctionHouse.GetNumReplicateItems", "READ - cached snapshot count" },
  { "C_AuctionHouse.GetReplicateItemInfo", "READ - cached snapshot row" },
  { "C_AuctionHouse.GetReplicateItemLink", "READ - cached snapshot item link" },
  { "C_AuctionHouse.GetReplicateItemTimeLeft", "READ - cached snapshot time left" },
  { "C_AuctionHouse.IsThrottledMessageSystemReady", "READ - AH throttle state" },
  { "C_AuctionHouse.RefreshItemSearchResults", "QUERY - refresh cached regular-item results" },
  { "C_AuctionHouse.RefreshCommoditySearchResults", "QUERY - refresh cached commodity results" },
  { "C_AuctionHouse.GetItemKeyInfo", "READ - key metadata and classification" },
  { "C_AuctionHouse.HasSearchResults", "READ - cached search presence" },
  { "C_AuctionHouse.CancelCommoditiesPurchase", "QUOTE - cancel unconfirmed quote" },
  { "C_AuctionHouse.MakeItemKey", "READ - construct item key" },
  { "C_AuctionHouse.SendSearchQuery", "QUERY - item/commodity search" },
  { "C_AuctionHouse.SendSellSearchQuery", "QUERY - sell-side search" },
  { "C_AuctionHouse.GetNumCommoditySearchResults", "READ - commodity result count" },
  { "C_AuctionHouse.GetCommoditySearchResultInfo", "READ - commodity price levels" },
  { "C_AuctionHouse.GetNumItemSearchResults", "READ - item result count" },
  { "C_AuctionHouse.GetItemSearchResultInfo", "READ - item auction rows" },
  { "C_AuctionHouse.HasFullCommoditySearchResults", "READ - pagination status" },
  { "C_AuctionHouse.HasFullItemSearchResults", "READ - pagination status" },
  { "C_AuctionHouse.RequestMoreCommoditySearchResults", "QUERY - pagination" },
  { "C_AuctionHouse.RequestMoreItemSearchResults", "QUERY - pagination" },
  { "C_AuctionHouse.QueryOwnedAuctions", "QUERY - own auctions" },
  { "C_AuctionHouse.GetOwnedAuctions", "READ - own auctions" },
  { "C_AuctionHouse.GetNumOwnedAuctions", "READ - own auction count" },
  { "C_AuctionHouse.GetOwnedAuctionInfo", "READ - own auction row" },
  { "C_AuctionHouse.GetItemCommodityStatus", "READ - commodity classification" },
  { "C_AuctionHouse.CalculateCommodityDeposit", "READ/CALC - deposit quote" },
  { "C_AuctionHouse.CalculateItemDeposit", "READ/CALC - deposit quote" },
  { "C_AuctionHouse.StartCommoditiesPurchase", "PROTECTED - hardware event required on modern AH" },
  { "C_AuctionHouse.ConfirmCommoditiesPurchase", "PURCHASE - hardware input required" },
  { "C_AuctionHouse.PlaceBid", "PROTECTED/PURCHASE - hardware input required" },
  { "C_AuctionHouse.PostCommodity", "PROTECTED/POST - hardware input required" },
  { "C_AuctionHouse.PostItem", "PROTECTED/POST - hardware input required" },
  { "C_AuctionHouse.CancelAuction", "PROTECTED/CANCEL - hardware input required" },
  { "C_AuctionHouse.CanCancelAuction", "READ - cancel eligibility" },
  { "C_AuctionHouse.GetCancelCost", "READ - cancel cost" },
  { "C_AuctionHouse.SupportsCopperValues", "READ - currency behavior" },
}

local EVENT_SPECS = {
  "AUCTION_HOUSE_SHOW",
  "AUCTION_HOUSE_CLOSED",
  "AUCTION_HOUSE_DISABLED",
  "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_AUCTION_CREATED",
  "AUCTION_CANCELED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "ITEM_PURCHASED",
  "COMMODITY_PURCHASED",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "REPLICATE_ITEM_LIST_UPDATE",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_ADDED",
  "OWNED_AUCTIONS_UPDATED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}

local function resolvePath(path)
  local current = _G
  for token in string.gmatch(path, "[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[token]
    if current == nil then
      return nil
    end
  end
  return current
end

function TTB:RunAPIProbe()
  if not self.db then
    self:InitializeDatabase()
  end

  local results = {}
  local present = 0

  for _, spec in ipairs(API_SPECS) do
    local path = spec[1]
    local value = resolvePath(path)
    local exists = type(value) == "function"
    if exists then
      present = present + 1
    end
    table.insert(results, {
      path = path,
      present = exists,
      valueType = type(value),
      note = spec[2],
    })
  end

  local eventResults = {}
  for _, eventName in ipairs(EVENT_SPECS) do
    local ok = pcall(self.eventFrame.RegisterEvent, self.eventFrame, eventName)
    if ok then
      table.insert(eventResults, { event = eventName, supported = true })
    else
      table.insert(eventResults, { event = eventName, supported = false })
    end
  end

  local throttleReady = nil
  if C_AuctionHouse and type(C_AuctionHouse.IsThrottledMessageSystemReady) == "function" then
    local ok, result = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
    if ok then
      throttleReady = result and true or false
    end
  end

  self.db.currentBuild = self:GetBuildSnapshot()
  self.db.api = {
    capturedAt = time(),
    present = present,
    total = #API_SPECS,
    results = results,
    events = eventResults,
    throttleReady = throttleReady,
    hasAuctionHouseTable = type(C_AuctionHouse) == "table",
  }

  self:Log("PROBE", string.format("AH API probe: %d/%d functions present; TOC=%s", present, #API_SPECS, tostring(self.db.currentBuild.tocVersion)))
  if self.RefreshUI then
    self:RefreshUI()
  end
end

function TTB:GetAPIProbeSpecs()
  return API_SPECS
end

function TTB:GetEventProbeSpecs()
  return EVENT_SPECS
end

TTB:RegisterHandler("AUCTION_HOUSE_SHOW", function(self)
  self.ahOpen = true
  self:Log("AH", "Auction House opened")
  self:RunAPIProbe()
end)

TTB:RegisterHandler("AUCTION_HOUSE_CLOSED", function(self)
  self.ahOpen = false
  self:Log("AH", "Auction House closed")
  if self.scanState and self.scanState.running then
    self.scanState.running = false
    self.scanState.phase = "aborted"
    self.scanState.status = "Auction House closed during scan"
  end
end)

