unpack=unpack or table.unpack
local clock=1000000; local ms=0; local calls={}; local money=100000000
function time() return math.floor(clock) end
function GetTime() return clock end
function debugprofilestop() ms=ms+0.02; return ms end
function GetBuildInfo() return '1.60.1','69913','',16001 end
function GetNormalizedRealmName() return 'TestRealm' end
function GetRealmName() return 'TestRealm' end
function UnitFactionGroup() return 'Horde' end
function UnitName() return 'Tester' end
function GetMoney() return money end
function date(fmt,v) return os.date(fmt,v) end
WOW_PROJECT_ID=1
DEFAULT_CHAT_FRAME={AddMessage=function() end}; SlashCmdList={}; Enum={ItemCommodityStatus={Commodity=2,Item=1},AuctionHouseSortOrder={Price=0}}
local frames={}; local methods={}
function methods:SetScript(k,v) self.scripts[k]=v end
function methods:RegisterEvent(k) self.events[k]=true end
function methods:GetWidth() return self.width or 1600 end
function methods:GetHeight() return self.height or 900 end
function methods:SetSize(w,h) self.width=w; self.height=h end
function methods:SetWidth(w) self.width=w end
function methods:SetHeight(h) self.height=h end
function methods:SetText(t) self.text=tostring(t) end
function methods:GetText() return self.text or '' end
function methods:GetStringHeight() return 450 end
function methods:Show() self.shown=true end
function methods:Hide() self.shown=false end
function methods:SetShown(v) self.shown=v end
function methods:IsShown() return self.shown~=false end
function methods:SetChecked(v) self.checked=v end
function methods:GetChecked() return self.checked end
function methods:SetEnabled(v) self.enabled=v end
local noop=function() end
setmetatable(methods,{__index=function() return noop end})
function CreateFrame(kind,name,parent,template)
  local f=setmetatable({scripts={},events={},shown=true},{__index=methods}); frames[#frames+1]=f; return f
end
function methods:CreateFontString() return CreateFrame('FontString') end
UIParent=CreateFrame('Frame'); UIParent:SetSize(1600,900)
local function spy(k) return function(...) calls[#calls+1]={k,...} end end
local ready=true; local commodity=false; local searchRows={}; local full=true; local has=false; local replicateRows=0
C_AuctionHouse={
 IsThrottledMessageSystemReady=function() return ready end,
 GetItemKeyInfo=function() return {isCommodity=commodity} end,
 GetItemCommodityStatus=function() return commodity and 2 or 1 end,
 HasSearchResults=function() return has end,
 ReplicateItems=spy('replicate'),SendSearchQuery=spy('search'),RefreshItemSearchResults=spy('refresh-item'),
 RefreshCommoditySearchResults=spy('refresh-commodity'),RequestMoreItemSearchResults=spy('more-item'),
 RequestMoreCommoditySearchResults=spy('more-commodity'),SendBrowseQuery=spy('browse'),QueryOwnedAuctions=spy('owned'),
 HasFullItemSearchResults=function() return full end,HasFullCommoditySearchResults=function() return full end,
 GetNumItemSearchResults=function() return #searchRows end,GetNumCommoditySearchResults=function() return #searchRows end,
 GetItemSearchResultInfo=function(_,i) return searchRows[i] end,GetCommoditySearchResultInfo=function(_,i) return searchRows[i] end,
 PlaceBid=spy('bid'),StartCommoditiesPurchase=spy('quote'),ConfirmCommoditiesPurchase=spy('confirm'),CancelCommoditiesPurchase=spy('cancel-quote'),
 GetNumReplicateItems=function() return replicateRows end,
 GetReplicateItemInfo=function(i)
   if i==12 then error('Bad row') end
   local id=i%1500+1
   return 'Item '..id,999,1,1,true,1,0,0,0,i%8==0 and 500 or 4500,0,false,nil,'Other','Other-TestRealm',0,id,true
 end,
 GetReplicateItemLink=function(i) return '|Hitem:'..(i%1500+1)..':0:0:0:0:0:0:0|h[Item]|h' end,
 GetNumOwnedAuctions=function() return 0 end,GetOwnedAuctionInfo=function() end,
}
function GetItemInfo(id) return 'Test item','link',1,1,1,'Armor','Cloth',1,'',999,100 end
local M={}; local addon=VMM_ADDON_PATH or './'
for line in io.lines(addon..'VoidMarkMarket.toc') do
  if line:match('%.lua$') then assert(loadfile(addon..line))('VoidMarkMarket',M) end
end
local total=0
local function check(name,fn)
  local ok,err=pcall(fn); if not ok then error('FAIL '..name..': '..tostring(err)) end
  total=total+1; print('PASS '..name)
end
local function emit(e,...) M.eventFrame.scripts.OnEvent(M.eventFrame,e,...) end
local function jobs()
  local count=0; while next(M.jobs) do M:RunJobs(); count=count+1; assert(count<10000,'jobs stuck') end; return count
end
local function advance(s) clock=clock+s end
local function resetQueue()
 M.ahOpen=true
 M:CancelRequests('test reset'); M.queue.waiting={};M.queue.dedupe={};M.queue.active=nil; M.queue.nextSend=0
 M.execution={state='idle',message='idle'};M.db.pending={};M.db.settings.safeMode=true;M.db.settings.depositReserve=0;M.db.quoteGuardUntil=0
 calls={};ready=true;has=false;full=true;commodity=false
end
local market
local function mk()
 M.db.market[5001]=nil
 local g={itemID=5001,marketKey=5001,itemSuffix=0,name='Ritual Gloves',quantity=21,listings=21,floorUnitPrice=500,ceilingUnitPrice=5000,priceLevels={[500]=1,[4500]=10,[5000]=10}}
 for i=1,4 do advance(1000); market=M:UpdateMarketFromGroup(g,i,time()) end
 return market
end
local function selectReady(isCom,qty)
 resetQueue();commodity=isCom;market=mk();M:RebuildIndexes();jobs()
 market.vendorPrice=0; local o=M:MakeOpportunity(market);assert(o)
 M:SelectOpportunity(o);M:RevalidateSelected(qty or 1);M:PumpQueue()
 if isCom then searchRows={{unitPrice=500,quantity=10,numOwnerItems=0}}
 else searchRows={{auctionID=42,quantity=1,buyoutAmount=500,itemKey=M:ItemKey(market)}} end
 emit(isCom and 'COMMODITY_SEARCH_RESULTS_UPDATED' or 'ITEM_SEARCH_RESULTS_UPDATED',isCom and 5001 or M:ItemKey(market)); jobs()
 assert(M.execution.state=='ready',M.execution.message)
end
check('All TOC modules load',function() assert(M.ExecutionTick and M.RenderUI and M.Sync) end)
check('Idempotent legacy migration and startup safety',function()
 TaliaaTradeBetaDB={schemaVersion=3,market={[100]={itemID=100,marketKey=100,name='Legacy',history={},latest={floor=100},fairValue=200}},scanSequence=9}
 M:InitializeDatabase();jobs(); assert(M.db.market[100]==TaliaaTradeBetaDB.market[100]);assert(M.root.legacyImported);assert(M.db.scanSequence==9)
 local old=M.db.market[100];M:InitializeDatabase();jobs();assert(M.db.market[100]==old);assert(M.db.settings.safeMode)
end)
check('Bait-resistant model, bounded history, vendor return index',function()
 mk();assert(market.fairValue>4000);assert(market.latest.meaningfulFloor==4500);assert(market.vendorPrice==100)
 assert(market.confidenceScore<=62,'within-day confidence cap');assert(market.observations==4)
 for i=1,40 do advance(1000);M:UpdateMarketFromGroup({itemID=5001,marketKey=5001,name='Ritual Gloves',quantity=2,listings=2,floorUnitPrice=500,ceilingUnitPrice=4500,priceLevels={[500]=1,[4500]=1}},i,time()) end
 assert(#market.history==30)
end)
check('Cached/repeated observations do not inflate confidence',function()
 local count=market.totalObservations
 M:UpdateMarketFromGroup({itemID=5001,marketKey=5001,quantity=1,listings=1,floorUnitPrice=1,ceilingUnitPrice=1,priceLevels={[1]=1}},99,time())
 assert(market.totalObservations==count)
end)
check('Random suffix identity is isolated',function()
 assert(M:Suffix('|Hitem:123:0:0:0:0:0:-18:0|h[Thing]|h')==-18)
 assert(M:Key(123,-18)~=M:Key(123,-19));assert(M:Key(123,-18,1)~=M:Key(123,-18,2)); assert(M:Suffix(nil)==nil)
end)
check('Money formatting handles negative profit',function() assert(M:Money(-101)=='-0g 1s 1c') end)
check('Risk caps and reserved money',function()
 mk();local e=M:Economics(market,500,1,'resale');local pass,why=M:CheckRisk(market,e);assert(pass,table.concat(why,';'))
 M.db.settings.maxTransaction=400;assert(not M:CheckRisk(market,e));M.db.settings.maxTransaction=100000
 M.db.pending[9]={cost=99999999,marketKey=5001,character=M.characterID,status='unknown'};M.exposureDirty=true
 assert(not M:CheckRisk(market,e));M.db.pending={}
end)
check('Request dedupe, throttle, priorities',function()
 resetQueue();ready=false
 assert(M:QueueRequest({id='low',kind='browse',query={},priority=1})); assert(not M:QueueRequest({id='low',kind='browse'}))
 M:QueueRequest({id='high',kind='owned',priority=100});M:PumpQueue();assert(#calls==0)
 ready=true;M:PumpQueue();assert(calls[1][1]=='owned');emit('OWNED_AUCTIONS_UPDATED');assert(not M.queue.active)
end)
check('Timeouts retry once then stop',function()
 resetQueue();local fail
 M:QueueRequest({id='test',kind='owned',fail=function(e)fail=e end});M:PumpQueue();advance(16);M:PumpQueue();advance(16);M:PumpQueue()
 assert(fail and not M.queue.active);assert(M.queue.stats.retries>=1)
end)
check('Existing searches use refresh; cached rows never unlock EXECUTE',function()
 resetQueue();mk();has=true;M:Search(market,100,function() end);M:PumpQueue();assert(calls[1][1]=='refresh-item')
 assert(M.execution.state=='idle');M:CancelRequests('end')
end)
check('Search pagination waits for complete results',function()
 resetQueue();mk();local done=false;M:Search(market,100,function()done=true end);M:PumpQueue();full=false
 emit('ITEM_SEARCH_RESULTS_UPDATED',M:ItemKey(market));assert(not done);M:PumpQueue();assert(calls[#calls][1]=='more-item')
 full=true;searchRows={};emit('ITEM_SEARCH_RESULTS_ADDED',M:ItemKey(market));jobs();assert(done)
end)
check('Mismatched suffix results ignored',function()
 resetQueue();mk();M:Search(market,100,function()error('wrong callback')end);M:PumpQueue()
 emit('ITEM_SEARCH_RESULTS_UPDATED',{itemID=5001,itemSuffix=-1});assert(M.queue.active)
 M:CancelRequests('end')
end)
check('Live regular auction revalidation, safe mode and click-only buy',function()
 selectReady(false);M:ExecuteClicked();assert(calls[#calls][1]=='search')
 M.db.settings.safeMode=false;M:ExecuteClicked();assert(calls[#calls][1]=='bid');assert(M.execution.state=='pending')
 assert(M:HasUnresolvedPurchase());emit('AUCTION_HOUSE_PURCHASE_COMPLETED',41);assert(M:HasUnresolvedPurchase())
 emit('AUCTION_HOUSE_PURCHASE_COMPLETED',42);assert(not M:HasUnresolvedPurchase());assert(M.execution.state=='complete')
 local lot=M.db.inventory[M:InventoryKey(5001)];assert(lot.quantity==1 and lot.cost==500)
 emit('AUCTION_HOUSE_PURCHASE_COMPLETED',42);assert(lot.quantity==1)
end)
check('Stale live results block purchase',function()
 selectReady(false);M.db.settings.safeMode=false;advance(11);local n=#calls;M:ExecuteClicked();assert(#calls==n);assert(M.execution.state=='stale')
end)
check('Commodity quote needs second click; event never purchases',function()
 selectReady(true,3);M.db.settings.safeMode=false;M:ExecuteClicked();assert(calls[#calls][1]=='quote')
 emit('COMMODITY_PRICE_UPDATED',500,1500);assert(M.execution.state=='quoted');assert(calls[#calls][1]=='quote')
 M:ConfirmClicked();assert(calls[#calls][1]=='confirm');assert(M.execution.state=='pending')
 emit('COMMODITY_PURCHASE_SUCCEEDED');assert(M.execution.state=='complete')
end)
check('Commodity price increase invalidates quote',function()
 selectReady(true,3);M.db.settings.safeMode=false;M:ExecuteClicked();emit('COMMODITY_PRICE_UPDATED',600,1800)
 assert(M.execution.state=='invalid');assert(calls[#calls][1]=='cancel-quote');assert(not M:HasUnresolvedPurchase())
end)
check('Late/duplicate quote cannot silently confirm',function()
 selectReady(true,3);M.db.settings.safeMode=false;M:ExecuteClicked();advance(4);emit('COMMODITY_PRICE_UPDATED',500,1500)
 M:ExecutionTick();assert(M.execution.state=='invalid');local n=#calls;emit('COMMODITY_PRICE_UPDATED',500,1500);assert(#calls==n)
end)
check('Unknown purchase reserves funds; late success resolves exactly once',function()
 selectReady(true,2);M.db.settings.safeMode=false;M:ExecuteClicked();emit('COMMODITY_PRICE_UPDATED',500,1000);M:ConfirmClicked()
 local p=M.execution.order;advance(16);M:ExecutionTick();assert(p.status=='unknown');assert(M:HasUnresolvedPurchase())
 emit('AUCTION_HOUSE_CLOSED');assert(M.db.pending[p.id]);emit('COMMODITY_PURCHASE_SUCCEEDED');assert(not M.db.pending[p.id]);assert(p.status=='confirmed')
 emit('AUCTION_HOUSE_SHOW')
end)
check('Owned listings excluded from execution',function()
 resetQueue();mk();local result;M:Search(market,100,function(r)result=r end);M:PumpQueue()
 searchRows={{auctionID=1,quantity=1,buyoutAmount=1,containsOwnerItem=true},{auctionID=2,quantity=1,buyoutAmount=3,isOwnerItem=true},{auctionID=3,quantity=1,buyoutAmount=500}}
 emit('ITEM_SEARCH_RESULTS_UPDATED',M:ItemKey(market));jobs();assert(#result.rows==1 and result.rows[1].auctionID==3)
end)
check('Commodity ownership reduces available quantity',function()
 resetQueue();mk();commodity=true;local result;M:Search(market,100,function(r)result=r end);M:PumpQueue()
 searchRows={{unitPrice=1,quantity=10,numOwnerItems=8,containsOwnerItem=true},{unitPrice=2,quantity=10,containsOwnerItem=true}}
 emit('COMMODITY_SEARCH_RESULTS_UPDATED',5001);jobs();assert(#result.rows==1 and result.rows[1].quantity==2)
end)
check('Moving-average accounting excludes unknown basis',function()
 M.db.inventory={};M.db.pending={};M.db.totals={}
 local lot={marketKey=5001,character=M.characterID,quantity=2,cost=1000,purchasedQty=2,purchasedCost=1000};M.db.inventory[M:InventoryKey(5001)]=lot
 local e=M:AddLedger('mail sale',{marketKey=5001,name='Ritual Gloves',quantity=3,gross=3000,fee=150,invoiceVerified=true,status='observed',depositRefund=1000})
 assert(M:BookSale(e));assert(not M:BookSale(e));assert(lot.quantity==0)
 local t=M:LedgerTotals();assert(t.realized==900);assert(t.uncostedRevenue==950);assert(t.revenue==2850);assert(t.fees==150)
end)
check('Invoices are observed, deduped and not auto-booked',function()
 function GetInboxNumItems() return 1 end
 function GetInboxHeaderInfo() return nil,nil,'Auction House','Auction successful: Ritual Gloves',960 end
 function GetInboxInvoiceInfo() return 'seller','Ritual Gloves','Buyer',0,1000,10,50,0,0,0,1 end
 M:RebuildIndexes();jobs();M.mailOpen=true;M:ObserveMail();jobs();local n=#M.db.ledger
 local e=M.db.ledger[n];assert(e.kind=='mail sale' and not e.booked and e.marketKey==5001)
 M:ObserveMail();jobs();assert(#M.db.ledger==n)
end)
check('50,000 rows process across frames; malformed row isolated',function()
 resetQueue();M.ahOpen=true;replicateRows=50000;M:StartSnapshotProcessing(50000,'fresh replicate request');local ticks=jobs()
 assert(ticks>350);assert(M.scanState.phase=='done');local s=M.db.latestScan
 assert(s.rawRows==50000 and s.auctionsProcessed==49999 and s.invalidRecords==1);assert(s.uniqueItems==1500)
 assert(M.db.market[5001],'absent market retained');assert(s.marketScanID and M.db.marketStats.storedMarkets>=1501)
 print('50k scan job ticks: '..ticks..'; synthetic-budget elapsed ms: '..s.processingMS)
end)
check('Oversized price distribution retains history and blocks trading',function()
 local old=M.db.market[5001];M:FinalizeMarketScan({[5001]={analysisIncomplete=true}},{skippedMarkets=0,modelErrors=0},function()end);jobs()
 assert(M.db.market[5001]==old and old.analysisIncomplete);assert(not M:MakeOpportunity(old));old.analysisIncomplete=nil
end)
check('UI builds and every terminal tab renders',function()
 M:InitializeUI()
 for _,v in ipairs({'market','opportunities','execution','selling','my auctions','ledger','settings','diagnostics'}) do M:SetView(v);jobs();M:RenderUI() end
 M:ShowReport();assert(M.reportEdit:GetText():find('VOIDMARK MARKET',1,true))
end)
check('Protocol boundary rejects malformed or stale summaries',function()
 assert(not M.Sync:ValidateSummary({version=2,itemID=1,price=1,at=time(),economy='x'},time()))
 assert(M.Sync:ValidateSummary({version=1,itemID=1,price=1,at=time(),economy='x'},time()))
end)
check('Cached snapshot after cooldown cannot refresh model history',function()
 mk();local count=market.totalObservations;local seen=market.lastSeen;advance(2000)
 M:FinalizeMarketScan({[5001]={itemID=5001,marketKey=5001,quantity=1,listings=1,floorUnitPrice=1,ceilingUnitPrice=1,priceLevels={[1]=1}}},{source='cached snapshot',skippedMarkets=0,modelErrors=0},function()end);jobs()
 assert(market.totalObservations==count and market.lastSeen==seen)
end)
check('Bogus regular-auction quantities are capped to item stack size',function()
 resetQueue();mk();local result;M:Search(market,100,function(r)result=r end);M:PumpQueue()
 searchRows={{auctionID=77,quantity=100,buyoutAmount=500}}
 emit('ITEM_SEARCH_RESULTS_UPDATED',M:ItemKey(market));jobs();assert(result.rows[1].quantity==1 and result.rows[1].unit==500)
end)
check('Newer schemas remain untouched and cannot trade',function()
 local saved=VoidMarkMarketDB;VoidMarkMarketDB={schemaVersion=99,marker='keep'};M:InitializeDatabase();jobs()
 assert(VoidMarkMarketDB.schemaVersion==99 and VoidMarkMarketDB.marker=='keep');assert(M.persistenceBlocked)
 VoidMarkMarketDB=saved;M.persistenceBlocked=nil;M:InitializeDatabase();jobs()
end)
check('Unresolved orders survive reload and share ledger identity',function()
 resetQueue();local p={id=888,character=M.characterID,marketKey=5001,itemID=5001,name='Ritual Gloves',quantity=1,cost=500,status='pending'}
 M.db.pending[888]=p;M.db.ledger[#M.db.ledger+1]={id=888,status='pending',name='independent copy'}
 M:InitializeDatabase();jobs();assert(p.status=='unknown');assert(M.db.ledger[#M.db.ledger]==p)
 M:ReviewPending(p,false);assert(p.status=='failed' and not M.db.pending[888])
end)
check('AH close during processing cancels scan publication',function()
 resetQueue();M:StartSnapshotProcessing(50000,'fresh replicate request');M:RunJobs();emit('AUCTION_HOUSE_CLOSED')
 assert(not M.jobs.scan and not M.jobs.model and not M.jobs['scan-finish']);assert(M.scanState.phase=='aborted');jobs();emit('AUCTION_HOUSE_SHOW')
end)
check('Changed live prices must still pass economics',function()
 resetQueue();commodity=false;mk();M:RebuildIndexes();jobs();local o=M:MakeOpportunity(market);M:SelectOpportunity(o);M:RevalidateSelected(1);M:PumpQueue()
 searchRows={{auctionID=99,quantity=1,buyoutAmount=4600}}
 emit('ITEM_SEARCH_RESULTS_UPDATED',M:ItemKey(market));jobs();assert(M.execution.state=='invalid')
end)
check('Fresh-result completeness is mandatory',function()
 resetQueue();mk();local old=C_AuctionHouse.HasFullItemSearchResults;C_AuctionHouse.HasFullItemSearchResults=nil;local failed
 M:Search(market,100,function()error('unsafe')end,function(e)failed=e end);M:PumpQueue();emit('ITEM_SEARCH_RESULTS_UPDATED',M:ItemKey(market));assert(failed)
 C_AuctionHouse.HasFullItemSearchResults=old
end)
check('Aborted commodity quote enforces a stale-event guard',function()
 selectReady(true,1);M.db.settings.safeMode=false;M:ExecuteClicked();M:InvalidateQuote('discard');local untilTime=M.db.quoteGuardUntil;assert(untilTime>time())
 M:RevalidateSelected(1);M:PumpQueue();advance(0.4);M:PumpQueue();searchRows={{unitPrice=500,quantity=10}};emit('COMMODITY_SEARCH_RESULTS_UPDATED',5001);jobs()
 local n=#calls;M:ExecuteClicked();assert(#calls==n);assert(M.execution.state=='ready')
end)
check('Expired/cancelled mailbox subjects are observations, not sales',function()
 local oldInvoice=GetInboxInvoiceInfo;local oldHeader=GetInboxHeaderInfo
 GetInboxInvoiceInfo=function() return nil end
 GetInboxHeaderInfo=function() return nil,nil,'Auction House','Auction expired: Ritual Gloves',0 end
 M.mailOpen=true;M:ObserveMail();jobs();local e=M.db.ledger[#M.db.ledger];assert(e.kind=='mail expired' and not e.booked)
 local n=#M.db.ledger;M:ObserveMail();jobs();assert(#M.db.ledger==n)
 GetInboxInvoiceInfo=oldInvoice;GetInboxHeaderInfo=oldHeader
end)
check('Reviewed actual sales feed future fair value conservatively',function()
 mk();market.bookedSales={{at=time(),price=2000,quantity=1},{at=time(),price=2000,quantity=1},{at=time(),price=2000,quantity=1}}
 local before=market.fairValue;advance(1000)
 M:UpdateMarketFromGroup({itemID=5001,marketKey=5001,quantity=21,listings=21,floorUnitPrice=500,ceilingUnitPrice=5000,priceLevels={[500]=1,[4500]=10,[5000]=10}},99,time())
 assert(market.fairValue<before and market.recordedSaleSamples==3);assert(market.fairValue>3500)
end)
check('Winning bid is used instead of advertised buyout; payout checked',function()
 local oldInvoice=GetInboxInvoiceInfo;local oldHeader=GetInboxHeaderInfo
 GetInboxInvoiceInfo=function() return 'seller','Ritual Gloves','Bidder',1000,5000,10,50,0,0,0,1 end
 GetInboxHeaderInfo=function() return nil,nil,'Auction House','Auction successful: Ritual Gloves',960 end
 M.mailOpen=true;M:ObserveMail();jobs();local e=M.db.ledger[#M.db.ledger];assert(e.gross==1000 and e.invoiceVerified)
 GetInboxInvoiceInfo=function() return 'seller','Ritual Gloves','Other bidder',1000,5000,10,50,0,0,0,1 end
 GetInboxHeaderInfo=function() return nil,nil,'Auction House','Auction successful: Ritual Gloves',123 end
 M:ObserveMail();jobs();e=M.db.ledger[#M.db.ledger];assert(not e.invoiceVerified)
 GetInboxInvoiceInfo=oldInvoice;GetInboxHeaderInfo=oldHeader
end)
print('ALL '..total..' TESTS PASSED')
