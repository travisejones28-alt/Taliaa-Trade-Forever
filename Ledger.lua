local _,M=...
function M:AddLedger(kind,data)
  local db=self.db; db.ledgerSequence=db.ledgerSequence+1
  data=data or {}; data.id=db.ledgerSequence; data.kind=kind; data.at=time(); data.character=data.character or self.characterID
  db.ledger[#db.ledger+1]=data
  -- Compact history only. Lifetime aggregates and unresolved orders are separate.
  while #db.ledger>2000 do table.remove(db.ledger,1) end
  self:RefreshUI(); return data
end
function M:ReservePurchase(x)
  local entry=self:AddLedger('purchase',{marketKey=x.market.marketKey,itemID=x.market.itemID,name=x.market.name,
    quantity=x.live.quantity,cost=x.live.cost,status='pending',evidence='request issued',commodity=x.commodity,
    auctionID=x.live.auctionID,transaction=x.token})
  self.db.pending[entry.id]=entry; self.exposureDirty=true; x.order=entry; return entry
end
function M:ResolvePurchase(p,status,evidence)
  if not p or (p.status~='pending' and p.status~='unknown') then return end
  p.status=status; p.evidence=evidence; p.resolvedAt=time()
  if status=='confirmed' then
    local key=self:InventoryKey(p.marketKey); local lot=self.db.inventory[key]
    if not lot then lot={marketKey=p.marketKey,character=self.characterID,quantity=0,cost=0,purchasedQty=0,purchasedCost=0}; self.db.inventory[key]=lot end
    lot.quantity=lot.quantity+p.quantity; lot.cost=lot.cost+p.cost
    lot.purchasedQty=lot.purchasedQty+p.quantity; lot.purchasedCost=lot.purchasedCost+p.cost
    self.db.totals.purchaseCost=(self.db.totals.purchaseCost or 0)+p.cost
  end
  self.db.pending[p.id]=nil; self.exposureDirty=true; self:RebuildOpportunities(); self:RefreshUI()
end
function M:LedgerTotals()
  local t=self.db.totals; local out={revenue=t.revenue or 0,fees=t.fees or 0,costBasis=t.costBasis or 0,
    realized=t.realized or 0,uncostedRevenue=t.uncostedRevenue or 0,saleQuantity=t.saleQuantity or 0,
    gross=t.gross or 0,inventory=0,reserved=0,roi=(t.costBasis or 0)>0 and (t.realized or 0)/t.costBasis or 0}
  for _,lot in pairs(self.db.inventory) do out.inventory=out.inventory+(lot.cost or 0) end
  for _,p in pairs(self.db.pending) do out.reserved=out.reserved+p.cost end
  return out
end
function M:BookSale(entry)
  if not entry or entry.kind~='mail sale' or entry.booked or not entry.invoiceVerified or entry.character~=self.characterID then return false end
  local m=entry.marketKey and self.db.market[entry.marketKey]
  if not m or not entry.quantity or entry.quantity<1 or not entry.gross or entry.gross<0 then return false end
  local key=self:InventoryKey(entry.marketKey); local lot=self.db.inventory[key]
  local qty=entry.quantity; local matched=lot and math.min(qty,lot.quantity) or 0
  local basis=matched>0 and lot.cost*matched/lot.quantity or 0
  if lot and matched>0 then lot.quantity=lot.quantity-matched; lot.cost=math.max(0,lot.cost-basis) end
  local net=entry.gross-entry.fee; local knownRevenue=net*matched/qty
  self.exposureDirty=true
  entry.booked=true; entry.matchedQuantity=matched; entry.costBasis=basis
  entry.realized=matched==qty and net-basis or nil
  entry.evidence='Invoice observed; duplicate identity and item mapping reviewed by user'
  m.bookedSales=m.bookedSales or {}
  m.bookedSales[#m.bookedSales+1]={at=time(),price=entry.gross/qty,quantity=qty}
  if #m.bookedSales>30 then table.remove(m.bookedSales,1) end
  m.actualSaleUnits=(m.actualSaleUnits or 0)+qty
  local t=self.db.totals
  t.revenue=(t.revenue or 0)+net; t.gross=(t.gross or 0)+entry.gross; t.fees=(t.fees or 0)+entry.fee
  t.saleQuantity=(t.saleQuantity or 0)+qty; t.costBasis=(t.costBasis or 0)+basis
  t.realized=(t.realized or 0)+knownRevenue-basis
  t.uncostedRevenue=(t.uncostedRevenue or 0)+net-knownRevenue
  -- Invoice deposit is refunded capital, never profit/revenue. Unknown posting deposits are not fabricated.
  self:RebuildOpportunities(); self:RefreshUI(); return true
end
function M:UniqueMarketByName(name)
  return self.nameIndex and self.nameIndex[name] or nil
end
function M:RememberMail(fingerprint,rank)
  if not self.db.mailSeen[fingerprint] then
    self.db.mailOrder=self.db.mailOrder or {}; self.db.mailOrder[#self.db.mailOrder+1]=fingerprint
    if #self.db.mailOrder>5000 then self.db.mailSeen[table.remove(self.db.mailOrder,1)]=nil end
  end
  self.db.mailSeen[fingerprint]=rank
end
function M:MailOutcome(subject)
  if type(subject)~='string' then return nil end
  local definitions={{'expired','AUCTION_EXPIRED_MAIL_SUBJECT','Auction expired: %s'},
    {'cancelled','AUCTION_REMOVED_MAIL_SUBJECT','Auction cancelled: %s'},
    {'won','AUCTION_WON_MAIL_SUBJECT','Auction won: %s'},
    {'outbid','AUCTION_OUTBID_MAIL_SUBJECT','Outbid on %s'}}
  for _,d in ipairs(definitions) do
    local template=_G[d[2]] or d[3]; local prefix,suffix=template:match('^(.-)%%s(.*)$')
    if prefix then
      prefix=prefix:gsub('(%W)','%%%1'); suffix=suffix:gsub('(%W)','%%%1')
      local name=subject:match('^'..prefix..'(.-)'..suffix..'$')
      if name then return d[1],name end
    end
  end
end
function M:ObserveMail()
  if not self.mailOpen or not GetInboxNumItems or not GetInboxHeaderInfo then return end
  local n=GetInboxNumItems(); local occurrence={}; local i=1
  self:AddJob('mail',function(start)
    for j=1,12 do
      if i>n then return true end
      local index=i; i=i+1
      local ok,kind,name,player,bid,buyout,deposit,fee,delay,hour,minute,qty=pcall(GetInboxInvoiceInfo,index)
      if ok and (kind=='seller' or kind=='buyer' or kind=='seller_temp_invoice') then
        local _,_,sender,subject,money=GetInboxHeaderInfo(index)
        local fingerprint=table.concat({self.characterID,kind,tostring(name),tostring(player),tostring(bid),tostring(buyout),tostring(deposit),tostring(fee),tostring(qty)},'|')
        occurrence[fingerprint]=(occurrence[fingerprint] or 0)+1
        local rank=occurrence[fingerprint]; local seen=self.db.mailSeen[fingerprint] or 0
        if rank>seen then
          -- Invoice API has no unique mail/auction ID. Review before financial booking.
          local e=self:AddLedger(kind=='seller' and 'mail sale' or kind=='buyer' and 'mail won' or 'mail pending',{
            name=name,quantity=tonumber(qty),gross=(tonumber(bid) or 0)>0 and tonumber(bid) or tonumber(buyout),
            fee=tonumber(fee) or 0,depositRefund=tonumber(deposit) or 0,money=tonumber(money),
            subject=subject,marketKey=self:UniqueMarketByName(name),invoiceVerified=kind=='seller',
            status='observed',evidence='Mailbox invoice; identity requires review; not yet booked',mailFingerprint=fingerprint})
          if kind=='seller' and e.gross and e.money and math.abs(e.gross-e.fee+e.depositRefund-e.money)>1 then
            e.invoiceVerified=false; e.evidence='Observed invoice; payout disagrees with invoice amounts, financial booking blocked'
          end
          self:RememberMail(fingerprint,rank)
        end
      else
        local _,_,sender,subject,money=GetInboxHeaderInfo(index)
        local outcome,itemName=self:MailOutcome(subject)
        if outcome and sender==(_G.AUCTION_HOUSE_MAIL_SENDER or _G.AUCTION_HOUSE or 'Auction House') then
          local fingerprint=self.characterID..'|'..outcome..'|'..subject
          occurrence[fingerprint]=(occurrence[fingerprint] or 0)+1; local rank=occurrence[fingerprint]
          if rank>(self.db.mailSeen[fingerprint] or 0) then
            self:AddLedger('mail '..outcome,{name=itemName,marketKey=self:UniqueMarketByName(itemName),status='observed',
              evidence='Observed system AH mail subject; no unique auction ID, cost or deposit inferred',subject=subject,money=tonumber(money)})
            self:RememberMail(fingerprint,rank)
          end
        end
      end
      if debugprofilestop()-start>=4 then return false end
    end
  end)
end
M:RegisterHandler('MAIL_SHOW',function(self) self.mailOpen=true; self:ObserveMail() end)
M:RegisterHandler('MAIL_INBOX_UPDATE',function(self) self:ObserveMail() end)
M:RegisterHandler('MAIL_CLOSED',function(self) self.mailOpen=false; self:CancelJob('mail') end)
function M:ReviewPending(entry,succeeded)
  if not entry or entry.character~=self.characterID or (entry.status~='pending' and entry.status~='unknown') then return end
  if entry.commodity then self.db.quoteGuardUntil=time()+120 end
  self:ResolvePurchase(entry,succeeded and 'confirmed' or 'failed','User reported outcome after checking AH/mail; not API confirmation')
  if self.execution and self.execution.order==entry then self.execution.state='idle' end
end
