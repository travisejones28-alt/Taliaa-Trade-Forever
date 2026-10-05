local _,M=...
M.execution={state='idle',message='Select an opportunity and revalidate'}
function M:HasUnresolvedPurchase()
  for _,p in pairs(self.db.pending) do if p.character==self.characterID then return true end end
  return false
end
function M:SelectOpportunity(o)
  if self:HasUnresolvedPurchase() or self.execution.state=='quoting' or self.execution.state=='quoted' then self:Print('Resolve the current transaction first'); return end
  self.executionToken=(self.executionToken or 0)+1
  self.execution={state='selected',opportunity=o,market=self.db.market[o.marketKey],token=self.executionToken,message='Snapshot estimate; click REVALIDATE'}
  self:SetView('execution')
end
function M:RevalidateSelected(quantity)
  local x=self.execution; if not x.market or self:HasUnresolvedPurchase() or x.state=='quoting' or x.state=='quoted' or x.state=='validating' then return end
  quantity=math.max(1,math.floor(tonumber(quantity) or 1)); quantity=math.min(quantity,self.db.settings.maxQuantity)
  if quantity<1 then x.message='Quantity limit is zero'; self:RefreshUI(); return end
  x.state='validating'; x.message='Waiting for fresh complete search results'; x.live=nil
  local requested=x
  self:Search(x.market,100,function(result)
    if M.execution~=requested then return end
    if not result.rows[1] then x.state='invalid'; x.message='No buyable auctions remain'; M:RefreshUI(); return end
    x.commodity=result.commodity
    local live={quantity=0,cost=0,received=result.received,at=result.at}
    if result.commodity then
      local left=quantity
      for _,r in ipairs(result.rows) do
        local take=math.min(left,r.quantity); live.quantity=live.quantity+take; live.cost=live.cost+take*r.unit; left=left-take
        if left==0 then break end
      end
      if left>0 then x.state='invalid'; x.message='Requested quantity no longer available'; M:RefreshUI(); return end
    else
      -- One click purchases exactly one complete auction, never an automatic loop.
      local best
      for _,r in ipairs(result.rows) do
        if r.quantity<=quantity and r.auctionID then best=r; break end
      end
      if not best then x.state='invalid'; x.message='No whole auction fits quantity limit'; M:RefreshUI(); return end
      live.quantity=best.quantity; live.cost=best.total; live.auctionID=best.auctionID
    end
    local vendor=x.opportunity.kind=='vendor'
    if vendor and GetItemInfo then
      local _,_,_,_,_,_,_,_,_,_,value=GetItemInfo(x.market.itemLink or x.market.itemID)
      x.market.vendorPrice=tonumber(value) or 0
    end
    live.economics=M:Economics(x.market,live.cost,live.quantity,x.opportunity.kind)
    local pass,why=M:CheckRisk(x.market,live.economics)
    live.blocks=why; x.live=live; x.state=pass and 'ready' or 'invalid'
    x.message=pass and 'Fresh market validated; one transaction requires one click' or table.concat(why,'; ')
    M:RefreshUI()
  end,function(err) if M.execution==requested then x.state='invalid'; x.message=err; M:RefreshUI() end end,
    function() return M.execution==requested and requested.state=='validating' end)
  self:RefreshUI()
end
function M:ExecuteClicked()
  -- Called only by the EXECUTE button OnClick. No timer/event invokes this function.
  local x=self.execution
  if self.persistenceBlocked then self:Print('Database schema is newer than this addon; trading blocked'); return end
  if x.commodity and (self.db.quoteGuardUntil or 0)>time() then self:Print('Commodity guard: wait '..self:FormatDuration(self.db.quoteGuardUntil-time())); return end
  if self.db.settings.safeMode then self:Print('SAFE MODE: transaction blocked'); return end
  if not self:CanUseAuctionHouse() or not self:ThrottleReady() or self:HasUnresolvedPurchase() or x.state~='ready' or not x.live then return end
  if GetTime()-x.live.received>10 then x.state='stale'; x.message='Live prices expired; revalidate'; self:RefreshUI(); return end
  local pass,why=self:CheckRisk(x.market,x.live.economics)
  if not pass then x.state='invalid'; x.message=table.concat(why,'; '); self:RefreshUI(); return end
  local fn=x.commodity and C_AuctionHouse.StartCommoditiesPurchase or C_AuctionHouse.PlaceBid
  if type(fn)~='function' then x.state='invalid'; x.message='Purchase API unavailable'; self:RefreshUI(); return end
  if x.commodity and type(C_AuctionHouse.ConfirmCommoditiesPurchase)~='function' then x.state='invalid'; x.message='Confirmation API unavailable'; return end
  x.sent=GetTime()
  if x.commodity then
    x.state='quoting'; x.message='Waiting for quote; confirmation needs a second click'
    local ok,err=pcall(fn,x.market.itemID,x.live.quantity)
    if not ok then x.state='invalid'; x.message=tostring(err) end
  else
    self:ReservePurchase(x); x.state='pending'; x.message='Waiting for auction purchase result'
    local ok,err=pcall(fn,x.live.auctionID,x.live.cost)
    if not ok then self:ResolvePurchase(x.order,'failed','API rejected request: '..tostring(err)); x.state='invalid'; x.message=tostring(err) end
  end
  self:RefreshUI()
end
function M:ConfirmClicked()
  -- Called only by CONFIRM QUOTE OnClick. Events never confirm automatically.
  local x=self.execution
  if self.persistenceBlocked or self.db.settings.safeMode or not self:CanUseAuctionHouse() or x.state~='quoted' then return end
  if GetTime()-x.quotedAt>5 then self:InvalidateQuote('Quote expired; revalidate'); return end
  if not self:ThrottleReady() then return end
  local pass,why=self:CheckRisk(x.market,x.live.economics)
  if not pass then self:InvalidateQuote(table.concat(why,'; ')); return end
  self:ReservePurchase(x); x.state='pending'; x.sent=GetTime(); x.message='Waiting for commodity result'
  local ok,err=pcall(C_AuctionHouse.ConfirmCommoditiesPurchase,x.market.itemID,x.live.quantity)
  if not ok then self:ResolvePurchase(x.order,'failed','Confirmation API rejected: '..tostring(err)); self:InvalidateQuote(tostring(err)) end
  self:RefreshUI()
end
function M:InvalidateQuote(reason)
  local x=self.execution
  if x.state=='quoting' or x.state=='quoted' then
    self.db.quoteGuardUntil=time()+10
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
  end
  x.state='invalid'; x.message=reason; self:RefreshUI()
end
function M:ExecutionTick()
  local x=self.execution
  if x.state=='ready' and GetTime()-x.live.received>10 then x.state='stale'; x.message='Live prices expired; revalidate'; self:RefreshUI()
  elseif x.state=='quoting' and GetTime()-x.sent>3 then self:InvalidateQuote('Quote request timed out')
  elseif x.state=='quoted' and GetTime()-x.quotedAt>5 then self:InvalidateQuote('Quote expired')
  elseif x.state=='pending' and GetTime()-x.sent>15 then
    x.order.status='unknown'; x.order.evidence='Request sent, result not received'; x.state='unknown'
    x.message='Result uncertain; gold stays reserved. Check mailbox and reconcile in Ledger.'; self:RefreshUI()
  end
end
M:RegisterHandler('COMMODITY_PRICE_UPDATED',function(self,_,unit,total)
  local x=self.execution; if x.state~='quoting' or GetTime()-x.sent>3 then return end
  unit=tonumber(unit); total=tonumber(total)
  if not unit or unit<=0 or not total or total<=0 or total>x.live.cost then
    self:InvalidateQuote('Price/quantity changed or invalid quote; revalidate'); return
  end
  x.live.cost=total; x.live.economics=self:Economics(x.market,total,x.live.quantity,x.opportunity.kind)
  if not self:ThrottleReady() then return end
  local pass,why=self:CheckRisk(x.market,x.live.economics)
  if not pass then self:InvalidateQuote(table.concat(why,'; ')); return end
  x.state='quoted'; x.quotedAt=GetTime(); x.message='Quote '..self:Money(total)..'; click CONFIRM QUOTE within 5 seconds'; self:RefreshUI()
end)
M:RegisterHandler('COMMODITY_PRICE_UNAVAILABLE',function(self)
  local x=self.execution; if x.state=='quoting' or x.state=='quoted' then self:InvalidateQuote('Commodity price unavailable') end
end)
M:RegisterHandler('COMMODITY_PURCHASE_SUCCEEDED',function(self)
  local x=self.execution
  if x.order and x.commodity and (x.state=='pending' or x.state=='unknown') then
    self:ResolvePurchase(x.order,'confirmed','Observed COMMODITY_PURCHASE_SUCCEEDED'); x.state='complete'; x.message='Purchase confirmed'; self:RefreshUI()
  end
end)
M:RegisterHandler('COMMODITY_PURCHASE_FAILED',function(self)
  local x=self.execution
  if x.order and x.commodity and (x.state=='pending' or x.state=='unknown') then
    self:ResolvePurchase(x.order,'failed','Observed COMMODITY_PURCHASE_FAILED'); x.state='failed'; x.message='Purchase failed'; self:RefreshUI()
  elseif x.state=='quoting' or x.state=='quoted' then self:InvalidateQuote('Commodity request failed') end
end)
M:RegisterHandler('AUCTION_HOUSE_PURCHASE_COMPLETED',function(self,_,id)
  for _,p in pairs(self.db.pending) do
    if not p.commodity and p.auctionID==id and p.character==self.characterID then
      self:ResolvePurchase(p,'confirmed','Observed purchase completed for matching auction ID')
      if self.execution.order==p then self.execution.state='complete'; self.execution.message='Purchase confirmed' end
      break
    end
  end
end)
M:RegisterHandler('AUCTION_HOUSE_CLOSED',function(self)
  local x=self.execution
  if x.state=='pending' then x.order.status='unknown'; x.state='unknown'; x.message='AH closed before result; spend remains reserved'
  elseif x.state=='quoting' or x.state=='quoted' then self:InvalidateQuote('AH closed; quote discarded')
  elseif x.state~='complete' and x.state~='unknown' then x.state='stale'; x.message='AH closed; revalidate after reopening' end
  self:RefreshUI()
end)

M:RegisterHandler('AUCTION_HOUSE_SHOW_ERROR',function(self,_,code)
  self:Log('AH ERROR',tostring(code))
  local x=self.execution
  if x.state=='quoting' or x.state=='quoted' then self:InvalidateQuote('AH error: '..tostring(code))
  elseif x.state=='pending' then
    x.order.status='unknown'; x.order.evidence='AH error; transaction outcome uncertain'
    x.state='unknown'; x.message='AH error; check mailbox and reconcile outcome'
  end
  local r=self.queue.active; if r then self:FinishRequest(r,false,'AH error '..tostring(code)) end
  self:RefreshUI()
end)
