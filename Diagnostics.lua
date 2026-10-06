local _,M=...
function M:BuildFullScanReport()
  local d=self.db.fullScanDiagnostic
  if not d then return 'FULL SCAN DIAGNOSTICS\nNo full-scan request recorded yet.' end
  local lines={'FULL SCAN DIAGNOSTICS',
    'Request API: '..tostring(d.api)..' | dataset: replicate snapshot (legacy list pages are trace only)',
    'State: '..tostring(d.phase)..' | 60s response wait / 180s grace deadline / no automatic retry',
    'Events: '..tostring(d.eventCount)..' total, '..tostring(d.replicateEvents)..' replicate, '..tostring(d.legacyEvents)..' legacy list',
    'Last event: '..tostring(d.lastEvent)..' | replicate rows: '..tostring(d.lastReplicateRows),
    'Queued: '..tostring(d.queuedAt)..' | sent: '..tostring(d.sentAt)..' | cached rows before send: '..tostring(d.baselineRows),
    'Response: '..tostring(d.responseAt)..' | delay: '..tostring(d.responseSeconds)..'s | rows: '..tostring(d.responseRows),
    'Parse start: '..tostring(d.parseStartedAt)..' | parse finish: '..tostring(d.parseFinishedAt)..' | parse: '..tostring(d.parseMS)..'ms',
    'Completed: '..tostring(d.completedAt)..' | total processing: '..tostring(d.processingMS)..'ms | recovered late: '..tostring(d.recoveredLate==true)}
  if d.error then lines[#lines+1]='Failure: '..d.error end
  if d.baselineError then lines[#lines+1]='Pre-request count error: '..d.baselineError end
  if d.validRows then lines[#lines+1]='Results: '..d.validRows..' valid / '..tostring(d.invalidRows)..' invalid / '..tostring(d.markets)..' markets / '..tostring(d.candidates)..' candidates' end
  if self.scanState.fullScanDiagnostic~=d then lines[#lines+1]='Saved diagnostic record; no response recovery is active in this session.' end
  if d.lastCountError then lines[#lines+1]='Count error: '..d.lastCountError end
  if self.queue.lateReplicate then lines[#lines+1]='Still listening in this AH session; keep AH open. A late replicate event can recover this scan.' end
  lines[#lines+1]='Timestamps are Unix seconds; event delays use the monotonic client clock.'
  for _,e in ipairs(d.events or {}) do
    lines[#lines+1]=string.format('%s | %s | +%ss | replicate=%s | list=%s/%s | %s',
      tostring(e.at),e.event,tostring(e.elapsed),tostring(e.replicateRows),tostring(e.listRows),tostring(e.listTotal),e.disposition)
    if e.countError then lines[#lines+1]='  '..e.countError end
    if e.listError then lines[#lines+1]='  '..e.listError end
  end
  return table.concat(lines,'\n')
end
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
  lines[#lines+1]=self:BuildFullScanReport()
  local scan=self.db.latestScan
  if scan then
    for _,k in ipairs({'source','requestedAt','startedAt','completedAt','rawRows','auctionsProcessed','invalidRecords','incompleteRecords','uniqueItems','uniqueBaseItems','totalQuantity','processingMS','responseAt','responseSeconds','parseMS','marketScanID','skippedMarkets','modelErrors'}) do lines[#lines+1]=k..': '..tostring(scan[k]) end
  end
  if self.db.api then
    lines[#lines+1]='API functions '..self.db.api.present..' / '..self.db.api.total
    for _,r in ipairs(self.db.api.results or {}) do if not r.present then lines[#lines+1]='MISSING '..r.path end end
    for _,r in ipairs(self.db.api.events or {}) do if not r.supported then lines[#lines+1]='UNSUPPORTED EVENT '..r.event end end
  end
  for i=math.max(1,#self.runtimeLog-30),#self.runtimeLog do local e=self.runtimeLog[i]; lines[#lines+1]=tostring(e.at)..' '..e.kind..': '..e.message end
  return table.concat(lines,'\n')
end
