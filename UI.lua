local addonName, TTB = ...

local function makeButton(parent, text, width, callback)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 130, 28)
  b:SetText(text)
  b:SetScript("OnClick", callback)
  return b
end

local function addLine(lines, text)
  lines[#lines + 1] = tostring(text or "")
end

local function statusColor(ok)
  if ok then return "|cff66ff99YES|r" end
  return "|cffff6666NO|r"
end

local function signalColor(signal)
  if signal == "BUY CANDIDATE" then return "|cff66ff99" end
  if type(signal) == "string" and string.find(signal, "WATCH", 1, true) then return "|cffffd966" end
  return "|cffaaaaaa"
end

local function joinText(values)
  if not values or #values == 0 then return "none" end
  return table.concat(values, "; ")
end

function TTB:BuildOpportunitiesText()
  local lines = {}
  addLine(lines, "|cffffffffTOP MARKET OPPORTUNITIES|r")
  addLine(lines, "|cffaaaaaaRead-only model. SAFE MODE calls no buy/post/cancel actions. BUY CANDIDATE cannot appear until at least 3 observations of that exact market variant.|r")
  addLine(lines, "|cffaaaaaaScoring now weights absolute profit + cheap-depth profit and penalizes thin/outlier markets. Activity remains a snapshot-change proxy, not proven sell-through.|r")
  addLine(lines, "")

  local scan = self.db and self.db.latestScan
  if scan then
    addLine(lines, string.format("Latest scan: %d valid auctions | %d markets | %d quantity | model scan #%s | %d ms",
      scan.auctionsProcessed or 0, scan.uniqueItems or 0, scan.totalQuantity or 0, tostring(scan.marketScanID or "?"), scan.processingMS or 0))
  else
    addLine(lines, "No market snapshot yet. Open the AH and click REQUEST FRESH SCAN.")
  end
  addLine(lines, "")

  local opportunities = self:GetTopOpportunities(20)
  if #opportunities == 0 then
    addLine(lines, "No WATCH/BUY candidates are stored yet.")
    addLine(lines, "Run a fresh scan with v0.2.1-beta to populate the hardened model.")
    return table.concat(lines, "\n")
  end

  for i, o in ipairs(opportunities) do
    local c = signalColor(o.signal)
    local suffixText = (tonumber(o.itemSuffix) or 0) ~= 0 and ("  suffix " .. tostring(o.itemSuffix)) or ""
    addLine(lines, string.format("%s%02d. %-17s|r  |cffffffff%s|r  |cffaaaaaa[%d]%s|r  Score %d",
      c, i, tostring(o.signal), tostring(o.name or "Unknown"), tonumber(o.itemID) or 0, suffixText, tonumber(o.score) or 0))
    addLine(lines, string.format("     Floor %s  ->  Fair %s  |  Advantage %.1f%%  |  Net/unit %s  |  Cheap depth %d for %s  |  Modeled depth net %s",
      self:Money(o.floor), self:Money(o.fairValue), (tonumber(o.priceAdvantage) or 0) * 100, self:Money(o.estimatedNetUnit), tonumber(o.cheapQuantity) or 0,
      self:Money(o.cheapCost), self:Money(o.estimatedCheapNet)))
    addLine(lines, string.format("     Supply %d across %d listings  |  Confidence %s (%d)  |  Activity %s (%d)  |  Obs %d  |  Volatility %.1f%%",
      tonumber(o.quantity) or 0, tonumber(o.listings) or 0, tostring(o.confidence), tonumber(o.confidenceScore) or 0,
      tostring(o.activity), tonumber(o.activityScore) or 0, tonumber(o.observations) or 0, (tonumber(o.volatility) or 0) * 100))
    addLine(lines, "     Why: " .. joinText(o.reasons))
    addLine(lines, "     Risk: " .. joinText(o.risks))
    addLine(lines, "")
  end

  addLine(lines, "Enter any item ID above in the Item ID box and click DETAIL for the full price-depth/history view.")
  return table.concat(lines, "\n")
end

function TTB:BuildDatabaseText()
  local lines = {}
  addLine(lines, "|cffffffffMARKET DATABASE|r")
  local stats = self.db and self.db.marketStats
  local market = self.db and self.db.market or {}
  if not stats then
    addLine(lines, "No modeled market database yet. Run one v0.2.1-beta scan.")
    return table.concat(lines, "\n")
  end

  addLine(lines, string.format("Stored markets: %d  |  updated last scan: %d  |  WATCH/BUY candidates: %d  |  latest scan ID: %d",
    stats.storedMarkets or 0, stats.marketsUpdated or 0, stats.opportunities or 0, stats.scanID or 0))
  addLine(lines, "Each exact market variant keeps up to 30 compact observations. Random-stat suffixes are separated; v0.2.0 unsuffixed history is preserved.")
  addLine(lines, "")

  local rows = {}
  for _, m in pairs(market) do
    if m.latest then rows[#rows + 1] = m end
  end
  table.sort(rows, function(a, b)
    if (a.observations or 0) == (b.observations or 0) then
      return (a.latest.quantity or 0) > (b.latest.quantity or 0)
    end
    return (a.observations or 0) > (b.observations or 0)
  end)

  addLine(lines, "MOST OBSERVED / LARGEST CURRENT MARKETS")
  for i = 1, math.min(40, #rows) do
    local m = rows[i]
    local suffixText = (tonumber(m.itemSuffix) or 0) ~= 0 and (" s" .. tostring(m.itemSuffix)) or ""
    addLine(lines, string.format("%2d. %-30s [%d%s]  obs=%d  floor=%s  fair=%s  qty=%d  listings=%d  conf=%s  activity=%s",
      i, tostring(m.name or "Unknown"), tonumber(m.itemID) or 0, suffixText, tonumber(m.observations) or 0,
      self:Money(m.latest.floor), self:Money(m.fairValue), tonumber(m.latest.quantity) or 0, tonumber(m.latest.listings) or 0,
      tostring(m.confidence or "?"), tostring(m.activity or "?")))
  end
  return table.concat(lines, "\n")
end

function TTB:BuildDiagnosticsText()
  local lines = {}
  local build = self.db and self.db.currentBuild or self:GetBuildSnapshot()
  local api = self.db and self.db.api

  addLine(lines, "|cffffffffCLIENT / SAFE MODE|r")
  addLine(lines, string.format("Addon %s | Client %s | Build %s | Interface %s | WOW_PROJECT_ID %s",
    tostring(self.version), tostring(build.version), tostring(build.build), tostring(build.tocVersion), tostring(build.projectID)))
  addLine(lines, string.format("Forever Beta: %s | AH open: %s | SAFE MODE: |cff66ff99ON|r", statusColor(build.isForeverBeta), statusColor(self.ahOpen)))
  addLine(lines, "Protected buy / bid / post / cancel APIs are presence-probed only. This build calls none of them.")
  addLine(lines, "")

  addLine(lines, "|cffffffffSCAN STATE|r")
  addLine(lines, string.format("%s | %d%% | local replicate timer %s", tostring(self.scanState.status), math.floor((self.scanState.progress or 0) * 100 + 0.5), self:FormatDuration(self:GetSecondsUntilFreshScanAllowed())))
  local scan = self.db and self.db.latestScan
  if scan then
    addLine(lines, string.format("Latest: raw=%d valid=%d markets=%d baseItems=%d suffixVariants=%d qty=%d incomplete=%d invalid=%d modelCandidates=%d",
      scan.rawRows or 0, scan.auctionsProcessed or 0, scan.uniqueItems or 0, scan.uniqueBaseItems or scan.uniqueItems or 0, scan.variantMarkets or 0, scan.totalQuantity or 0,
      scan.incompleteRecords or 0, scan.invalidRecords or 0, scan.marketOpportunities or 0))
  end
  addLine(lines, "")

  addLine(lines, "|cffffffffAPI PROBE|r")
  if api and api.results then
    addLine(lines, string.format("Functions present: %d / %d | throttle ready at probe: %s", api.present or 0, api.total or 0, tostring(api.throttleReady)))
    for _, row in ipairs(api.results) do
      addLine(lines, string.format("%s %-47s %s", row.present and "|cff66ff99YES|r" or "|cffff6666NO |r", row.path, row.note or ""))
    end
  else
    addLine(lines, "No API probe data.")
  end
  addLine(lines, "")

  addLine(lines, "|cffffffffLATEST LIVE QUERY|r")
  local q = self.db and self.db.latestQuery
  if q then
    addLine(lines, string.format("Item %s | type=%s | results=%s | qty=%s | floor=%s | full=%s",
      tostring(q.itemID), tostring(q.resultType), tostring(q.resultCount), tostring(q.totalQuantity), self:Money(q.floorPrice), tostring(q.hasFullResults)))
  else
    addLine(lines, "No live item query completed yet.")
  end
  addLine(lines, "")

  addLine(lines, "|cffffffffRECENT LOG|r")
  local log = self.db and self.db.log or self.runtimeLog
  local startAt = math.max(1, #log - 24)
  for i = startAt, #log do
    local e = log[i]
    addLine(lines, string.format("[%s] %-11s %s", date("%H:%M:%S", e.at or time()), tostring(e.kind), tostring(e.message)))
  end
  return table.concat(lines, "\n")
end

function TTB:BuildItemDetailText(itemID)
  local lines = {}
  local m = self:GetMarket(itemID)
  addLine(lines, "|cffffffffITEM DETAIL|r")
  if not m or not m.latest then
    addLine(lines, "No saved market data for item ID " .. tostring(itemID) .. ".")
    addLine(lines, "Run a full scan first, or choose an item ID shown in Top 20 / Market DB.")
    return table.concat(lines, "\n")
  end

  local o = m.latest
  local variants = self.GetMarketVariants and self:GetMarketVariants(itemID) or { m }
  local suffixText = (tonumber(m.itemSuffix) or 0) ~= 0 and ("  |  suffix " .. tostring(m.itemSuffix)) or ""
  addLine(lines, string.format("|cffffffff%s|r  [%d]%s  |  %s  |  Opportunity score %d", tostring(m.name), tonumber(m.itemID) or 0, suffixText, tostring(m.signal), tonumber(m.opportunityScore) or 0))
  if #variants > 1 then
    addLine(lines, string.format("Stored variants for this base item: %d. DETAIL shows the most recently observed variant; Top 20 identifies suffixes explicitly.", #variants))
  end
  addLine(lines, "")
  addLine(lines, "|cffffffffPRICE / DEPTH|r")
  addLine(lines, string.format("Floor: %s  |  floor qty: %d  |  modeled fair: %s  |  current depth value: %s  |  historical fair: %s",
    self:Money(o.floor), tonumber(o.floorQuantity) or 0, self:Money(m.fairValue), self:Money(o.depthValue), self:Money(m.historicalFair)))
  addLine(lines, string.format("Q10 %s  |  Q25 %s  |  Median %s  |  Q75 %s  |  Q90 %s  |  Ceiling %s",
    self:Money(o.q10), self:Money(o.q25), self:Money(o.median), self:Money(o.q75), self:Money(o.q90), self:Money(o.ceiling)))
  addLine(lines, string.format("Price advantage: %.1f%%  |  net/unit after 5%% AH cut: %s  |  units <= 82%% of depth value: %d (capital %s)",
    (tonumber(m.priceAdvantage) or 0) * 100, self:Money(m.estimatedNetUnit), tonumber(o.cheapQuantity) or 0, self:Money(o.cheapCost)))
  addLine(lines, string.format("Modeled cheap-depth net: %s  |  cheap-depth ROI: %.1f%%  |  BUY history gate: %d/%d observations",
    self:Money(m.estimatedCheapNet), (tonumber(m.estimatedCheapROI) or 0) * 100, tonumber(m.observations) or 0, tonumber(m.minBuyObservations) or 3))
  addLine(lines, "")

  addLine(lines, "|cffffffffMODEL / CONFIDENCE|r")
  addLine(lines, string.format("Observations: %d  |  confidence: %s (%d/100)  |  activity proxy: %s (%d/100)  |  volatility: %.1f%%",
    tonumber(m.observations) or 0, tostring(m.confidence), tonumber(m.confidenceScore) or 0, tostring(m.activity), tonumber(m.activityScore) or 0, (tonumber(m.volatility) or 0) * 100))
  addLine(lines, string.format("Fresh-launch/current weight: %.0f%%  |  historical weight: %.0f%%", (tonumber(m.freshLaunchWeight) or 0) * 100, (tonumber(m.historyWeight) or 0) * 100))
  addLine(lines, string.format("Supply change: %+d (%+.1f%%)  |  median move: %+.1f%%  |  floor move: %+.1f%%",
    tonumber(m.supplyChange) or 0, (tonumber(m.supplyChangePct) or 0) * 100, (tonumber(m.medianMovePct) or 0) * 100, (tonumber(m.floorMovePct) or 0) * 100))
  addLine(lines, string.format("Vendor value: %s  |  below vendor: %s  |  thin floor: %s",
    m.vendorPrice and m.vendorPrice > 0 and self:Money(m.vendorPrice) or "unknown", tostring(m.vendorArbitrage and true or false), tostring(m.thinFloor and true or false)))
  addLine(lines, "")

  addLine(lines, "|cff66ff99WHY|r  " .. joinText(m.reasons))
  addLine(lines, "|cffffcc66RISKS|r  " .. joinText(m.risks))
  addLine(lines, "")
  addLine(lines, "|cffffffffHISTORY (oldest -> newest, max 30)|r")
  for i, h in ipairs(m.history or {}) do
    addLine(lines, string.format("%2d. %s  scan#%s  floor=%s  median=%s  depth=%s  qty=%d  listings=%d  cheap=%d",
      i, date("%m/%d %H:%M", h.at or time()), tostring(h.scanID or "?"), self:Money(h.floor), self:Money(h.median), self:Money(h.depthValue),
      tonumber(h.quantity) or 0, tonumber(h.listings) or 0, tonumber(h.cheapQuantity) or 0))
  end
  addLine(lines, "")
  addLine(lines, "Use LIVE QUERY to compare the saved full-scan model with Blizzard's current targeted search result. No purchase is made.")
  return table.concat(lines, "\n")
end

function TTB:BuildCurrentViewText()
  local view = self.currentView or (self.db and self.db.settings and self.db.settings.defaultView) or "opportunities"
  if view == "database" then return self:BuildDatabaseText() end
  if view == "diagnostics" then return self:BuildDiagnosticsText() end
  if view == "detail" then return self:BuildItemDetailText(self.selectedItemID or 0) end
  return self:BuildOpportunitiesText()
end

function TTB:SetView(view, silent)
  self.currentView = view or "opportunities"
  if self.db and self.db.settings then self.db.settings.defaultView = self.currentView end
  if self.frame and not silent then self.frame:Show() end
  self:RefreshUI()
end

function TTB:ShowItemDetail(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then self:Print("Enter a valid item ID for DETAIL."); return end
  self.selectedItemID = itemID
  if self.queryEditBox then self.queryEditBox:SetText(tostring(itemID)) end
  self:SetView("detail")
end

function TTB:InitializeUI()
  if self.frame then return end

  local f = CreateFrame("Frame", "TaliaaTradeBetaFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetSize(1080, 720)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
  f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 22, -18)
  title:SetText("TALIAA TRADE — FOREVER MARKET PROTOTYPE")

  local safe = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  safe:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  safe:SetText("|cff66ff99SAFE MODE ON|r — scan/database/model only; zero buy / post / cancel calls")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -7, -7)

  local top = makeButton(f, "TOP 20", 90, function() TTB:SetView("opportunities") end)
  top:SetPoint("TOPLEFT", 22, -68)
  local db = makeButton(f, "MARKET DB", 100, function() TTB:SetView("database") end)
  db:SetPoint("LEFT", top, "RIGHT", 7, 0)
  local diag = makeButton(f, "DIAGNOSTICS", 110, function() TTB:SetView("diagnostics") end)
  diag:SetPoint("LEFT", db, "RIGHT", 7, 0)

  local fresh = makeButton(f, "REQUEST FRESH SCAN", 160, function() TTB:RequestFreshScan() end)
  fresh:SetPoint("LEFT", diag, "RIGHT", 20, 0)
  self.freshScanButton = fresh
  local cached = makeButton(f, "ANALYZE CACHED", 135, function() TTB:AnalyzeCachedSnapshot() end)
  cached:SetPoint("LEFT", fresh, "RIGHT", 7, 0)
  local report = makeButton(f, "COPY REPORT", 115, function() TTB:ShowReport() end)
  report:SetPoint("LEFT", cached, "RIGHT", 7, 0)

  local queryLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  queryLabel:SetPoint("TOPLEFT", 22, -108)
  queryLabel:SetText("Item ID:")

  local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  self.queryEditBox = edit
  edit:SetSize(110, 28)
  edit:SetPoint("LEFT", queryLabel, "RIGHT", 10, 0)
  edit:SetAutoFocus(false)
  edit:SetNumeric(true)
  edit:SetMaxLetters(10)

  local detail = makeButton(f, "DETAIL", 85, function() TTB:ShowItemDetail(edit:GetText()) end)
  detail:SetPoint("LEFT", edit, "RIGHT", 8, 0)
  local live = makeButton(f, "LIVE QUERY", 105, function() TTB:RequestItemQuery(edit:GetText()) end)
  live:SetPoint("LEFT", detail, "RIGHT", 8, 0)
  local probe = makeButton(f, "REFRESH API PROBE", 145, function() TTB:RunAPIProbe(); TTB:SetView("diagnostics") end)
  probe:SetPoint("LEFT", live, "RIGHT", 8, 0)

  local queryHelp = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  queryHelp:SetPoint("LEFT", probe, "RIGHT", 10, 0)
  queryHelp:SetText("DETAIL uses saved DB. LIVE QUERY asks Blizzard for current results; it never buys.")

  local scanStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.scanStatusText = scanStatus
  scanStatus:SetPoint("TOPLEFT", 22, -145)
  scanStatus:SetWidth(1020)
  scanStatus:SetJustifyH("LEFT")

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  self.scroll = scroll
  scroll:SetPoint("TOPLEFT", 22, -171)
  scroll:SetPoint("BOTTOMRIGHT", -42, 22)

  local child = CreateFrame("Frame", nil, scroll)
  self.scrollChild = child
  child:SetSize(980, 1600)
  scroll:SetScrollChild(child)

  local body = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.bodyText = body
  body:SetPoint("TOPLEFT", 2, -2)
  body:SetWidth(970)
  body:SetJustifyH("LEFT")
  body:SetJustifyV("TOP")
  body:SetSpacing(2)

  f:SetScript("OnUpdate", function(frame, elapsed)
    frame.ttbElapsed = (frame.ttbElapsed or 0) + elapsed
    if frame.ttbElapsed >= 1 then frame.ttbElapsed = 0; TTB:RefreshUI() end
  end)

  tinsert(UISpecialFrames, "TaliaaTradeBetaFrame")
  self:CreateReportWindow()
  self.currentView = self.db and self.db.settings and self.db.settings.defaultView or "opportunities"
  self:RefreshUI()

  if self.db and self.db.settings and self.db.settings.windowShown then f:Show() else f:Hide() end
end

function TTB:CreateReportWindow()
  if self.reportFrame then return end
  local f = CreateFrame("Frame", "TaliaaTradeBetaReportFrame", UIParent, "BackdropTemplate")
  self.reportFrame = f
  f:SetSize(860, 600)
  f:SetPoint("CENTER")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
  f:SetScript("OnDragStop", function(frame) frame:StopMovingOrSizing() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 22, -18)
  title:SetText("COPY TALIAA TRADE TEST REPORT")
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
  hint:SetText("Ctrl+A, Ctrl+C. Includes market-model summary, API probe, and recent log.")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -7, -7)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 22, -66)
  scroll:SetPoint("BOTTOMRIGHT", -42, 22)
  local edit = CreateFrame("EditBox", nil, scroll)
  self.reportEditBox = edit
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(790)
  edit:SetTextInsets(4, 4, 4, 4)
  edit:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
  edit:SetScript("OnTextChanged", function() scroll:UpdateScrollChildRect() end)
  scroll:SetScrollChild(edit)
  edit:SetHeight(500)
  tinsert(UISpecialFrames, "TaliaaTradeBetaReportFrame")
  f:Hide()
end

function TTB:ShowReport()
  if not self.reportFrame then self:CreateReportWindow() end
  local text = self:BuildTextReport()
  self.reportEditBox:SetText(text)
  self.reportEditBox:SetCursorPosition(0)
  local lines = 1
  for _ in string.gmatch(text, "\n") do lines = lines + 1 end
  self.reportEditBox:SetHeight(math.max(500, lines * 15 + 30))
  self.reportFrame:Show()
  self.reportEditBox:SetFocus()
  self.reportEditBox:HighlightText()
end

function TTB:RefreshUI()
  if not self.frame or not self.frame:IsShown() then return end
  if self.scanStatusText then
    local remain = self:GetSecondsUntilFreshScanAllowed()
    self.scanStatusText:SetText(string.format("Scan: %s  |  %d%%  |  next fresh full snapshot: %s  |  saved DB remains available between scans",
      tostring(self.scanState.status), math.floor((self.scanState.progress or 0) * 100 + 0.5), self:FormatDuration(remain)))
  end
  if self.freshScanButton then
    local remain = self:GetSecondsUntilFreshScanAllowed()
    if remain > 0 then self.freshScanButton:SetText("FRESH SCAN " .. self:FormatDuration(remain)) else self.freshScanButton:SetText("REQUEST FRESH SCAN") end
  end
  if self.queryEditBox and self.queryEditBox:GetText() == "" and self.suggestedTestItemID then self.queryEditBox:SetText(tostring(self.suggestedTestItemID)) end
  if self.bodyText then
    local text = self:BuildCurrentViewText()
    self.bodyText:SetText(text)
    self.scrollChild:SetHeight(math.max(1600, self.bodyText:GetStringHeight() + 40))
  end
end

function TTB:ToggleUI()
  if not self.frame then self:InitializeUI() end
  if self.frame:IsShown() then
    self.frame:Hide()
    if self.db and self.db.settings then self.db.settings.windowShown = false end
  else
    self.frame:Show()
    if self.db and self.db.settings then self.db.settings.windowShown = true end
    self:RefreshUI()
  end
end
