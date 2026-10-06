local _,M=...
M.queue={waiting={},dedupe={},stats={sent=0,timeouts=0,retries=0,dropped=0},sequence=0,nextSend=0}
function M:ThrottleReady()
  if not self:CanUseAuctionHouse() then return false end
  local fn=C_AuctionHouse.IsThrottledMessageSystemReady
  if type(fn)~='function' then return true end
  local ok,v=pcall(fn); return ok and v==true
end
function M:QueueRequest(r)
  if not self:CanUseAuctionHouse() then if r.fail then r.fail('Auction House closed') end; return false end
  local q=self.queue
  if q.dedupe[r.id] then return false,'duplicate' end
  if #q.waiting>=100 then if r.fail then r.fail('Queue full') end; return false end
  q.sequence=q.sequence+1; r.token=q.sequence; r.priority=r.priority or 10; r.at=GetTime(); r.attempt=0
  q.dedupe[r.id]=r; q.waiting[#q.waiting+1]=r
  table.sort(q.waiting,function(a,b) if a.priority==b.priority then return a.token<b.token end; return a.priority>b.priority end)
  self:RefreshUI(); return true
end
function M:FinishRequest(r,ok,result)
  local q=self.queue; if q.active~=r then return end
  q.active=nil; q.dedupe[r.id]=nil; self:CancelJob('results')
  q.nextSend=GetTime()+0.3
  if ok then if r.done then r.done(result) end else if r.fail then r.fail(result) end end
  self:RefreshUI()
end
function M:CancelRequests(reason)
  local q=self.queue; local old=q.active; q.active=nil; q.dedupe={}
  local waiting=q.waiting; q.waiting={}; self:CancelJob('results')
  if q.lateReplicate then
    if q.lateReplicate.fail then q.lateReplicate.fail(reason) end
    q.lateReplicate=nil
  end
  if old and old.fail then old.fail(reason) end
  for _,r in ipairs(waiting) do if r.fail then r.fail(reason) end end
end
function M:SendAHRequest(r)
  local A=C_AuctionHouse
  if r.kind=='replicate' then
    self:FullScanSent(r)
    self.db.lastFreshScanRequestAt=time(); A.ReplicateItems()
  elseif r.kind=='owned' then A.QueryOwnedAuctions({})
  elseif r.kind=='browse' then A.SendBrowseQuery(r.query)
  elseif r.kind=='search' then
    local has=A.HasSearchResults and A.HasSearchResults(r.key)
    if r.more then
      if r.commodity then A.RequestMoreCommoditySearchResults(r.key.itemID) else A.RequestMoreItemSearchResults(r.key) end
    elseif has and r.commodity and A.RefreshCommoditySearchResults then A.RefreshCommoditySearchResults(r.key.itemID)
    elseif has and not r.commodity and A.RefreshItemSearchResults then A.RefreshItemSearchResults(r.key)
    elseif has then error('Fresh search refresh API missing; close and reopen AH')
    else
      local sorts={}; if Enum and Enum.AuctionHouseSortOrder then sorts={{sortOrder=Enum.AuctionHouseSortOrder.Price,reverseSort=false}} end
      A.SendSearchQuery(r.key,sorts,true)
    end
  end
end
function M:PumpQueue()
  local q=self.queue; if not self:CanUseAuctionHouse() then return end
  local r=q.active
  if r and r.kind=='replicate' then
    local elapsed=GetTime()-r.sent
    if elapsed>=180 then
      if not r.timedOut then r.timedOut=true; q.stats.timeouts=q.stats.timeouts+1 end
      q.lateReplicate=r -- keep correlation until AH close, cached analysis or a new full scan
      self:FinishRequest(r,false,self:FullScanTimeoutReason(r)); return
    elseif elapsed>=r.timeout and not r.timedOut then
      r.timedOut=true; q.stats.timeouts=q.stats.timeouts+1
      self:FullScanSlow(r)
    end
  elseif r and GetTime()-r.at>90 then self:FinishRequest(r,false,'Request total deadline exceeded'); return
  elseif r and GetTime()-r.sent>r.timeout then
    q.stats.timeouts=q.stats.timeouts+1
    if r.kind~='replicate' and r.attempt<2 and not r.reading then
      r.attempt=r.attempt+1; r.sent=GetTime(); r.resend=true; q.stats.retries=q.stats.retries+1
    else self:FinishRequest(r,false,'Request timed out; no fresh response'); return end
  end
  if self.execution and (self.execution.state=='quoting' or self.execution.state=='quoted' or self.execution.state=='pending') then return end
  if r then
    if r.resend and self:ThrottleReady() then
      r.resend=nil; local ok,err=pcall(self.SendAHRequest,self,r)
      if not ok then self:FinishRequest(r,false,tostring(err)) end
    end
    return
  end
  if GetTime()<q.nextSend or not self:ThrottleReady() then return end
  while q.waiting[1] do
    r=table.remove(q.waiting,1)
    if r.valid and not r.valid() or GetTime()-r.at>120 then
      q.dedupe[r.id]=nil; if r.fail then r.fail('Stale request cancelled') end
    else break end
    r=nil
  end
  if not r then return end
  q.active=r; r.sent=GetTime(); r.timeout=r.kind=='replicate' and 60 or 15; r.attempt=1
  local ok,err=pcall(self.SendAHRequest,self,r)
  if not ok then self:FinishRequest(r,false,tostring(err)) else q.stats.sent=q.stats.sent+1 end
end
function M:Search(m,priority,done,fail,valid)
  local key=self:ItemKey(m); local commodity=self:IsCommodity(key)
  if commodity==nil then if fail then fail('Commodity classification unavailable; wait for item data') end; return false end
  return self:QueueRequest({id='search:'..tostring(self:Key(key.itemID,key.itemSuffix,key.itemLevel,key.battlePetSpeciesID)),kind='search',
    key=key,commodity=commodity,priority=priority,done=done,fail=fail,valid=valid})
end
function M:ReadSearch(event,key)
  local r=self.queue.active
  if not r or r.kind~='search' or r.resend then return end
  if r.commodity then if tonumber(key)~=r.key.itemID then return end
  elseif not self:SameKey(key,r.key) then return end
  -- UPDATED/ADDED may arrive repeatedly. Restart only this request's bounded reader.
  r.reading=true
  local A=C_AuctionHouse; local arg=r.commodity and r.key.itemID or r.key
  local fullFn=r.commodity and A.HasFullCommoditySearchResults or A.HasFullItemSearchResults
  if type(fullFn)~='function' then self:FinishRequest(r,false,'Cannot verify complete search results'); return end
  local ok,full=pcall(fullFn,arg)
  if not ok then self:FinishRequest(r,false,'Full-results API failed'); return end
  if not full then
    r.reading=false; r.more=true; r.resend=true; r.sent=GetTime(); r.pages=(r.pages or 0)+1
    if r.pages>30 then self:FinishRequest(r,false,'Pagination limit; incomplete results cannot execute'); return end
    local more=r.commodity and A.RequestMoreCommoditySearchResults or A.RequestMoreItemSearchResults
    if type(more)~='function' then self:FinishRequest(r,false,'Search incomplete and pagination unavailable') end
    return
  end
  r.more=nil
  local countFn=r.commodity and A.GetNumCommoditySearchResults or A.GetNumItemSearchResults
  local infoFn=r.commodity and A.GetCommoditySearchResultInfo or A.GetItemSearchResultInfo
  local good,n=pcall(countFn,arg)
  if not good or not tonumber(n) then self:FinishRequest(r,false,'Invalid search count'); return end
  if n>1000 then self:FinishRequest(r,false,'More than 1,000 live tiers/listings; execution paused to protect frame budget'); return end
  local result={key=r.key,commodity=r.commodity,rows={},at=time(),received=GetTime(),full=true}; local i=1
  self:AddJob('results',function(start)
    if self.queue.active~=r then return true end
    for j=1,70 do
      if i>n then return true end
      local valid,info=pcall(infoFn,arg,i); i=i+1
      if not valid or type(info)~='table' then result.incomplete=true
      else
        local qty=r.commodity and tonumber(info.quantity) or self:RegularQuantity(info,r.key.itemID); local total=tonumber(info.buyoutAmount)
        local unit=r.commodity and tonumber(info.unitPrice) or (total and qty and qty>0 and total/qty)
        local own=tonumber(info.numOwnerItems) or 0
        if r.commodity and info.containsOwnerItem and info.numOwnerItems==nil then qty=0 end
        if r.commodity then qty=qty and math.max(0,qty-own) end
        if unit and unit>0 and qty and qty>0 and (r.commodity or (info.auctionID and not info.isOwnerItem and not info.containsOwnerItem and (not info.itemKey or self:SameKey(info.itemKey,r.key)))) then
          result.rows[#result.rows+1]={unit=unit,quantity=qty,total=r.commodity and unit*qty or total,auctionID=info.auctionID,itemLink=info.itemLink}
        end
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end,function()
    if self.queue.active~=r then return end
    if result.incomplete then self:FinishRequest(r,false,'Incomplete search rows; revalidate again'); return end
    table.sort(result.rows,function(a,b) return a.unit<b.unit end)
    self:FinishRequest(r,true,result)
  end)
end
for _,event in ipairs({'ITEM_SEARCH_RESULTS_UPDATED','ITEM_SEARCH_RESULTS_ADDED','COMMODITY_SEARCH_RESULTS_UPDATED','COMMODITY_SEARCH_RESULTS_ADDED'}) do
  M:RegisterHandler(event,function(self,e,key) self:ReadSearch(e,key) end)
end
M:RegisterHandler('OWNED_AUCTIONS_UPDATED',function(self)
  local r=self.queue.active; if r and r.kind=='owned' then self:FinishRequest(r,true,true) end
end)
M:RegisterHandler('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED',function(self)
  local r=self.queue.active; if r and r.kind=='browse' then self:FinishRequest(r,true,true) end
end)
M:RegisterHandler('AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED',function(self)
  self.queue.stats.dropped=self.queue.stats.dropped+1
  local r=self.queue.active; if r then self:FinishRequest(r,false,'AH throttle dropped request') end
end)
M:RegisterHandler('AUCTION_HOUSE_CLOSED',function(self) self:CancelRequests('Auction House closed'); self.scanToken=(self.scanToken or 0)+1; self:CancelJob('scan'); self:CancelJob('model'); self:CancelJob('scan-finish') end)
