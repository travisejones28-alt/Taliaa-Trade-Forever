local _,M=...
local tabs={'market','opportunities','execution','selling','my auctions','ledger','settings','diagnostics'}
local function label(parent,text,x,y,w,font)
  local f=parent:CreateFontString(nil,'OVERLAY',font or 'GameFontNormalSmall'); f:SetPoint('TOPLEFT',x,y)
  if w then f:SetWidth(w) end; f:SetJustifyH('LEFT'); f:SetText(text); return f
end
local function button(parent,text,x,y,w,fn)
  local b=CreateFrame('Button',nil,parent,'UIPanelButtonTemplate'); b:SetPoint('TOPLEFT',x,y); b:SetSize(w,26); b:SetText(text); b:SetScript('OnClick',fn); return b
end
local function edit(parent,x,y,w,text)
  local e=CreateFrame('EditBox',nil,parent,'InputBoxTemplate'); e:SetPoint('TOPLEFT',x,y); e:SetSize(w,24); e:SetAutoFocus(false)
  e:SetText(text or ''); e:SetScript('OnEscapePressed',function(f) f:ClearFocus() end); return e
end
function M:SetView(view)
  self.view=view; self.page=1; if self.window then self.window:Show() end
  if view=='selling' then self:RefreshInventory() end; self:RefreshUI()
end
function M:ToggleUI() if self.window:IsShown() then self.window:Hide() else self.window:Show(); self:RefreshUI() end end
function M:InitializeUI()
  if self.window then return end
  local f=CreateFrame('Frame','VoidMarkMarketWindow',UIParent,'BackdropTemplate'); self.window=f
  f:SetSize(1040,680); f:SetPoint('CENTER'); f:SetFrameStrata('HIGH'); f:SetMovable(true); f:EnableMouse(true)
  f:SetClampedToScreen(true); f:RegisterForDrag('LeftButton')
  f:SetScript('OnDragStart',function(w) w:StartMoving() end); f:SetScript('OnDragStop',function(w) w:StopMovingOrSizing() end)
  f:SetBackdrop({bgFile='Interface\\Buttons\\WHITE8X8',edgeFile='Interface\\Tooltips\\UI-Tooltip-Border',edgeSize=16,insets={left=4,right=4,top=4,bottom=4}})
  f:SetBackdropColor(0.025,0.022,0.04,0.97); f:SetBackdropBorderColor(0.45,0.3,0.7,1)
  if UIParent.GetWidth then f:SetScale(math.min(1,(UIParent:GetWidth()-30)/1040,(UIParent:GetHeight()-30)/680)) end
  label(f,'VOIDMARK MARKET',18,-16,300,'GameFontNormalLarge')
  self.modeLabel=label(f,'SAFE MODE ON',365,-19,580)
  button(f,'X',995,-12,26,function() f:Hide() end)
  for i,v in ipairs(tabs) do local tab=v; button(f,v:upper(),18+(i-1)*126,-48,122,function() self:SetView(tab) end) end
  self.status=label(f,'',18,-84,995)
  self.toolbar=CreateFrame('Frame',nil,f); self.toolbar:SetPoint('TOPLEFT',18,-109); self.toolbar:SetSize(1000,34)
  self.scanButton=button(self.toolbar,'FULL SCAN',0,0,125,function() self:RequestFreshScan() end)
  self.cachedButton=button(self.toolbar,'CACHED',132,0,100,function() self:AnalyzeCachedSnapshot() end)
  self.filter=edit(self.toolbar,305,-1,210,self.db.settings.filter); label(self.toolbar,'Filter:',245,-7,50)
  self.filter:SetScript('OnTextChanged',function(e) self.db.settings.filter=e:GetText(); self.page=1; self:RefreshUI() end)
  self.sortButton=button(self.toolbar,'SORT: SCORE',530,0,125,function()
    local sorts={'score','profit','roi','name'}; local current=self.db.settings.sort
    for i,v in ipairs(sorts) do if v==current then self.db.settings.sort=sorts[i%#sorts+1]; break end end
    self:RefreshUI()
  end)
  button(self.toolbar,'<',750,0,32,function() self.page=math.max(1,(self.page or 1)-1); self:RefreshUI() end)
  button(self.toolbar,'>',788,0,32,function() self.page=(self.page or 1)+1; self:RefreshUI() end)
  self.pageText=label(self.toolbar,'',830,-7,155)
  self.tableFrame=CreateFrame('Frame',nil,f); self.tableFrame:SetPoint('TOPLEFT',18,-151); self.tableFrame:SetSize(1000,340)
  self.headings={}; self.rows={}
  local widths={270,105,105,110,75,55,110,120}; local x=0
  for i,w in ipairs(widths) do self.headings[i]=label(self.tableFrame,'',x,-2,w); x=x+w end
  for r=1,12 do
    local b=CreateFrame('Button',nil,self.tableFrame); self.rows[r]=b; b:SetPoint('TOPLEFT',0,-25-(r-1)*25); b:SetSize(1000,25)
    b:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight'); b.cols={}; local cx=0
    for i,w in ipairs(widths) do b.cols[i]=label(b,'',cx,-6,w-5,'GameFontHighlightSmall'); cx=cx+w end
    b:SetScript('OnClick',function(row)
      if not row.data then return end
      self.selectedRow=row.data
      if self.view=='opportunities' then self:SelectOpportunity(row.data)
      elseif self.view=='my auctions' then self:AnalyzeOwnedLive(row.data)
      else self:RefreshUI() end
    end)
  end
  self.detail=label(f,'',18,-493,998,'GameFontHighlightSmall'); self.detail:SetHeight(125); self.detail:SetJustifyV('TOP')
  self.contentScroll=CreateFrame('ScrollFrame',nil,f,'UIPanelScrollFrameTemplate')
  self.contentScroll:SetPoint('TOPLEFT',18,-151); self.contentScroll:SetSize(976,465)
  local child=CreateFrame('Frame',nil,self.contentScroll); child:SetSize(972,460); self.contentScroll:SetScrollChild(child)
  self.content=label(child,'',0,0,960,'GameFontHighlightSmall'); self.content:SetJustifyV('TOP')
  self.action=CreateFrame('Frame',nil,f); self.action:SetPoint('BOTTOMLEFT',18,18); self.action:SetSize(1000,28)
  self.quantity=edit(self.action,83,-1,80,'1'); label(self.action,'Quantity:',0,-7,80)
  self.revalidateButton=button(self.action,'REVALIDATE',180,0,130,function() self:RevalidateSelected(self.quantity:GetText()) end)
  self.executeButton=button(self.action,'EXECUTE',318,0,130,function() self:ExecuteClicked() end)
  self.confirmButton=button(self.action,'CONFIRM QUOTE',456,0,155,function() self:ConfirmClicked() end)
  self.cancelQuoteButton=button(self.action,'DISCARD QUOTE',619,0,150,function()
    if self.execution.state=='quoting' or self.execution.state=='quoted' then self:InvalidateQuote('Quote discarded') end
  end)
  self.ledgerAction=CreateFrame('Frame',nil,f); self.ledgerAction:SetPoint('BOTTOMLEFT',18,18); self.ledgerAction:SetSize(1000,28)
  button(self.ledgerAction,'BOOK REVIEWED SALE',0,0,190,function()
    if not self:BookSale(self.selectedRow) then self:Print('Select an unbooked verified invoice with one exact market match') end
  end)
  button(self.ledgerAction,'MARK BUY CONFIRMED',200,0,200,function() self:ReviewPending(self.selectedRow,true) end)
  button(self.ledgerAction,'MARK BUY FAILED',410,0,170,function() self:ReviewPending(self.selectedRow,false) end)
  self.ownedRefresh=button(f,'REFRESH MY AUCTIONS',18,-628,210,function() self:RequestOwnedAuctionsDiagnostic() end)
  self.settingsFrame=CreateFrame('Frame',nil,f); self.settingsFrame:SetPoint('TOPLEFT',18,-151); self.settingsFrame:SetSize(998,460)
  local settings={
    {'maxTransaction','Maximum transaction (gold)',10000},{'maxItemSpend','Maximum per-item exposure (gold)',10000},
    {'maxExposure','Maximum portfolio exposure (gold)',10000},{'maxQuantity','Maximum quantity',1},
    {'minProfit','Minimum expected profit (silver)',100},{'minROI','Minimum ROI (%)',0.01},
    {'minConfidence','Minimum confidence (0-100)',1},{'minLiquidity','Minimum inferred liquidity (0-100)',1},
    {'riskTolerance','Maximum volatility (%)',0.01},{'depositReserve','Resale deposit allowance/unit (silver)',100},
    {'ahCut','AH cut (%) - verify current AH',0.01},{'maxDataAge','Maximum model age (minutes)',60}}
  self.settingFields={}
  for i,s in ipairs(settings) do
    local col=(i-1)%2; local row=math.floor((i-1)/2); local x=col*495
    label(self.settingsFrame,s[2],x,-row*52,355)
    local e=edit(self.settingsFrame,x+365,-row*52+3,100,tostring(self.db.settings[s[1]]/s[3]))
    self.settingFields[#self.settingFields+1]={edit=e,key=s[1],factor=s[3]}
  end
  button(self.settingsFrame,'APPLY LIMITS',0,-335,155,function()
    local values={}
    for _,s in ipairs(self.settingFields) do
      local n=tonumber(s.edit:GetText())
      if not n or n<0 or n>1e9 then self:Print('Use nonnegative numeric limits'); return end
      values[s.key]=n*s.factor
    end
    if values.ahCut>0.30 or values.minConfidence>100 or values.minLiquidity>100 or values.riskTolerance>2 or values.maxDataAge>86400*7 then self:Print('One or more limits exceed supported ranges'); return end
    values.maxQuantity=math.floor(values.maxQuantity)
    for k,v in pairs(values) do self.db.settings[k]=v end
    if self.execution.state=='quoted' then self:InvalidateQuote('Limits changed; revalidate')
    elseif self.execution.state=='ready' then self.execution.state='stale'; self.execution.message='Limits changed; revalidate' end
    self:RebuildOpportunities(); self:RefreshUI()
  end)
  self.safe=CreateFrame('CheckButton',nil,self.settingsFrame,'UICheckButtonTemplate'); self.safe:SetPoint('TOPLEFT',190,-332); self.safe:SetSize(28,28)
  label(self.settingsFrame,'SAFE MODE (starts ON every login)',223,-340,450)
  self.safe:SetChecked(true); self.safe:SetScript('OnClick',function(c)
    self.db.settings.safeMode=c:GetChecked() and true or false; self.safeMode=self.db.settings.safeMode
    if self.safeMode and (self.execution.state=='quoted' or self.execution.state=='quoting') then self:InvalidateQuote('Safe Mode enabled') end
    self:RefreshUI()
  end)
  label(self.settingsFrame,'Turning Safe Mode off enables purchase buttons. Each purchase still needs a real click.\nDeposit allowance is an estimate; set it conservatively. Pending orders remain reserved through reloads.\nLiquidity describes observed supply/depth, not proven sale speed. Cross-client sharing is deferred.',0,-387,970)
  self.view='market'; self.page=1; self:RefreshUI(); f:Show()
end
function M:ShowReport()
  if not self.reportWindow then
    local f=CreateFrame('Frame',nil,UIParent,'BackdropTemplate'); self.reportWindow=f; f:SetSize(800,570); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG')
    f:SetBackdrop({bgFile='Interface\\Buttons\\WHITE8X8'}); f:SetBackdropColor(0.02,0.02,0.02,1)
    button(f,'CLOSE',665,-12,115,function() f:Hide() end)
    label(f,'Diagnostics - Ctrl+A, Ctrl+C to copy',18,-18,600)
    local scroll=CreateFrame('ScrollFrame',nil,f,'UIPanelScrollFrameTemplate'); scroll:SetPoint('TOPLEFT',18,-52); scroll:SetSize(745,490)
    local e=CreateFrame('EditBox',nil,scroll); e:SetMultiLine(true); e:SetFontObject('ChatFontNormal'); e:SetWidth(735); e:SetAutoFocus(false); e:SetScript('OnEscapePressed',function() f:Hide() end); scroll:SetScrollChild(e); self.reportEdit=e
  end
  self.reportEdit:SetText(self:BuildTextReport()); self.reportWindow:Show(); self.reportEdit:SetFocus(); self.reportEdit:HighlightText()
end
function M:RenderUI()
  self.uiDirty=false; if not self.window or not self.window:IsShown() then return end
  local view=self.view or 'market'; local s=self.db.settings
  self.modeLabel:SetText(s.safeMode and '|cff72e7aaSAFE MODE ON - no transactions|r' or '|cffffa250TRADING ENABLED - real clicks required|r')
  self.status:SetText('AH '..(self.ahOpen and 'OPEN' or 'CLOSED')..' | '..self.scanState.status..' | full scan cooldown '..self:FormatDuration(self:GetSecondsUntilFreshScanAllowed()))
  self.toolbar:Show(); self.tableFrame:Hide(); self.detail:Hide(); self.contentScroll:Hide(); self.settingsFrame:Hide(); self.action:Hide(); self.ledgerAction:Hide(); self.ownedRefresh:Hide()
  self.filter:SetShown(view=='opportunities'); self.sortButton:SetShown(view=='opportunities'); self.sortButton:SetText('SORT: '..s.sort:upper())
  self.scanButton:SetEnabled(self.ahOpen and not self.scanState.running); self.cachedButton:SetEnabled(self.ahOpen and not self.scanState.running)
  if view=='settings' then self.settingsFrame:Show(); self.safe:SetChecked(s.safeMode); return end
  local text
  if view=='execution' then
    self.action:Show(); local x=self.execution; local m=x.market
    local lines={'|cffffffffEXECUTION / '..x.state:upper()..'|r',x.message,'',m and m.name or 'Select an opportunity first.'}
    if m then
      lines[#lines+1]='Historical ask '..self:Money(m.latest.floor)..' | fair '..self:Money(m.fairValue)..' | meaningful floor '..self:Money(m.latest.meaningfulFloor or m.latest.q10)
      lines[#lines+1]='Confidence '..tostring(m.confidence)..' | inferred liquidity '..tostring(m.activity)..' | '..m.observations..' observations'
      lines[#lines+1]=m.modelReason or ''
      local p=x.opportunity.parts
      if p then lines[#lines+1]=string.format('Rank %d: profit +%.1f, ROI +%.1f, confidence +%.1f, liquidity +%.1f, depth +%.1f, volatility -%.1f, capital -%.1f',x.opportunity.score,p.profit,p.roi,p.confidence,p.liquidity,p.depth,p.risk,p.exposure) end
      lines[#lines+1]='Snapshot limits: '..(x.opportunity.pass and 'passed at analysis time' or table.concat(x.opportunity.blocks or {},'; '))
      if x.live then
        local e=x.live.economics
        lines[#lines+1]='\nLIVE: '..x.live.quantity..' units | total '..self:Money(x.live.cost)..' | expected net '..self:Money(e.net)..' | ROI '..self:PercentText(e.roi)
        lines[#lines+1]='Gross estimate '..self:Money(e.gross)..' | cut '..self:Money(e.fee)..' | deposit allowance '..self:Money(e.depositReserve)
        lines[#lines+1]=x.commodity and 'Commodity: EXECUTE requests a quote; CONFIRM QUOTE purchases it.' or ('Regular item: one full auction #'..tostring(x.live.auctionID))
        lines[#lines+1]='Model '..e.kind..(e.kind=='vendor' and ': vendor spread, no resale fees' or ': resale estimates do not guarantee a sale')
      end
      lines[#lines+1]='\nWhy: '..table.concat(m.reasons or {},'; ')
      lines[#lines+1]='Risks: '..table.concat(m.risks or {},'; ')
    end
    self.revalidateButton:SetEnabled(not self.persistenceBlocked and self.ahOpen and m~=nil and not self:HasUnresolvedPurchase() and x.state~='quoting' and x.state~='quoted' and x.state~='validating')
    self.executeButton:SetEnabled(not self.persistenceBlocked and not s.safeMode and self.ahOpen and x.state=='ready' and not self:HasUnresolvedPurchase())
    self.confirmButton:SetEnabled(not s.safeMode and x.state=='quoted')
    self.cancelQuoteButton:SetEnabled(x.state=='quoted' or x.state=='quoting')
    text=table.concat(lines,'\n')
  elseif view=='diagnostics' then text=self:BuildTextReport()
  elseif view=='market' then
    local scan=self.db.latestScan; local stats=self.db.marketStats or {}; local totals=self:LedgerTotals()
    text='|cffffffffLOCAL MARKET TERMINAL|r\n\n'..#(self.marketIndex or {})..' markets | '..#self.db.opportunities..' ranked candidates\nEconomy: '..self.economyID..'\n\n'
    if scan then text=text..string.format('Last scan %s\nRows %d | valid %d | invalid %d | incomplete %d\nMarkets %d | total supply %d | elapsed %s ms | generation #%s\n\n',date('%Y-%m-%d %H:%M',scan.completedAt or time()),scan.rawRows or 0,scan.auctionsProcessed or 0,scan.invalidRecords or 0,scan.incompleteRecords or 0,scan.uniqueItems or 0,scan.totalQuantity or 0,tostring(scan.processingMS),tostring(scan.marketScanID)) end
    text=text..self:BuildFullScanReport()..'\n\n'
    text=text..'Tracked inventory cost '..self:Money(totals.inventory)..' | reserved orders '..self:Money(totals.reserved)..'\nCost-matched realized result '..self:Money(totals.realized)..' | net sale revenue '..self:Money(totals.revenue)..'\n\nFull scans have a 15-minute safety cooldown. Cached analysis cannot increase history confidence.\nPricing blends lower-market depth and recent history. Missing markets retain their last observation.\nChoose OPPORTUNITIES, select a row, then REVALIDATE before considering EXECUTE.\nSelling and cancel/repost analysis are advisory; use the native AH for posting/cancelling.\n/vmm report opens copyable diagnostics.'
  else
    local source,headers={},{'Name','Ask','Fair','Net','ROI','Score','Confidence','Liquidity'}
    if view=='opportunities' then
      for _,o in ipairs(self.db.opportunities) do if tostring(o.name):lower():find(s.filter:lower(),1,true) then source[#source+1]=o end end
      table.sort(source,function(a,b)
        if s.sort=='name' then return tostring(a.name)<tostring(b.name) end
        local av=s.sort=='profit' and a.economics.net or s.sort=='roi' and a.economics.roi or a.score
        local bv=s.sort=='profit' and b.economics.net or s.sort=='roi' and b.economics.roi or b.score
        return av>bv
      end)
    elseif view=='selling' then source=self.sellingRows; headers={'Inventory','Quantity','Suggest/unit','Fair','Floor','','Confidence','Status'}
    elseif view=='my auctions' then source=self.ownedRows; self.ownedRefresh:Show(); headers={'My listing','Quantity','My unit','Competitor','Time left','','',''}
    elseif view=='ledger' then
      self.ledgerAction:Show(); headers={'Event / item','Quantity','Cost','Revenue','State','ID','Evidence',''}
      for i=#self.db.ledger,1,-1 do source[#source+1]=self.db.ledger[i] end
      -- Unresolved purchases remain selectable even after compact history pruning.
      for _,p in pairs(self.db.pending) do
        local found=false; for _,e in ipairs(source) do if e==p then found=true; break end end
        if not found then table.insert(source,1,p) end
      end
    end
    local pages=math.max(1,math.ceil(#source/12)); self.page=math.min(self.page or 1,pages)
    self.pageText:SetText(self.page..' / '..pages..' ('..#source..')')
    self.tableFrame:Show(); self.detail:Show()
    for i,h in ipairs(headers) do self.headings[i]:SetText(h) end
    for i,row in ipairs(self.rows) do
      local o=source[(self.page-1)*12+i]; row.data=o; row:SetShown(o~=nil)
      if o then
        local cells
        if view=='opportunities' then cells={(o.kind=='vendor' and '|cff72e7aa[VENDOR]|r ' or '')..o.name,self:Money(o.floor),self:Money(o.fairValue),self:Money(o.economics.net),self:PercentText(o.economics.roi),o.score,o.confidence,o.activity}
        elseif view=='selling' then cells={o.name,o.quantity,self:Money(o.price),self:Money(o.fair),self:Money(o.floor),'',o.confidence,o.stale and 'STALE' or 'Estimate'}
        elseif view=='my auctions' then cells={o.name,o.quantity,self:Money(o.unit),o.competition and self:Money(o.competition) or '?',tostring(o.timeLeft or '?'),'','',''}
        else cells={(o.kind or '')..': '..tostring(o.name or o.auctionID or ''),o.quantity or '',o.cost and self:Money(o.cost) or '',o.gross and self:Money(o.gross) or '',o.booked and 'booked' or o.status,o.id,o.evidence or '',''} end
        for j,c in ipairs(cells) do row.cols[j]:SetText(tostring(c)) end
      end
    end
    local o=self.selectedRow
    if view=='opportunities' then self.detail:SetText('Select a row to inspect economics and revalidate live prices. Vendor opportunities have a separate model.\nResale rankings weigh absolute profit, ROI, confidence, inferred liquidity, depth, volatility and capital exposure.\nA snapshot opportunity may fail current limits or disappear before you buy. Live prices expire after 10 seconds.')
    elseif view=='ledger' then
      local t=self:LedgerTotals()
      self.detail:SetText('Cost-matched realized '..self:Money(t.realized)..' | ROI '..self:PercentText(t.roi)..' | fees '..self:Money(t.fees)..' | uncosted revenue '..self:Money(t.uncostedRevenue)..'\n'..(o and (tostring(o.evidence)..'\n'..tostring(o.name or '')..' | market '..tostring(o.marketKey)..' | deposit refund '..self:Money(o.depositRefund)) or 'Select an invoice or unresolved order.')..'\nMailbox invoices are observed facts, but have no unique ID. Review identity before BOOK REVIEWED SALE.\nPurchase cost uses moving average. Unknown cost is excluded from realized profit; manually reported outcomes are labeled.')
    else self.detail:SetText(o and (tostring(o.name)..'\n'..tostring(o.reason or '')..'\nAdvisory only. Verify live price and deposit in the native auction window.') or 'Select a row for details. Posting and cancellation use the native auction window.') end
    return
  end
  self.contentScroll:Show(); self.content:SetText(text or ''); self.content:SetHeight(math.max(450,self.content:GetStringHeight()+20))
end
