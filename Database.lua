local _,M=...
M.defaults={safeMode=true,debug=false,maxTransaction=100000,maxItemSpend=500000,maxQuantity=20,
 maxExposure=2000000,minProfit=100,minROI=0.20,minConfidence=42,minLiquidity=15,
 riskTolerance=0.35,ahCut=0.05,depositReserve=100,maxDataAge=7200,historyDays=90,filter='',sort='score'}
function M:InitializeDatabase()
  if type(VoidMarkMarketDB)~='table' then VoidMarkMarketDB={} end
  local root=VoidMarkMarketDB
  if (tonumber(root.schemaVersion) or 0)>1 then
    self.persistenceBlocked=true; root={} -- analyze only in memory; leave newer saved schema untouched
    self:Print('Saved data was created by a newer addon. This session is read-only; update before trading.')
  end
  self.root=root
  self.loadedSavedMarker=type(root.persistenceMarker)=='table'
  root.persistenceMarker=root.persistenceMarker or {createdAt=time(),version=self.version}
  root.settings=type(root.settings)=='table' and root.settings or {}
  for k,v in pairs(self.defaults) do
    if type(root.settings[k])~=type(v) then root.settings[k]=v end
    if type(v)=='number' and (root.settings[k]~=root.settings[k] or root.settings[k]<0 or root.settings[k]>1e12) then root.settings[k]=v end
  end
  -- Every login starts safe. Trading must be enabled deliberately in Settings.
  root.settings.safeMode=true; self.safeMode=true
  root.settings.ahCut=math.min(0.30,root.settings.ahCut)
  root.settings.riskTolerance=math.min(2,root.settings.riskTolerance)
  root.economies=type(root.economies)=='table' and root.economies or {}
  local realm=GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName()
  local faction=UnitFactionGroup('player') or 'Unknown'
  self.economyID=tostring(realm)..'|'..faction
  self.characterID=(UnitName('player') or 'Unknown')..'|'..tostring(realm)
  local db=root.economies[self.economyID]
  if type(db)~='table' then db={}; root.economies[self.economyID]=db end
  self.db=db; db.settings=root.settings
  for _,k in ipairs({'market','scans','queries','ownedQueries','opportunities','ledger','inventory','mailSeen','pending','totals'}) do
    if type(db[k])~='table' then db[k]={} end
  end
  db.scanSequence=tonumber(db.scanSequence) or 0; db.ledgerSequence=tonumber(db.ledgerSequence) or 0
  -- Keep the legacy global declared in the TOC. User imports it once as documented.
  -- Adopt existing records by reference, without deleting/rewriting the old root.
  if type(TaliaaTradeBetaDB)=='table' and not root.legacyImported then
    local legacy=TaliaaTradeBetaDB
    if type(legacy.market)=='table' then
      for k,m in pairs(legacy.market) do if type(m)=='table' and not db.market[k] then db.market[k]=m end end
    end
    db.scanSequence=math.max(db.scanSequence,tonumber(legacy.scanSequence) or 0)
    db.lastFreshScanRequestAt=legacy.lastFreshScanRequestAt
    db.latestScan=db.latestScan or legacy.latestScan
    root.legacyImported={at=time(),economy=self.economyID,schema=legacy.schemaVersion}
  end
  db.currentBuild=self:GetBuildSnapshot()
  root.schemaVersion=1; db.schemaVersion=1
  self.exposureDirty=true
  self:RebuildIndexes()
  -- Pending spend is persistent. Reload/close never changes an uncertain purchase to failed.
  for _,p in pairs(db.pending) do
    if type(p)=='table' then
      if p.status=='pending' then p.status='unknown' end
      -- SavedVariables may serialize aliases as independent copies. Canonicalize
      -- unresolved orders by ID so the visible ledger receives later resolutions.
      for i,e in ipairs(db.ledger) do if type(e)=='table' and e.id==p.id then db.ledger[i]=p; break end end
    end
  end
  self:RebuildOpportunities()
end
function M:RebuildIndexes()
  self.marketIndex={}; self.itemIndex={}; self.nameIndex={}; local cursor=nil
  self:AddJob('index',function(start)
    for i=1,40 do
      local k,m=next(self.db.market,cursor); cursor=k
      if k==nil then return true end
      if type(m)=='table' and tonumber(m.itemID) and type(m.latest)=='table' and type(m.history or {})=='table' then
        m.history=m.history or {}; self.marketIndex[#self.marketIndex+1]=k
        self.itemIndex[m.itemID]=self.itemIndex[m.itemID] or {}; table.insert(self.itemIndex[m.itemID],k)
        if m.name then if self.nameIndex[m.name]==nil then self.nameIndex[m.name]=k else self.nameIndex[m.name]=false end end
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end,function() self:RebuildOpportunities(); self:RefreshUI() end)
end
function M:GetMarket(itemID)
  local keys=self.itemIndex[tonumber(itemID)] or {}; local best
  for _,k in ipairs(keys) do local m=self.db.market[k]; if not best or (m.lastSeen or 0)>(best.lastSeen or 0) then best=m end end
  return best
end
function M:GetMarketVariants(itemID)
  local out={}; for _,k in ipairs(self.itemIndex[tonumber(itemID)] or {}) do out[#out+1]=self.db.market[k] end; return out
end
function M:PruneDatabase()
  local cursor=nil; local cutoff=time()-self.db.settings.historyDays*86400
  self:AddJob('prune',function(start)
    for i=1,40 do
      local k,m=next(self.db.market,cursor); cursor=k; if k==nil then return true end
      if type(m)=='table' and type(m.history)=='table' then
        while #m.history>1 and type(m.history[1])=='table' and (tonumber(m.history[1].at) or 0)<cutoff do table.remove(m.history,1) end
        -- Retain the last useful price and aggregate history even for absent markets.
        if (tonumber(m.lastSeen) or 0)<cutoff then m.archived=true end
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end)
end
