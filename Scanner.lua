local _,M=...
function M:RequestFreshScan()
  if self.scanState.running then self:Print('Scan already running'); return end
  if not self:CanUseAuctionHouse() then self:Print('Open the Auction House first'); return end
  if self:GetSecondsUntilFreshScanAllowed()>0 then self:Print('Full scan cooldown: '..self:FormatDuration(self:GetSecondsUntilFreshScanAllowed())); return end
  self.scanState.running=true; self.scanState.phase='waiting'; self.scanState.requestedAt=time()
  self:SetScanStatus('Queued fresh replicate scan',0)
  self:QueueRequest({id='replicate',kind='replicate',priority=5,done=function(n) M:StartSnapshotProcessing(n,'fresh replicate request') end,
    fail=function(err) M.scanState.running=false; M.scanState.phase='error'; M:SetScanStatus(err,0) end})
end
function M:AnalyzeCachedSnapshot()
  if self.scanState.running or not self:CanUseAuctionHouse() then return end
  local ok,n=self:SafeCall('GetNumReplicateItems',C_AuctionHouse.GetNumReplicateItems)
  if ok and tonumber(n) and n>0 then self:StartSnapshotProcessing(n,'cached snapshot') else self:Print('Replicate cache is empty') end
end
function M:StartSnapshotProcessing(total,source)
  self.scanToken=(self.scanToken or 0)+1; local token=self.scanToken
  local s=self.scanState; s.running=true; s.phase='processing'; s.startedAt=time(); s.startedMS=debugprofilestop()
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
    s.phase='model'; self:FinalizeMarketScan(grouped,summary,function()
      if token~=self.scanToken then return end
      summary.completedAt=time(); summary.processingMS=math.floor(debugprofilestop()-s.startedMS)
      self.db.latestScan=summary; self.db.scans[#self.db.scans+1]=summary
      if #self.db.scans>20 then table.remove(self.db.scans,1) end
      if source~='cached snapshot' then self.db.lastSuccessfulScanAt=time() end
      s.running=false; s.phase='done'; self:SetScanStatus(string.format('%d valid rows | %d markets | %d candidates | %d skipped',summary.auctionsProcessed,summary.uniqueItems,#self.db.opportunities,summary.skippedMarkets),1)
      self:PruneDatabase()
    end)
  end)
end
