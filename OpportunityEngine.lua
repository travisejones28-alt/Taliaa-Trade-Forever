local _,M=...
function M:Economics(m,cost,qty,kind)
  local settings=self.db.settings; local vendor=kind=='vendor'
  local gross=math.floor((vendor and (m.vendorPrice or 0) or (m.fairValue or 0))*qty)
  local fee=vendor and 0 or math.ceil(gross*settings.ahCut)
  local deposits=vendor and 0 or settings.depositReserve*qty -- conservative allowance, not an actual quote
  local net=gross-fee-deposits-cost
  return {cost=cost,quantity=qty,gross=gross,fee=fee,depositReserve=deposits,net=net,roi=cost>0 and net/cost or 0,
    discount=(m.fairValue or 0)>0 and 1-cost/qty/m.fairValue or 0,kind=kind or 'resale'}
end
function M:InventoryKey(k) return self.characterID..'/'..tostring(k) end
function M:Exposure(k)
  local c=self.exposureCache
  if not c or self.exposureDirty or c.inventory~=self.db.inventory or c.pending~=self.db.pending then
    c={total=0,reserved=0,items={},inventory=self.db.inventory,pending=self.db.pending}
    for _,lot in pairs(self.db.inventory) do
      if lot.character==self.characterID then
        c.total=c.total+(lot.cost or 0); local key=lot.marketKey
        c.items[key]=(c.items[key] or 0)+(lot.cost or 0)
      end
    end
    for _,p in pairs(self.db.pending) do
      if p.character==self.characterID and (p.status=='pending' or p.status=='unknown') then
        c.reserved=c.reserved+p.cost; c.total=c.total+p.cost
        c.items[p.marketKey]=(c.items[p.marketKey] or 0)+p.cost
      end
    end
    self.exposureCache=c; self.exposureDirty=false
  end
  return c.total,c.items[k] or 0,c.reserved
end
function M:CheckRisk(m,e,exclude)
  local s=self.db.settings; local why={}; local total,item,reserved=self:Exposure(m.marketKey)
  if exclude then total=total-exclude.cost; item=item-exclude.cost; reserved=reserved-exclude.cost end
  local function check(ok,msg) if not ok then why[#why+1]=msg end end
  check(not self.persistenceBlocked,'Newer database schema; upgrade addon before trading')
  check(e.cost>0 and e.quantity>0,'Invalid transaction')
  check(e.cost<=s.maxTransaction,'Transaction spend limit')
  check(item+e.cost<=s.maxItemSpend,'Item exposure limit')
  check(total+e.cost<=s.maxExposure,'Portfolio exposure limit')
  check(e.quantity<=s.maxQuantity,'Quantity limit')
  check(not GetMoney or e.cost<=GetMoney()-reserved,'Available gold after pending reservations')
  check(e.net>=s.minProfit,'Minimum expected profit')
  check(e.roi>=s.minROI,'Minimum ROI')
  check(not m.analysisIncomplete,'Incomplete market analysis')
  if e.kind~='vendor' then
    check((m.observations or 0)>=3,'Three independent observations required')
    check((m.confidenceScore or 0)>=s.minConfidence,'Minimum confidence')
    check((m.activityScore or 0)>=s.minLiquidity,'Minimum inferred liquidity')
    check((m.volatility or 0)<=s.riskTolerance,'Volatility exceeds risk tolerance')
    check(time()-(m.lastSeen or 0)<=s.maxDataAge,'Market model is stale')
  else check((m.vendorPrice or 0)>0,'Vendor value unavailable') end
  return #why==0,why
end
function M:MakeOpportunity(m)
  if not m.latest or not m.fairValue or m.archived or m.analysisIncomplete then return nil end
  local ask=m.latest.floor or 0; if ask<=0 then return nil end
  local kind=(m.vendorPrice or 0)>ask and 'vendor' or 'resale'
  local e=self:Economics(m,ask,1,kind)
  if e.net<=0 or (kind=='resale' and e.discount<0.12) then return nil end
  local pass,why=self:CheckRisk(m,e)
  local parts={profit=math.min(25,math.log(1+math.max(0,e.net)/100)*4),roi=math.min(18,math.max(0,e.roi)*10),
    confidence=(m.confidenceScore or 0)*0.20,liquidity=(m.activityScore or 0)*0.16,
    depth=math.min(10,math.log(1+(m.latest.listings or 0))*2),risk=math.min(25,(m.volatility or 0)*35),
    exposure=math.min(12,ask/math.max(1,self.db.settings.maxTransaction)*12)}
  local score=kind=='vendor' and math.min(100,70+parts.profit+parts.roi) or math.max(0,math.min(100,parts.profit+parts.roi+parts.confidence+parts.liquidity+parts.depth-parts.risk-parts.exposure))
  return {marketKey=m.marketKey,itemID=m.itemID,itemSuffix=m.itemSuffix,name=m.name,floor=ask,fairValue=m.fairValue,
    quantity=m.latest.quantity,cheapQuantity=m.latest.cheapQuantity,score=math.floor(score),parts=parts,
    kind=kind,economics=e,pass=pass,blocks=why,confidence=m.confidence,confidenceScore=m.confidenceScore,
    activity=m.activity,activityScore=m.activityScore,risk=kind=='vendor' and 'Vendor spread' or ((m.volatility or 0)>0.20 and 'High' or (m.observations or 0)<6 and 'Moderate' or 'Lower'),
    reasons=m.reasons,at=m.lastSeen}
end
function M:RebuildOpportunities()
  if not self.db then return end
  local i=1; local list={}; local keys=self.marketIndex or {}
  self:AddJob('opportunities',function(start)
    for j=1,40 do
      if i>#keys then return true end
      local m=self.db.market[keys[i]]; i=i+1
      if m then local ok,o=pcall(self.MakeOpportunity,self,m); if ok and o then
        list[#list+1]=o
        if #list>200 then table.sort(list,function(a,b) return a.score>b.score end); list[201]=nil end
      end end
      if debugprofilestop()-start>=4 then return false end
    end
  end,function()
    table.sort(list,function(a,b) return a.score>b.score end); self.db.opportunities=list; self.opportunityRevision=(self.opportunityRevision or 0)+1
    self:RefreshUI()
  end)
end
function M:GetTopOpportunities(limit)
  local out={}; for i=1,math.min(limit or 200,#self.db.opportunities) do out[i]=self.db.opportunities[i] end; return out
end
function M:FinalizeMarketScan(grouped,summary,done)
  self.db.scanSequence=self.db.scanSequence+1; local scanID=self.db.scanSequence; local cursor=nil; local at=time(); local updated=0
  local storedCount=#(self.marketIndex or {})
  self:AddJob('model',function(start)
    for j=1,12 do
      local k,g=next(grouped,cursor); cursor=k
      if k==nil then return true end
      local isNew=not self.db.market[k]
      if not self.db.market[k] and storedCount>=20000 then summary.skippedMarkets=summary.skippedMarkets+1
      elseif g.analysisIncomplete then
        summary.skippedMarkets=summary.skippedMarkets+1
        if self.db.market[k] then self.db.market[k].analysisIncomplete=true end
      elseif summary.source=='cached snapshot' and self.db.market[k] then
        -- The client cache has no trustworthy generation timestamp. Reanalysis
        -- must never make established history newer or add independent evidence.
      else
        local ok,m=pcall(self.UpdateMarketFromGroup,self,g,scanID,at)
        if ok and m then
          updated=updated+1
          if isNew then storedCount=storedCount+1 end
          if summary.source=='cached snapshot' then
            m.history={}; m.observations=0; m.totalObservations=0; m.lastSeen=0
            m.confidence='New'; m.confidenceScore=0; m.cacheUntrusted=true
          else m.cacheUntrusted=nil end
        else summary.modelErrors=summary.modelErrors+1; self:Log('MODEL',m) end
      end
      if debugprofilestop()-start>=4 then return false end
    end
    self:SetScanStatus('Modeling markets: '..updated,0.85)
  end,function()
    summary.marketScanID=scanID
    self.db.marketStats={storedMarkets=0,marketsUpdated=updated,scanID=scanID,modelVersion=self.version}
    self:RebuildIndexes()
    -- Index and opportunities must finish before publishing scan completion.
    self:AddJob('scan-finish',function()
      if self.jobs.index or self.jobs.opportunities then return false end
      self.db.marketStats.storedMarkets=#self.marketIndex; self.db.marketStats.opportunities=#self.db.opportunities
      summary.marketOpportunities=#self.db.opportunities; return true
    end,done)
  end)
end
