local addonName, TTB = ...

_G.TaliaaTradeBeta = TTB

TTB.name = addonName or "TaliaaTradeBeta"
TTB.version = "0.2.1-beta"
TTB.schemaVersion = 3
TTB.safeMode = true
TTB.ahOpen = false
TTB.eventHandlers = {}
TTB.runtimeLog = {}
TTB.maxRuntimeLog = 250

local function now()
  if time then return time() end
  return 0
end

local function fmtTime(ts)
  ts = tonumber(ts) or now()
  if date then return date("%H:%M:%S", ts) end
  return tostring(ts)
end

local function stringify(value)
  local t = type(value)
  if t == "nil" then return "nil" end
  if t == "string" or t == "number" or t == "boolean" then return tostring(value) end
  if t == "table" then
    if value.itemID then return "itemID=" .. tostring(value.itemID) end
    return "<table>"
  end
  return "<" .. t .. ">"
end

function TTB:Print(message)
  local prefix = "|cff9f7aeaTaliaa Trade:|r "
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. tostring(message))
  elseif print then
    print(prefix .. tostring(message))
  end
end

function TTB:Log(kind, message)
  local entry = { at = now(), kind = tostring(kind or "INFO"), message = tostring(message or "") }
  table.insert(self.runtimeLog, entry)
  if #self.runtimeLog > self.maxRuntimeLog then table.remove(self.runtimeLog, 1) end

  if self.db then
    self.db.log = self.db.log or {}
    table.insert(self.db.log, entry)
    while #self.db.log > 500 do table.remove(self.db.log, 1) end
  end

  if self.RefreshUI then self:RefreshUI() end
end

function TTB:SafeCall(label, fn, ...)
  if type(fn) ~= "function" then
    self:Log("ERROR", tostring(label) .. ": function unavailable")
    return false, "function unavailable"
  end
  local args = { ... }
  local function invoke() return fn(unpack(args)) end
  local ok, a, b, c, d, e = xpcall(invoke, function(err)
    local trace = debugstack and debugstack(2, 8, 8) or ""
    return tostring(err) .. (trace ~= "" and ("\n" .. trace) or "")
  end)
  if not ok then
    self:Log("ERROR", tostring(label) .. ": " .. tostring(a))
    return false, a
  end
  return true, a, b, c, d, e
end

function TTB:RegisterHandler(eventName, handler)
  if type(eventName) ~= "string" or type(handler) ~= "function" then return false end
  self.eventHandlers[eventName] = self.eventHandlers[eventName] or {}
  table.insert(self.eventHandlers[eventName], handler)
  if self.eventFrame then
    local ok = pcall(self.eventFrame.RegisterEvent, self.eventFrame, eventName)
    if not ok then
      self:Log("EVENT", "Unsupported event: " .. eventName)
      return false
    end
  end
  return true
end

function TTB:RecordObservedEvent(eventName, ...)
  if not self.db then return end
  self.db.eventCounts = self.db.eventCounts or {}
  self.db.lastEvents = self.db.lastEvents or {}
  self.db.eventCounts[eventName] = (self.db.eventCounts[eventName] or 0) + 1
  local args, compact = { ... }, {}
  for i = 1, math.min(#args, 4) do compact[i] = stringify(args[i]) end
  self.db.lastEvents[eventName] = { at = now(), args = compact }
end

function TTB:GetBuildSnapshot()
  local version, build, buildDate, tocVersion, localizedVersion, buildInfo = GetBuildInfo()
  return {
    version = version, build = build, buildDate = buildDate, tocVersion = tocVersion,
    localizedVersion = localizedVersion, buildInfo = buildInfo, projectID = WOW_PROJECT_ID,
    projectMainline = WOW_PROJECT_MAINLINE, isForeverBeta = tonumber(tocVersion) == 16001,
    capturedAt = now(),
  }
end

function TTB:InitializeDatabase()
  TaliaaTradeBetaDB = TaliaaTradeBetaDB or {}
  self.db = TaliaaTradeBetaDB

  local oldSchema = tonumber(self.db.schemaVersion) or 0
  self.db.schemaVersion = self.schemaVersion
  self.db.firstSeen = self.db.firstSeen or now()
  self.db.log = self.db.log or {}
  self.db.eventCounts = self.db.eventCounts or {}
  self.db.lastEvents = self.db.lastEvents or {}
  self.db.api = self.db.api or {}
  self.db.buildHistory = self.db.buildHistory or {}
  self.db.scans = self.db.scans or {}
  self.db.queries = self.db.queries or {}
  self.db.ownedQueries = self.db.ownedQueries or {}
  self.db.settings = self.db.settings or {}
  self.db.settings.windowShown = self.db.settings.windowShown ~= false
  self.db.settings.defaultView = self.db.settings.defaultView or "opportunities"
  self.db.market = self.db.market or {}
  self.db.opportunities = self.db.opportunities or {}
  self.db.scanSequence = tonumber(self.db.scanSequence) or 0

  local build = self:GetBuildSnapshot()
  self.db.currentBuild = build
  local last = self.db.buildHistory[#self.db.buildHistory]
  if not last or last.build ~= build.build or last.tocVersion ~= build.tocVersion then
    table.insert(self.db.buildHistory, build)
    while #self.db.buildHistory > 20 do table.remove(self.db.buildHistory, 1) end
  end

  if oldSchema < self.schemaVersion then
    self.db.migratedFromSchema = oldSchema
    self.db.migratedAt = now()
  end
end

function TTB:GetSecondsUntilFreshScanAllowed()
  if not self.db then return 0 end
  local last = tonumber(self.db.lastFreshScanRequestAt) or 0
  local remain = 900 - (now() - last)
  if remain < 0 then remain = 0 end
  return remain
end

function TTB:FormatDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, s) end
  return string.format("%ds", s)
end

function TTB:Money(copper)
  copper = math.floor(tonumber(copper) or 0)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local cop = copper % 100
  if gold > 0 then return string.format("%dg %ds %dc", gold, silver, cop) end
  if silver > 0 then return string.format("%ds %dc", silver, cop) end
  return string.format("%dc", cop)
end

function TTB:DescribeEvent(eventName)
  if not self.db or not self.db.lastEvents then return "never" end
  local e = self.db.lastEvents[eventName]
  if not e then return "never" end
  local suffix = ""
  if e.args and #e.args > 0 then suffix = " [" .. table.concat(e.args, ", ") .. "]" end
  return fmtTime(e.at) .. suffix
end

function TTB:BuildTextReport()
  local lines = {}
  local build = (self.db and self.db.currentBuild) or self:GetBuildSnapshot()
  table.insert(lines, "TALIAA TRADE - FOREVER BETA MARKET PROTOTYPE REPORT")
  table.insert(lines, "Addon version: " .. tostring(self.version))
  table.insert(lines, "Safe mode: ON (no buy/post/cancel actions are called)")
  table.insert(lines, "Client version: " .. tostring(build.version))
  table.insert(lines, "Build: " .. tostring(build.build))
  table.insert(lines, "TOC/interface: " .. tostring(build.tocVersion))
  table.insert(lines, "WOW_PROJECT_ID: " .. tostring(build.projectID))
  table.insert(lines, "Forever Beta detected: " .. tostring(build.isForeverBeta))
  table.insert(lines, "AH open now: " .. tostring(self.ahOpen))
  table.insert(lines, "")

  local scan = self.db and self.db.latestScan
  table.insert(lines, "LATEST FULL SCAN")
  if scan then
    table.insert(lines, string.format("Source: %s | raw=%s | valid=%s | markets=%s | baseItems=%s | suffixVariants=%s | quantity=%s | incomplete=%s | invalid=%s | ms=%s",
      tostring(scan.source), tostring(scan.rawRows), tostring(scan.auctionsProcessed), tostring(scan.uniqueItems), tostring(scan.uniqueBaseItems or scan.uniqueItems),
      tostring(scan.variantMarkets or 0), tostring(scan.totalQuantity), tostring(scan.incompleteRecords), tostring(scan.invalidRecords), tostring(scan.processingMS)))
    table.insert(lines, "Market scan ID: " .. tostring(scan.marketScanID or "n/a"))
  else
    table.insert(lines, "No scan completed yet.")
  end

  table.insert(lines, "")
  table.insert(lines, "MARKET DATABASE")
  local stats = self.db and self.db.marketStats
  if stats then
    table.insert(lines, string.format("Stored markets: %d | updated last scan: %d | opportunities: %d", stats.storedMarkets or 0, stats.marketsUpdated or 0, stats.opportunities or 0))
  else
    table.insert(lines, "No market model has been generated yet.")
  end

  table.insert(lines, "")
  table.insert(lines, "TOP OPPORTUNITIES")
  local opportunities = self.GetTopOpportunities and self:GetTopOpportunities(20) or {}
  if #opportunities == 0 then
    table.insert(lines, "No WATCH/BUY candidates yet. Run a fresh scan.")
  else
    for i, o in ipairs(opportunities) do
      local suffixText = (tonumber(o.itemSuffix) or 0) ~= 0 and (" suffix=" .. tostring(o.itemSuffix)) or ""
      table.insert(lines, string.format("%02d | %s | %s [%d]%s | score=%d | floor=%s | fair=%s | advantage=%.1f%% | net/unit=%s | depthNet=%s | qty=%d | cheap=%d | conf=%s(%d) | activity=%s(%d) | obs=%d",
        i, tostring(o.signal), tostring(o.name), tonumber(o.itemID) or 0, suffixText, tonumber(o.score) or 0, self:Money(o.floor), self:Money(o.fairValue),
        (tonumber(o.priceAdvantage) or 0) * 100, self:Money(o.estimatedNetUnit), self:Money(o.estimatedCheapNet), tonumber(o.quantity) or 0, tonumber(o.cheapQuantity) or 0,
        tostring(o.confidence), tonumber(o.confidenceScore) or 0, tostring(o.activity), tonumber(o.activityScore) or 0, tonumber(o.observations) or 0))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "API PROBE")
  if self.db and self.db.api and self.db.api.results then
    table.insert(lines, string.format("Functions present: %d/%d", self.db.api.present or 0, self.db.api.total or 0))
    for _, row in ipairs(self.db.api.results) do
      table.insert(lines, string.format("%s | %s | %s", row.present and "YES" or "NO", row.path, row.note or ""))
    end
  else
    table.insert(lines, "No API probe recorded yet.")
  end

  table.insert(lines, "")
  table.insert(lines, "RECENT ADDON LOG")
  local sourceLog = (self.db and self.db.log) or self.runtimeLog
  local startAt = math.max(1, #sourceLog - 39)
  for i = startAt, #sourceLog do
    local entry = sourceLog[i]
    table.insert(lines, string.format("[%s] %s: %s", fmtTime(entry.at), tostring(entry.kind), tostring(entry.message)))
  end
  return table.concat(lines, "\n")
end

TTB.eventFrame = CreateFrame("Frame")
TTB.eventFrame:RegisterEvent("ADDON_LOADED")
TTB.eventFrame:RegisterEvent("PLAYER_LOGIN")
TTB.eventFrame:SetScript("OnEvent", function(_, eventName, ...)
  if eventName == "ADDON_LOADED" then
    local loadedName = ...
    if loadedName ~= TTB.name then return end
    TTB:InitializeDatabase()
    TTB:Log("INIT", "Loaded v" .. TTB.version .. " in SAFE MODE")
    return
  elseif eventName == "PLAYER_LOGIN" then
    if not TTB.db then TTB:InitializeDatabase() end
    if TTB.RunAPIProbe then TTB:RunAPIProbe() end
    if TTB.InitializeUI then TTB:InitializeUI() end
    TTB:Print("loaded. /ttb opens Taliaa Trade. Market analysis only; buying/posting/canceling remain disabled.")
  end

  local eventArgs = { ... }
  TTB:RecordObservedEvent(eventName, unpack(eventArgs))
  local handlers = TTB.eventHandlers[eventName]
  if handlers then
    for _, handler in ipairs(handlers) do
      local ok, err = xpcall(function() handler(TTB, eventName, unpack(eventArgs)) end, function(e)
        return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 6, 6)) or "")
      end)
      if not ok then TTB:Log("ERROR", eventName .. " handler: " .. tostring(err)) end
    end
  end
end)

SLASH_TALIAATRADEBETA1 = "/ttb"
SLASH_TALIAATRADEBETA2 = "/ttradebeta"
SlashCmdList.TALIAATRADEBETA = function(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local lower = string.lower(msg)
  local itemArg = string.match(lower, "^item%s+(%d+)$")
  if lower == "report" then
    if TTB.ShowReport then TTB:ShowReport() end
  elseif lower == "probe" then
    if TTB.RunAPIProbe then TTB:RunAPIProbe(); TTB:Print("API probe refreshed.") end
  elseif lower == "scan" then
    if TTB.RequestFreshScan then TTB:RequestFreshScan() end
  elseif lower == "cached" then
    if TTB.AnalyzeCachedSnapshot then TTB:AnalyzeCachedSnapshot() end
  elseif lower == "top" then
    if TTB.SetView then TTB:SetView("opportunities") end
  elseif lower == "db" then
    if TTB.SetView then TTB:SetView("database") end
  elseif lower == "diag" then
    if TTB.SetView then TTB:SetView("diagnostics") end
  elseif itemArg then
    if TTB.ShowItemDetail then TTB:ShowItemDetail(tonumber(itemArg)) end
  else
    if TTB.ToggleUI then TTB:ToggleUI() else TTB:Print("UI not initialized yet.") end
  end
end
