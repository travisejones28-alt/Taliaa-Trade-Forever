local addonName, M = ...
_G.VoidMarkMarket = M
M.name, M.version = addonName or 'VoidMarkMarket', '1.0.1-beta'
M.eventHandlers, M.runtimeLog, M.jobs = {}, {}, {}
M.ahOpen, M.safeMode = false, true
M.scanState = {running=false, phase='idle', status='No scan yet', progress=0}
function M:Now() return time() end
function M:Money(v)
  v=math.floor(tonumber(v) or 0)
  local sign=v<0 and '-' or ''; v=math.abs(v)
  return sign..string.format('%dg %ds %dc',math.floor(v/10000),math.floor(v/100)%100,v%100)
end
function M:FormatDuration(s)
  s=math.max(0,math.floor(tonumber(s) or 0)); return string.format('%dm %02ds',math.floor(s/60),s%60)
end
function M:PercentText(v) return string.format('%.1f%%',(tonumber(v) or 0)*100) end
function M:Print(s)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff9f7aeaVoidMark Market:|r '..tostring(s)) end
end
function M:RefreshUI() self.uiDirty=true end
function M:Log(kind,s)
  local log=self.runtimeLog; log[#log+1]={at=time(),kind=kind,message=tostring(s)}
  if #log>200 then table.remove(log,1) end
  if self.db and self.db.settings.debug then self:Print(kind..': '..tostring(s)) end
  self:RefreshUI()
end
function M:SafeCall(label,fn,...)
  if type(fn)~='function' then return false,'API unavailable: '..label end
  local ok,a,b,c,d,e=pcall(fn,...)
  if not ok then self:Log('ERROR',label..': '..tostring(a)) end
  return ok,a,b,c,d,e
end
function M:RegisterHandler(event,fn)
  self.eventHandlers[event]=self.eventHandlers[event] or {}
  table.insert(self.eventHandlers[event],fn)
  return pcall(self.eventFrame.RegisterEvent,self.eventFrame,event)
end
function M:GetBuildSnapshot()
  local v,b,d,t=GetBuildInfo()
  return {version=v,build=b,buildDate=d,tocVersion=t,projectID=WOW_PROJECT_ID,isForeverBeta=tonumber(t)==16001}
end
function M:CanUseAuctionHouse() return self.ahOpen and type(C_AuctionHouse)=='table' end
function M:GetSecondsUntilFreshScanAllowed()
  return math.max(0,900-(time()-(self.db.lastFreshScanRequestAt or 0)))
end
function M:SetScanStatus(s,p)
  self.scanState.status=s; if p then self.scanState.progress=p end; self:RefreshUI()
end
-- Frame-budgeted jobs; callbacks run only from OnUpdate, never protected transactions.
function M:AddJob(id,step,done)
  self.jobs[id]={step=step,done=done}; return id
end
function M:CancelJob(id) self.jobs[id]=nil end
function M:RunJobs()
  local start=debugprofilestop()
  local ids={}
  for id in pairs(self.jobs) do ids[#ids+1]=id end
  for _,id in ipairs(ids) do
    local job=self.jobs[id]
    if job then
    local ok,finished=pcall(job.step,start)
    if not ok or finished then
      self.jobs[id]=nil
      if not ok then self:Log('JOB ERROR',id..': '..tostring(finished))
      elseif job.done then local good,err=pcall(job.done); if not good then self:Log('JOB ERROR',err) end end
    end
    end
    if debugprofilestop()-start>=4 then break end
  end
end
function M:Key(itemID,suffix,level,pet)
  itemID=tonumber(itemID); if not itemID or itemID<=0 then return nil end
  suffix=tonumber(suffix) or 0; level=tonumber(level) or 0; pet=tonumber(pet) or 0
  if level~=0 or pet~=0 then return tostring(itemID)..':s'..suffix..':l'..level..':p'..pet end
  return suffix~=0 and (tostring(itemID)..':s'..suffix) or itemID
end
function M:ItemKey(m)
  return {itemID=m.itemID,itemSuffix=m.itemSuffix or 0,itemLevel=m.itemLevel or 0,battlePetSpeciesID=m.battlePetSpeciesID or 0}
end
function M:RegularQuantity(info,itemID)
  local quantity=math.max(1,math.floor(tonumber(info.quantity) or 1))
  if quantity==1 then return 1 end
  local maxStack
  if C_Item and C_Item.GetItemMaxStackSizeByID then
    local ok,v=pcall(C_Item.GetItemMaxStackSizeByID,itemID); if ok then maxStack=tonumber(v) end
  end
  if not maxStack and GetItemInfo then
    local ok,_,_,_,_,_,_,_,v=pcall(GetItemInfo,itemID); if ok then maxStack=tonumber(v) end
  end
  -- Forever may report a bogus large quantity for a single recipe. Never value
  -- a non-stackable purchase as a stack, or count unsupported inventory units.
  return math.min(quantity,maxStack and maxStack>=1 and maxStack or 1)
end
function M:SameKey(a,b)
  return type(a)=='table' and type(b)=='table' and self:Key(a.itemID,a.itemSuffix,a.itemLevel,a.battlePetSpeciesID)==self:Key(b.itemID,b.itemSuffix,b.itemLevel,b.battlePetSpeciesID)
end
function M:Suffix(link)
  local s=type(link)=='string' and link:match('|Hitem:([^|]+)|h')
  if not s then return nil end
  local fields={}; for f in (s..':'):gmatch('(.-):') do fields[#fields+1]=f; if #fields==7 then break end end
  return tonumber(fields[7]) or 0
end
function M:IsCommodity(key)
  if C_AuctionHouse.GetItemKeyInfo then
    local ok,info=pcall(C_AuctionHouse.GetItemKeyInfo,key)
    if ok and type(info)=='table' and type(info.isCommodity)=='boolean' then return info.isCommodity end
  end
  if C_AuctionHouse.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
    local ok,s=pcall(C_AuctionHouse.GetItemCommodityStatus,key.itemID)
    if ok and s==Enum.ItemCommodityStatus.Commodity then return true end
    if ok and s==Enum.ItemCommodityStatus.Item then return false end
  end
  return nil -- Unknown classification must never enable a purchase.
end
M.eventFrame=CreateFrame('Frame')
M.eventFrame:RegisterEvent('ADDON_LOADED'); M.eventFrame:RegisterEvent('PLAYER_LOGIN')
M.eventFrame:SetScript('OnEvent',function(_,event,...)
  if event=='ADDON_LOADED' then
    if (...)~=M.name then return end; M:InitializeDatabase(); return
  elseif event=='PLAYER_LOGIN' then
    if not M.db then M:InitializeDatabase() end
    M:RegisterHandler('AUCTION_HOUSE_DISABLED',function() end)
    M:RunAPIProbe(); M:InitializeUI(); M:Print('v'..M.version..' loaded. /vmm | SAFE MODE ON')
  end
  if event=='AUCTION_HOUSE_DISABLED' then event='AUCTION_HOUSE_CLOSED' end
  local args={...}
  for _,fn in ipairs(M.eventHandlers[event] or {}) do
    local ok,err=pcall(fn,M,event,unpack(args)); if not ok then M:Log('EVENT ERROR',event..': '..tostring(err)) end
  end
end)
local tick=0
M.eventFrame:SetScript('OnUpdate',function(_,elapsed)
  if not M.db then return end
  M:RunJobs(); tick=tick+elapsed
  if tick<0.1 then return end; tick=0
  M:PumpQueue(); M:ExecutionTick()
  if M.bagsDirty and M.view=='selling' then M.bagsDirty=false; M:RefreshInventory() end
  if M.uiDirty and M.RenderUI then M:RenderUI() end
end)
SLASH_VOIDMARKMARKET1='/vmm'; SLASH_VOIDMARKMARKET2='/voidmarkmarket'
SlashCmdList.VOIDMARKMARKET=function(msg)
  msg=(msg or ''):lower():match('^%s*(.-)%s*$')
  if msg=='scan' then M:RequestFreshScan()
  elseif msg=='cached' then M:AnalyzeCachedSnapshot()
  elseif msg=='diag' then M:SetView('diagnostics')
  elseif msg=='report' then M:ShowReport()
  elseif msg=='probe' then M:RunAPIProbe()
  elseif msg=='debug' then M.db.settings.debug=not M.db.settings.debug; M:Print('Debug '..tostring(M.db.settings.debug))
  else M:ToggleUI() end
end
