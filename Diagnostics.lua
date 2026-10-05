local _,M=...
function M:BuildTextReport()
  local q=self.queue; local s=self.scanState; local b=self.db.currentBuild
  local lines={'VOIDMARK MARKET '..self.version,'Client '..tostring(b.version)..' | build '..tostring(b.build)..' | interface '..tostring(b.tocVersion),
    'Economy '..self.economyID..' | schema '..self.root.schemaVersion,
    'Persistence marker loaded: '..tostring(self.loadedSavedMarker)..' (first install is unverified; check again after /reload)',
    'SAFE MODE '..tostring(self.db.settings.safeMode)..' | AH open '..tostring(self.ahOpen)..' | throttle ready '..tostring(self:ThrottleReady()),
    'Scanner '..s.phase..': '..s.status,
    'Queue waiting '..#q.waiting..' | active '..tostring(q.active and q.active.id)..' | sent '..q.stats.sent..' | retries '..q.stats.retries..' | timeouts '..q.stats.timeouts..' | dropped '..q.stats.dropped,
    'Execution '..self.execution.state..': '..self.execution.message,
    'Markets '..#(self.marketIndex or {})..' | opportunities '..#self.db.opportunities..' | ledger '..#self.db.ledger,
    'No automatic transactions. Pricing is an estimate; activity is inferred supply movement.'}
  local scan=self.db.latestScan
  if scan then
    for _,k in ipairs({'source','requestedAt','startedAt','completedAt','rawRows','auctionsProcessed','invalidRecords','incompleteRecords','uniqueItems','uniqueBaseItems','totalQuantity','processingMS','marketScanID','skippedMarkets','modelErrors'}) do lines[#lines+1]=k..': '..tostring(scan[k]) end
  end
  if self.db.api then
    lines[#lines+1]='API functions '..self.db.api.present..' / '..self.db.api.total
    for _,r in ipairs(self.db.api.results or {}) do if not r.present then lines[#lines+1]='MISSING '..r.path end end
    for _,r in ipairs(self.db.api.events or {}) do if not r.supported then lines[#lines+1]='UNSUPPORTED EVENT '..r.event end end
  end
  for i=math.max(1,#self.runtimeLog-30),#self.runtimeLog do local e=self.runtimeLog[i]; lines[#lines+1]=e.kind..': '..e.message end
  return table.concat(lines,'\n')
end
