local _,M=...
-- Versioned boundary for future summaries. No traffic, no transactions, no remote history ingestion.
M.Sync={protocol=1,maxMessage=220,minInterval=2,enabled=false}
function M.Sync:ValidateSummary(s,now)
  return type(s)=='table' and s.version==self.protocol and type(s.itemID)=='number' and s.itemID>0
    and type(s.price)=='number' and s.price>0 and s.price<1e12 and type(s.at)=='number'
    and s.at<=now+60 and s.at>=now-7200 and type(s.economy)=='string' and #s.economy<=100
end
