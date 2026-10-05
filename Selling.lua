local _,M=...
M.sellingRows={}; M.ownedRows={}
function M:RefreshInventory()
  self.sellingRows={}; if not C_Container or not C_Container.GetContainerItemInfo then return end
  local bag,slot=0,1; local rows={}
  self:AddJob('bags',function(start)
    for j=1,25 do
      if bag>4 then return true end
      local n=C_Container.GetContainerNumSlots(bag) or 0
      if slot>n then bag=bag+1; slot=1
      else
        local info=C_Container.GetContainerItemInfo(bag,slot); slot=slot+1
        if type(info)=='table' and info.itemID and not info.isBound then
          local suffix=self:Suffix(info.hyperlink)
          if suffix then
            local key=self:Key(info.itemID,suffix); local m=self.db.market[key]
            if m and m.latest then
              local minimum=math.max(m.latest.meaningfulFloor or m.latest.q10 or 0,m.fairValue*0.85)
              -- Hold the price when a lone low auction is bait. Native UI handles deposit and posting.
              local price=math.floor(math.min(m.fairValue,minimum))
              local own
              for _,r in ipairs(self.ownedRows) do if r.marketKey==key then own=not own and r.unit or math.min(own,r.unit) end end
              if own then price=math.max(price,own) end
              rows[#rows+1]={marketKey=key,name=m.name,itemID=m.itemID,quantity=info.stackCount or 1,price=price,
                fair=m.fairValue,floor=m.latest.floor,own=own,confidence=m.confidence,
                reason=own and 'Hold own price; avoid self-undercutting' or 'Meaningful floor / fair value; ignores isolated bait',
                stale=time()-(m.lastSeen or 0)>self.db.settings.maxDataAge}
            end
          end
        end
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end,function() self.sellingRows=rows; self:RefreshUI() end)
end
function M:RequestOwnedAuctionsDiagnostic()
  self:QueueRequest({id='owned',kind='owned',priority=30,done=function() M:CaptureOwnedAuctions() end,
    fail=function(e) M:Log('OWNED',e); M:Print(e) end})
end
function M:CaptureOwnedAuctions()
  local A=C_AuctionHouse; local rows={}; local n=0
  local all
  if A.GetOwnedAuctions then local ok,v=pcall(A.GetOwnedAuctions); if ok and type(v)=='table' then all=v; n=#v end end
  if not all and A.GetNumOwnedAuctions then local ok,v=pcall(A.GetNumOwnedAuctions); if ok then n=tonumber(v) or 0 end end
  local i=1
  self:AddJob('owned',function(start)
    for j=1,40 do
      if i>n then return true end
      local info=all and all[i]; if not all and A.GetOwnedAuctionInfo then local ok,v=pcall(A.GetOwnedAuctionInfo,i); if ok then info=v end end
      i=i+1
      if type(info)=='table' and type(info.itemKey)=='table' then
        local key=self:Key(info.itemKey.itemID,info.itemKey.itemSuffix,info.itemKey.itemLevel,info.itemKey.battlePetSpeciesID)
        local m=self.db.market[key]; local qty=tonumber(info.quantity) or 1
        local unit=tonumber(info.unitPrice) or (tonumber(info.buyoutAmount) or 0)/math.max(1,qty)
        rows[#rows+1]={auctionID=info.auctionID,marketKey=key,name=m and m.name or ('Item '..info.itemKey.itemID),quantity=qty,
          unit=unit,timeLeft=info.timeLeftSeconds or info.timeLeft,status=info.status,deposit=info.depositAmount,
          floor=m and m.latest and m.latest.meaningfulFloor,reason='Snapshot comparison only; refresh item before deciding'}
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end,function() self.ownedRows=rows; self:RefreshInventory(); self:RefreshUI() end)
end
function M:AnalyzeOwnedLive(row)
  local m=self.db.market[row.marketKey]; if not m then return end
  self:Search(m,60,function(result)
    local competitor=result.rows[1] and result.rows[1].unit
    row.liveAt=time(); row.competition=competitor
    if not competitor then row.reason='No competing supply; hold your auction'
    elseif competitor>=row.unit then row.reason='Your price is competitive; hold'
    else
      local reduction=(row.unit-competitor)*row.quantity
      local A=C_AuctionHouse; local cost
      if A.GetCancelCost then local ok,v=pcall(A.GetCancelCost,row.auctionID); if ok then cost=tonumber(v) end end
      row.cancelCost=cost
      row.reason=string.format('Undercut %.1f%%; repricing reduces revenue by %s. %s',100*(row.unit-competitor)/math.max(1,row.unit),self:Money(reduction),
        cost and ('Cancel fee '..self:Money(cost)..'; deposit loss '..(row.deposit and self:Money(row.deposit) or 'unknown')..'. Review demand before churn.') or 'Cancel/deposit cost unknown; hold until verified.')
    end
    self:RefreshUI()
  end,function(e) row.reason=e; self:RefreshUI() end)
end
M:RegisterHandler('BAG_UPDATE_DELAYED',function(self) self.bagsDirty=true end)
M:RegisterHandler('GET_ITEM_INFO_RECEIVED',function(self) self.bagsDirty=true end)
M:RegisterHandler('AUCTION_CANCELED',function(self,_,id)
  self:AddLedger('cancelled',{auctionID=id,status='observed',evidence='Observed AUCTION_CANCELED; lost deposit unknown'})
end)
M:RegisterHandler('AUCTION_HOUSE_AUCTION_CREATED',function(self,_,id)
  self:AddLedger('posted',{auctionID=id,status='observed',evidence='Observed creation; price/deposit captured only if supplied by client'})
end)
