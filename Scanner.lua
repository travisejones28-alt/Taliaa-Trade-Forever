local _,M=...
-- Diagnostics contain only serializable values. Runtime request correlation never survives /reload.
local function replicateCount()
  local fn=C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems
  if type(fn)~='function' then return nil,'replicate count API unavailable' end
  local ok,n=pcall(fn)
  if not ok then return nil,'replicate count API error: '..tostring(n) end
  n=tonumber(n)
  if not n or n<0 or n%1~=0 or n==math.huge then return nil,'invalid replicate count' end
  return n
end
function M:FullScanSent(r)
  self.queue.lateReplicate=nil
  local d=r.diagnostic; if not d then return end
  d.sentAt=time(); d.phase='waiting'; d.baselineRows,d.baselineError=replicateCount()
  self.scanState.phase='waiting'; self:SetScanStatus('Full scan sent; waiting for replicate event (60s + late-response grace)',0)
  self:Log('FULL SCAN','Request #'..r.token..' sent via C_AuctionHouse.ReplicateItems; cached rows='..tostring(d.baselineRows))
end
function M:FullScanSlow(r)
  local d=r.diagnostic; if d then d.slowAt=time(); d.phase='waiting-late' end
  self.scanState.phase='waiting-late'; self:SetScanStatus('Full scan slow after 60s; still listening until 180s (no retry)',0)
  self:Log('FULL SCAN','60s response timeout; request retained for late response, not resent')
end
function M:FullScanTimeoutReason(r)
  local d=r.diagnostic
  if d and (d.replicateEvents or 0)>0 then
    return 'Full scan: replicate event received, but '..tostring(d.lastCountError or 'only empty results')..'; listening for late response'
  elseif d and (d.legacyEvents or 0)>0 then
    return 'Full scan: legacy list events only; no replicate response after 180s; listening for late response'
  end
  return 'Full scan: no replicate response after 180s; listening for late response'
end
function M:RequestFreshScan()
  if self.scanState.running then self:Print('Scan already running'); return end
  if not self:CanUseAuctionHouse() then self:Print('Open the Auction House first'); return end
  if self:GetSecondsUntilFreshScanAllowed()>0 then self:Print('Full scan cooldown: '..self:FormatDuration(self:GetSecondsUntilFreshScanAllowed())); return end
  self.queue.lateReplicate=nil -- a new request supersedes any abandoned correlation before it is sent
  local d={queuedAt=time(),phase='queued',api='C_AuctionHouse.ReplicateItems',eventCount=0,replicateEvents=0,legacyEvents=0,events={}}
  self.db.fullScanDiagnostic=d; self.scanState.fullScanDiagnostic=d
  self.scanState.running=true; self.scanState.phase='waiting'; self.scanState.requestedAt=time()
  self:SetScanStatus('Queued fresh replicate scan',0)
  self:QueueRequest({id='replicate',kind='replicate',priority=5,diagnostic=d,
    done=function(n) M:StartSnapshotProcessing(n,'fresh replicate request',d) end,
    fail=function(err)
      d.phase='error'; d.error=tostring(err); d.failedAt=time()
      M.scanState.running=false; M.scanState.phase='error'; M:SetScanStatus(err,0); M:Log('FULL SCAN',err)
    end})
end
function M:ObserveFullScanEvent(event)
  local q=self.queue
  local r=q.active and q.active.kind=='replicate' and q.active or q.lateReplicate
  local d=r and r.diagnostic or self.scanState.fullScanDiagnostic
  if not d or not d.sentAt or not self.ahOpen then return end
  local n,err=replicateCount()
  local e={event=event,at=time(),elapsed=r and GetTime()-r.sent or nil,replicateRows=n,countError=err}
  d.eventCount=d.eventCount+1; d.lastEvent=event; d.lastEventAt=e.at
  if event=='REPLICATE_ITEM_LIST_UPDATE' then
    d.replicateEvents=d.replicateEvents+1; d.lastReplicateRows=n; d.lastCountError=err
  else
    d.legacyEvents=d.legacyEvents+1
    if type(GetNumAuctionItems)=='function' then
      local ok,batch,total=pcall(GetNumAuctionItems,'list')
      if ok then e.listRows=tonumber(batch); e.listTotal=tonumber(total) else e.listError=tostring(batch) end
    end
  end
  -- Legacy pages are observations only: this scanner requested a modern replicate dataset.
  if event~='REPLICATE_ITEM_LIST_UPDATE' then e.disposition='legacy list/page; not a replicate response'
  elseif not r then e.disposition='no pending full scan; ignored duplicate/unsolicited event'
  elseif not n then e.disposition='invalid count; keep waiting'
  elseif n==0 then e.disposition='empty replicate response; keep waiting'
  else e.disposition=q.lateReplicate==r and 'recovered late replicate response' or 'accepted replicate response' end
  d.events[#d.events+1]=e; if #d.events>24 then table.remove(d.events,1) end
  self:Log('FULL SCAN EVENT',event..' at '..tostring(e.at)..' (+'..tostring(e.elapsed)..'s): replicate='..tostring(n)..
    ', list='..tostring(e.listRows)..'/'..tostring(e.listTotal)..'; '..e.disposition..(err and '; '..err or ''))
  if event~='REPLICATE_ITEM_LIST_UPDATE' or not r or not n or n==0 then return end
  d.responseAt=e.at; d.responseSeconds=e.elapsed; d.responseRows=n; d.phase='received'; d.error=nil
  if q.active==r then self:FinishRequest(r,true,n)
  elseif q.lateReplicate==r and not self.scanState.running then
    q.lateReplicate=nil; d.recoveredLate=true; if r.done then r.done(n) end
  end
end
M:RegisterHandler('REPLICATE_ITEM_LIST_UPDATE',function(self,event) self:ObserveFullScanEvent(event) end)
M:RegisterHandler('AUCTION_ITEM_LIST_UPDATE',function(self,event) self:ObserveFullScanEvent(event) end)
function M:AnalyzeCachedSnapshot()
  if self.scanState.running or not self:CanUseAuctionHouse() then return end
  local ok,n=self:SafeCall('GetNumReplicateItems',C_AuctionHouse.GetNumReplicateItems)
  if ok and tonumber(n) and n>0 then
    if self.queue.lateReplicate then self.queue.lateReplicate=nil end
    self:StartSnapshotProcessing(n,'cached snapshot') else self:Print('Replicate cache is empty') end
end
function M:StartSnapshotProcessing(total,source,diagnostic)
  self.scanToken=(self.scanToken or 0)+1; local token=self.scanToken
  local s=self.scanState; s.running=true; s.phase='processing'; s.startedAt=time(); s.startedMS=debugprofilestop()
  if diagnostic then
    diagnostic.phase='processing'; diagnostic.parseStartedAt=time()
    self:Log('FULL SCAN','Parsing started: '..total..' replicate rows')
  end
  local summary={source=source,requestedAt=s.requestedAt,startedAt=time(),rawRows=total,auctionsProcessed=0,
    totalQuantity=0,invalidRecords=0,incompleteRecords=0,variantRows=0,variantMarkets=0,uniqueItems=0,uniqueBaseItems=0,skippedMarkets=0,modelErrors=0}
  local grouped,baseSeen={},{}; local i=0
  local function addRow(index)
    -- Exact proven Forever replicate tuple from the uploaded scanner.
    local ok,name,texture,count,quality,canUse,level,levelType,minBid,minIncrement,buyout,bid,highBidder,bidder,owner,ownerFull,saleStatus,itemID,complete=
      pcall(C_AuctionHouse.GetReplicateItemInfo,index)
    itemID=tonumber(itemID); count=tonumber(count); buyout=tonumber(buyout)
    if not ok or not itemID or not count or count<1 or not buyout or buyout<=0 or (tonumber(saleStatus) or 0)~=0 then summary.invalidRecords=summary.invalidRecords+1; return end
    if not complete then summary.incompleteRecords=summary.incompleteRecords+1 end
    local link; if C_AuctionHouse.GetReplicateItemLink then local good,v=pcall(C_AuctionHouse.GetReplicateItemLink,index); if good then link=v end end
    local suffix=self:Suffix(link)
    -- No link means variant identity is uncertain. Never mix random-stat gear blindly.
    if suffix==nil then summary.incompleteRecords=summary.incompleteRecords+1; summary.invalidRecords=summary.invalidRecords+1; return end
    local key=self:Key(itemID,suffix); local unit=buyout/count
    local g=grouped[key]
    if not g then
      g={marketKey=key,itemID=itemID,itemSuffix=suffix,itemLink=link,name=name,texture=texture,quality=quality,level=level,
        listings=0,quantity=0,floorUnitPrice=unit,ceilingUnitPrice=unit,priceLevels={},tierCount=0}
      grouped[key]=g; summary.uniqueItems=summary.uniqueItems+1
      if suffix~=0 then summary.variantMarkets=summary.variantMarkets+1 end
    end
    if not baseSeen[itemID] then baseSeen[itemID]=true; summary.uniqueBaseItems=summary.uniqueBaseItems+1 end
    summary.auctionsProcessed=summary.auctionsProcessed+1; summary.totalQuantity=summary.totalQuantity+count
    if suffix~=0 then summary.variantRows=summary.variantRows+1 end
    g.name=g.name or name; g.listings=g.listings+1; g.quantity=g.quantity+count
    g.floorUnitPrice=math.min(g.floorUnitPrice,unit); g.ceilingUnitPrice=math.max(g.ceilingUnitPrice,unit)
    if g.priceLevels[unit] then g.priceLevels[unit]=g.priceLevels[unit]+count
    elseif g.tierCount<512 then g.priceLevels[unit]=count; g.tierCount=g.tierCount+1
    else g.analysisIncomplete=true end -- retain old history, block an oversized distribution
  end
  self:AddJob('scan',function(start)
    if not self.ahOpen or token~=self.scanToken then return true end
    for j=1,140 do
      if i>=total then return true end
      local ok,err=pcall(addRow,i); i=i+1
      if not ok then summary.invalidRecords=summary.invalidRecords+1; self:Log('ROW',err) end
      if debugprofilestop()-start>=4 then break end
    end
    s.processed=i; self:SetScanStatus(string.format('Scan rows %d / %d',i,total),total>0 and i/total*0.70 or 0.70)
  end,function()
    if not self.ahOpen or token~=self.scanToken then return end
    if diagnostic then
      diagnostic.parseFinishedAt=time(); diagnostic.parseMS=math.floor(debugprofilestop()-s.startedMS); diagnostic.phase='model'
      self:Log('FULL SCAN','Parsing finished: '..summary.auctionsProcessed..' valid, '..summary.invalidRecords..' invalid rows')
    end
    s.phase='model'; self:FinalizeMarketScan(grouped,summary,function()
      if token~=self.scanToken then return end
      summary.completedAt=time(); summary.processingMS=math.floor(debugprofilestop()-s.startedMS)
      if diagnostic then
        diagnostic.completedAt=time(); diagnostic.phase='done'; diagnostic.processingMS=summary.processingMS
        diagnostic.validRows=summary.auctionsProcessed; diagnostic.invalidRows=summary.invalidRecords
        diagnostic.markets=summary.uniqueItems; diagnostic.candidates=#self.db.opportunities
        summary.responseSeconds=diagnostic.responseSeconds; summary.responseAt=diagnostic.responseAt; summary.parseMS=diagnostic.parseMS
        self:Log('FULL SCAN','Completed: '..summary.uniqueItems..' markets, '..#self.db.opportunities..' candidates')
      end
      self.db.latestScan=summary; self.db.scans[#self.db.scans+1]=summary
      if #self.db.scans>20 then table.remove(self.db.scans,1) end
      if source~='cached snapshot' then self.db.lastSuccessfulScanAt=time() end
      s.running=false; s.phase='done'; self:SetScanStatus(string.format('%d valid rows | %d markets | %d candidates | %d skipped',summary.auctionsProcessed,summary.uniqueItems,#self.db.opportunities,summary.skippedMarkets),1)
      self:PruneDatabase()
    end)
  end)
end

M:RegisterHandler('AUCTION_HOUSE_CLOSED',function(self)
  local d=self.scanState.fullScanDiagnostic
  if d and d.phase~='done' then
    d.phase='aborted'; d.error='Auction House closed'; d.abortedAt=time()
    self.scanState.running=false; self.scanState.phase='aborted'; self:SetScanStatus('Auction House closed during scan',0)
  end
  self.scanState.fullScanDiagnostic=nil -- never recover a response from an earlier AH session
end)
