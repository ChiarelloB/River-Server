-- RiverLife BeamMP server plugin. Original code.
-- Authoritative ledger for the River server: classifieds, dealerships,
-- workshops, NPC visits, messages and the online player directory.
local ROOT = 'Resources/Server/RiverLife/'
local Domain = dofile(ROOT .. 'domain.lua')
local Wire = dofile(ROOT .. 'wire.lua')

local cfg, market
local identities, bindings, uploads, rates, photoIndex, guestTokens = {}, {}, {}, {}, {}, {}
local presence, slots, requestChunks = {}, {}, {}
local displayHosts, displaySent, lastSpotsAsk = {}, {}, 0
local blobCache = {}
local messageSequence, blobSequence, timerTicks = 0, 0, 0
local dirty = false

local DEFAULTS = {
  trustCareerImports = true, allowGuestTokens = true, map = 'west_coast_usa', maxPhotoBytes = 524288,
  npcIntervalSeconds = 150, npcSellerIntervalSeconds = 300, npcCustomerIntervalSeconds = 200,
  npcOwnerRadius = 250, presenceSeconds = 2, backupsToKeep = 3, welcomeMessage = true,
}

local function log(msg) print('[RiverLife] ' .. msg) end
local function read(path)
  local f = io.open(path, 'rb'); if not f then return nil end
  local bytes = f:read('*a'); f:close()
  local ok, data = pcall(Util.JsonDecode, bytes)
  return ok and data or nil
end
local function encode(v) return Util.JsonEncode(v) end
local function write(path, data)
  local f = assert(io.open(path, 'wb')); assert(f:write(encode(data))); assert(f:flush()); assert(f:close())
end
local function writeAtomic(path, data)
  local temp = path .. '.tmp'
  write(temp, data)
  assert(read(temp) ~= nil, 'unreadable write')
  if FS.Exists(path) then FS.Remove(path) end
  local ok, err = FS.Rename(temp, path); assert(ok, err)
end

-- State generations ---------------------------------------------------------------
local function loadState()
  local latest, revision = nil, -1
  for _, file in pairs(FS.ListFiles(ROOT .. 'data')) do
    local name = FS.GetFilename(file)
    local r = tonumber(name:match('^state%.(%d+)%.json$'))
    if r and r > revision then
      local state = read(ROOT .. 'data/' .. name)
      if state and state.revision == r then latest = state; revision = r end
    end
  end
  return latest
end
local function save(state)
  local name = 'state.' .. string.format('%d', state.revision) .. '.json'
  local temp = ROOT .. 'data/' .. name .. '.tmp'
  write(temp, state)
  assert(read(temp).revision == state.revision)
  local ok, err = FS.Rename(temp, ROOT .. 'data/' .. name); assert(ok, err)
  for _, file in pairs(FS.ListFiles(ROOT .. 'data')) do
    local base = FS.GetFilename(file)
    local r = tonumber(base:match('^state%.(%d+)%.json$'))
    if r and r < state.revision - (cfg.backupsToKeep or 3) then os.remove(ROOT .. 'data/' .. base) end
  end
  dirty = true
  return true
end
local function putBlob(data)
  blobSequence = blobSequence + 1
  local ref = 'b' .. os.time() .. '-' .. blobSequence .. '-' .. Util.RandomIntRange(1000, 9999)
  writeAtomic(ROOT .. 'data/blobs/' .. ref .. '.json', data)
  blobCache[ref] = nil
  return ref
end
local function getBlob(ref)
  if type(ref) ~= 'string' or not ref:match('^[%w%-]+$') then return nil end
  if blobCache[ref] then return blobCache[ref] end
  local data = read(ROOT .. 'data/blobs/' .. ref .. '.json')
  blobCache[ref] = data
  return data
end
local function collectBlobs()
  local used = {}
  for _, a in pairs(market.state.assets) do if a.dataRef then used[a.dataRef] = true end end
  for _, r in pairs(market.state.receipts) do if r.dataRef then used[r.dataRef] = true end end
  local removed = 0
  for _, file in pairs(FS.ListFiles(ROOT .. 'data/blobs')) do
    local name = FS.GetFilename(file)
    local ref = name:match('^(.-)%.json$')
    if ref and not used[ref] then os.remove(ROOT .. 'data/blobs/' .. name); blobCache[ref] = nil; removed = removed + 1 end
  end
  return removed
end

-- Players, vehicles and positions ---------------------------------------------------
local function pos(pid, vid)
  if not pid or not vid then return nil end
  local raw = MP.GetPositionRaw(pid, tonumber(vid))
  if type(raw) ~= 'table' or type(raw.pos) ~= 'table' then return nil end
  return {x = raw.pos[1], y = raw.pos[2], z = raw.pos[3]}
end
local function pidFor(account)
  for pid, id in pairs(identities) do if id == account and MP.IsPlayerConnected(pid) then return pid end end
end
local function playerPos(pid)
  local b = pid and bindings[pid]
  return b and pos(pid, b.playerVehicleId)
end
local function localVehiclePos(account, localId)
  local pid = pidFor(account); local b = pid and bindings[pid]
  return b and localId and b.vehicles[tostring(localId)] and pos(pid, b.vehicles[tostring(localId)])
end
local function npcPos(npcId)
  local n = market.state.npcs[npcId]; if not n then return nil end
  local pid = pidFor(n.owner); local b = pid and bindings[pid]
  return b and b.npcs[npcId] and pos(pid, b.npcs[npcId])
end
local function validVehicle(pid, vid)
  return type(vid) == 'number' and MP.GetPlayerVehicles(pid) and MP.GetPlayerVehicles(pid)[vid] ~= nil
end

-- Transport ------------------------------------------------------------------------
local function transmit(pid, event, value)
  local bytes = encode(value)
  if #bytes < 48000 and not bytes:find('Zp', 1, true) then MP.TriggerClientEvent(pid, event, bytes); return end
  if #bytes > Wire.maxBytes then log('message exceeds transport limit for ' .. event); return end
  messageSequence = messageSequence + 1
  local id = tostring(os.time()) .. '-' .. messageSequence
  local encoded = Wire.encode64(bytes)
  for offset = 1, #encoded, Wire.chunkSize do
    MP.TriggerClientEvent(pid, 'RLChunk', encode({id = id, event = event, total = #encoded, offset = offset,
      chunk = encoded:sub(offset, offset + Wire.chunkSize - 1)}))
  end
end
local function send(pid, response) transmit(pid, 'RLReply', response) end
local function broadcast()
  dirty = false
  for pid, id in pairs(identities) do
    if MP.IsPlayerConnected(pid) and market.state.accounts[id] then transmit(pid, 'RLState', market:snapshot(id)) end
  end
end

-- Request context: the server measures positions itself; clients cannot fake them.
local function context(pid, request)
  local id = identities[pid]
  local c = {name = (presence[pid] and presence[pid].displayName) or MP.GetPlayerName(pid),
    allowImport = cfg.trustCareerImports == true, map = cfg.map, position = playerPos(pid),
    hour = tonumber(presence[pid] and presence[pid].hour) or 12}
  local s = market.state
  local p = request.payload or {}
  local l = s.listings[p.listingId]
  local v = s.visits[p.visitId]
  local o = s.offers[p.offerId]
  if o then v = s.visits[o.visitId] end
  if v then l = s.listings[v.listingId] end
  if l then
    c.sellerPosition = playerPos(pidFor(l.seller))
    local a = s.assets[l.assetId]
    c.vehiclePosition = a and localVehiclePos(a.owner, a.localId)
    local buyer = v and v.buyer
    c.buyerPosition = buyer and playerPos(pidFor(buyer))
    if buyer and s.npcs[buyer] then c.buyerPosition = npcPos(buyer) end
  end
  local order = s.orders[p.orderId]
  if order then
    if s.npcs[order.customer] then c.vehiclePosition = npcPos(order.customer)
    else c.vehiclePosition = localVehiclePos(order.customer, order.vehicle and order.vehicle.localId) end
  end
  if request.op == 'serviceRequest' and type(p.vehicle) == 'table' then
    c.vehiclePosition = localVehiclePos(id, p.vehicle.localId)
  end
  if request.op == 'stockIn' or request.op == 'streetSell' then
    local a = s.assets[p.assetId]
    c.vehiclePosition = a and localVehiclePos(id, a.localId)
  end
  if request.op == 'displayPhoto' then c.displayHost = displayHosts[p.listingId] == pid end
  if request.op == 'gigDeliver' then
    local b = bindings[pid]
    c.vehiclePosition = b and b.gigs and b.gigs[tostring(p.gigId)] and pos(pid, b.gigs[tostring(p.gigId)])
  end
  local pr = presence[pid]
  if pr and pr.heading then c.heading = pr.heading end
  return c
end

local function identity(pid, p)
  local identifiers = MP.GetPlayerIdentifiers(pid) or {}
  if not MP.IsPlayerGuest(pid) and identifiers.beammp then return 'beammp:' .. tostring(identifiers.beammp) end
  -- Guests get a stable identity bound to a secret token stored in their profile.
  if cfg.allowGuestTokens and type(p.guestToken) == 'string' and #p.guestToken == 64 and p.guestToken:match('^[a-f0-9]+$') then
    if not guestTokens[p.guestToken] then
      guestTokens[p.guestToken] = 'guest:' .. tostring(Util.RandomIntRange(100000000, 999999999)) .. '-' .. tostring(os.time())
      write(ROOT .. 'data/guest-identities.json', guestTokens)
    end
    return guestTokens[p.guestToken]
  end
end

local function rate(pid, limit)
  local t = os.time(); local r = rates[pid]
  if not r or r.at ~= t then r = {at = t, count = 0}; rates[pid] = r end
  r.count = r.count + 1
  return r.count <= (limit or 40)
end

local READS = {snapshot = true, delivery = true, displayData = true, bind = true, hello = true}
local SYSTEM_OPS = {npcCreate = 'buyer', npcSellerCreate = 'seller', npcCustomerCreate = 'customer'}
local NPC_OPS = {npcArrive = true, npcReply = true}
local SERVER_ONLY = {tick = true}

function RLRequest(pid, bytes)
  if type(bytes) ~= 'string' or #bytes > Wire.maxBytes or not rate(pid) then return end
  local ok, r = pcall(Util.JsonDecode, bytes)
  if not ok or type(r) ~= 'table' or type(r.id) ~= 'string' or type(r.op) ~= 'string' then return end
  if r.op == 'hello' then
    local id = identity(pid, r.payload or {})
    if not id then send(pid, {id = r.id, ok = false, error = 'identity_required'}); return end
    identities[pid] = id
    bindings[pid] = bindings[pid] or {vehicles = {}, npcs = {}}
  end
  local id = identities[pid]
  if not id then send(pid, {id = r.id, ok = false, error = 'hello_required'}); return end
  -- Every change is copied, saved and broadcast: a player gets a few per second, reads are free.
  if not READS[r.op] and not rate('w' .. pid, 8) then send(pid, {id = r.id, ok = false, error = 'rate_limited'}); return end
  local p = type(r.payload) == 'table' and r.payload or {}
  if r.op == 'bind' then
    local b = bindings[pid]
    if validVehicle(pid, p.playerVehicleId) then b.playerVehicleId = p.playerVehicleId end
    if type(p.vehicles) == 'table' then
      b.vehicles = {}
      for localId, vid in pairs(p.vehicles) do
        if validVehicle(pid, vid) then b.vehicles[tostring(localId)] = vid end
      end
    end
    if type(p.npcs) == 'table' then
      b.npcs = {}
      for npcId, vid in pairs(p.npcs) do
        local n = market.state.npcs[npcId]
        if n and n.owner == id and validVehicle(pid, vid) then b.npcs[npcId] = vid end
      end
    end
    if type(p.gigs) == 'table' then
      b.gigs = {}
      for gigId, vid in pairs(p.gigs) do
        local g = market.state.gigs[gigId]
        if g and g.taker == id and validVehicle(pid, vid) then b.gigs[tostring(gigId)] = vid end
      end
    end
    send(pid, {id = r.id, ok = true, data = {bound = true}}); return
  end
  if SERVER_ONLY[r.op] then send(pid, {id = r.id, ok = false, error = 'server_only'}); return end
  local ctx = context(pid, r)
  if SYSTEM_OPS[r.op] then
    local slot = slots[p.slot]
    if not slot or slot.pid ~= pid or slot.kind ~= SYSTEM_OPS[r.op] or slot.expires < os.time() then
      send(pid, {id = r.id, ok = false, error = 'npc_slot_expired'}); return
    end
    slots[p.slot] = nil
    ctx.system = true
  elseif NPC_OPS[r.op] then
    local n = market.state.npcs[p.npcId]
    if not n or n.owner ~= id then send(pid, {id = r.id, ok = false, error = 'npc_missing'}); return end
    ctx.system = true
    local np = npcPos(n.id)
    if r.op == 'npcArrive' then
      local target = n.position
      if n.visitId and market.state.visits[n.visitId] then target = market.state.visits[n.visitId].position end
      if not np or Domain.distance(np, target) > 30 then send(pid, {id = r.id, ok = false, error = 'npc_not_arrived'}); return end
      ctx.position = np; ctx.buyerPosition = np
      if n.kind == 'buyer' then
        local v = market.state.visits[n.visitId]
        local l = v and market.state.listings[v.listingId]
        local a = l and market.state.assets[l.assetId]
        ctx.sellerPosition = playerPos(pid)
        ctx.vehiclePosition = a and localVehiclePos(a.owner, a.localId)
      end
    else
      ctx.buyerPosition = np
    end
  end
  local result = market:dispatch(id, r, ctx)
  send(pid, result)
  if result.ok and result.revision then dirty = true end  -- read-only answers carry no revision
end

function RLRequestChunk(pid, bytes)
  if type(bytes) ~= 'string' or #bytes > 18000 or not rate(pid, 80) or not identities[pid] then return end
  local ok, p = pcall(Util.JsonDecode, bytes)
  if not ok or type(p) ~= 'table' then return end
  local key = tostring(pid) .. ':' .. tostring(p.id)
  if not requestChunks[key] then
    local count = 0
    for k in pairs(requestChunks) do if k:sub(1, #tostring(pid) + 1) == tostring(pid) .. ':' then count = count + 1 end end
    if count >= 3 then return end
  end
  local joined = Wire.accept(requestChunks, key, p, os.time())
  if joined then RLRequest(pid, joined) end
end

-- Photos are stored once on the server and fetched by id on demand.
function RLPhoto(pid, bytes)
  if type(bytes) ~= 'string' or #bytes > 18000 or not rate(pid, 80) then return end
  local id = identities[pid]; if not id then return end
  local ok, p = pcall(Util.JsonDecode, bytes)
  if not ok or type(p) ~= 'table' then return end
  if p.op == 'get' then
    local meta = photoIndex[p.photoId]
    if not meta then return end
    local f = io.open(ROOT .. 'photos/' .. meta.file, 'rb'); if not f then return end
    local data = f:read('*a'); f:close()
    for at = 1, #data, 12000 do
      MP.TriggerClientEvent(pid, 'RLPhotoData', encode({photoId = p.photoId, mime = meta.mime, total = #data,
        offset = at, chunk = data:sub(at, at + 11999)}))
    end
    return
  end
  if type(p.uploadId) ~= 'string' or not p.uploadId:match('^[a-f0-9]+$') or #p.uploadId ~= 32 then return end
  if type(p.total) ~= 'number' or p.total % 1 ~= 0 or p.total < 20 or p.total > math.ceil(cfg.maxPhotoBytes * 4 / 3) then return end
  if type(p.offset) ~= 'number' or p.offset % 1 ~= 0 or type(p.chunk) ~= 'string' or #p.chunk > 12000 or
    p.chunk:find('[^A-Za-z0-9+/_=]') then return end
  local key = id .. ':' .. p.uploadId
  local u = uploads[key]
  if not u then
    if p.offset ~= 1 then return end
    local count = 0
    for _, v in pairs(uploads) do if v.owner == id then count = count + 1 end end
    if count >= 6 then return end
    u = {owner = id, total = p.total, parts = {}, length = 0, at = os.time(), mime = p.mime}
    uploads[key] = u
  end
  if p.total ~= u.total then return end
  if p.offset == u.length + 1 then u.parts[#u.parts + 1] = p.chunk; u.length = u.length + #p.chunk end
  if u.length == u.total then
    local base64 = table.concat(u.parts)
    if (u.mime == 'image/png' and base64:sub(1, 11) == 'iVBORw0KGgo') or (u.mime == 'image/jpeg' and base64:sub(1, 3) == '/9j') then
      local file = id:gsub('[^%w%-]', '_') .. '-' .. p.uploadId .. '.b64'
      if not photoIndex[key] then
        local f = assert(io.open(ROOT .. 'photos/' .. file, 'wb')); assert(f:write(base64)); assert(f:close())
        photoIndex[key] = {owner = id, mime = u.mime, file = file, bytes = u.total, at = os.time()}
        write(ROOT .. 'photos/index.json', photoIndex)
      end
      MP.TriggerClientEvent(pid, 'RLPhotoAck', encode({uploadId = p.uploadId, photoId = key, mime = u.mime}))
    end
    uploads[key] = nil
  end
end

-- Presence: clients report what they drive; the server measures where.
function RLPresence(pid, bytes)
  if type(bytes) ~= 'string' or #bytes > 2000 or not rate(pid, 80) then return end
  local ok, p = pcall(Util.JsonDecode, bytes)
  if not ok or type(p) ~= 'table' then return end
  local b = bindings[pid]
  if b and validVehicle(pid, p.vehicleId) then b.playerVehicleId = p.vehicleId end
  local text = function(v, n) return type(v) == 'string' and v:sub(1, n) or nil end
  presence[pid] = {model = text(p.model, 64), niceName = text(p.niceName, 80), walking = p.walking == true,
    speed = tonumber(p.speed) or 0, heading = tonumber(p.heading), hour = tonumber(p.hour),
    activity = text(p.activity, 80), at = os.time(), displayName = presence[pid] and presence[pid].displayName}
end

local function presenceSnapshot()
  local list = {}
  local s = market.state
  for pid, name in pairs(MP.GetPlayers() or {}) do
    if MP.IsPlayerConnected(pid) then
      local id = identities[pid]
      local pr = presence[pid] or {}
      local entry = {pid = pid, name = name, account = id, position = playerPos(pid), model = pr.model,
        niceName = pr.niceName, walking = pr.walking, speed = pr.speed, heading = pr.heading, activity = pr.activity}
      if id then
        for _, st in pairs(s.stores) do if st.owner == id then entry.store = {id = st.id, name = st.name} end end
        for _, w in pairs(s.workshops) do if w.owner == id then entry.workshop = {id = w.id, name = w.name} end end
        local a = s.accounts[id]
        if a then entry.reputation = a.reputation; entry.sales = a.sales end
      end
      list[#list + 1] = entry
    end
  end
  return list
end

-- NPC slots: the server decides when a visit happens; the owner's client
-- describes the NPC within the bounds enforced by the domain.
local function offerSlot(pid, kind, extra)
  local token = tostring(Util.RandomIntRange(100000000, 999999999)) .. os.time()
  slots[token] = {pid = pid, kind = kind, expires = os.time() + 60}
  extra.slot = token; extra.kind = kind
  MP.TriggerClientEvent(pid, 'RLNpcSlot', encode(extra))
end
-- Business hours follow the owner's in-game clock (reported with presence).
local function hourFor(pid)
  return tonumber(presence[pid] and presence[pid].hour) or 12
end
local function scheduleNpcs(t)
  local s = market.state
  local busy, buyers, sellers = {}, {}, {}
  for _, n in pairs(s.npcs) do
    if n.status == 'travelling' or n.status == 'negotiating' or n.status == 'waiting' then
      local key = n.storeId or n.workshopId or ''
      busy[key] = (busy[key] or 0) + 1
      if n.kind == 'buyer' then buyers[key] = (buyers[key] or 0) + 1 end
      if n.kind == 'seller' then sellers[key] = (sellers[key] or 0) + 1 end
    end
  end
  -- Up to two buyers looking at the lot and one seller at a time per store.
  if t % cfg.npcIntervalSeconds == 0 then
    local ids = {}
    for lid in pairs(s.listings) do ids[#ids + 1] = lid end
    table.sort(ids)
    for _, lid in ipairs(ids) do
      local l = s.listings[lid]
      local st = l.storeId and s.stores[l.storeId]
      local pid = st and pidFor(st.owner)
      if pid and st.open and st.npcEnabled and l.status == 'active' and not l.reservation and (buyers[st.id] or 0) < 2
        and Domain.withinHours(st.opensAt, st.closesAt, hourFor(pid))
        and Domain.distance(playerPos(pid), st.position) < cfg.npcOwnerRadius then
        offerSlot(pid, 'buyer', {listingId = l.id, storeId = st.id, price = l.price})
        buyers[st.id] = (buyers[st.id] or 0) + 1
      end
    end
  end
  if t % cfg.npcSellerIntervalSeconds == 0 then
    for _, st in pairs(s.stores) do
      local pid = pidFor(st.owner)
      if pid and st.open and st.npcSellersEnabled and (sellers[st.id] or 0) == 0
        and Domain.withinHours(st.opensAt, st.closesAt, hourFor(pid))
        and Domain.distance(playerPos(pid), st.position) < cfg.npcOwnerRadius then
        offerSlot(pid, 'seller', {storeId = st.id, tradeBudget = st.tradeBudget})
        sellers[st.id] = 1
      end
    end
  end
  if t % cfg.npcCustomerIntervalSeconds == 0 then
    for _, w in pairs(s.workshops) do
      local pid = pidFor(w.owner)
      if pid and w.open and w.npcEnabled and (busy[w.id] or 0) <= w.bays
        and Domain.withinHours(w.opensAt, w.closesAt, hourFor(pid))
        and Domain.distance(playerPos(pid), w.position) < cfg.npcOwnerRadius then
        offerSlot(pid, 'customer', {workshopId = w.id, reputation = w.reputation})
      end
    end
  end
end

-- Cars on lots and by the road exist once, spawned by one nearby client and
-- synced by BeamMP to everyone. The store owner hosts their own lot when near;
-- otherwise the closest player does. Hosts stick until they leave the area.
local DISPLAY_RANGE = 450
local function assignDisplays()
  local s = market.state
  local players = {}
  for pid in pairs(MP.GetPlayers() or {}) do
    if MP.IsPlayerConnected(pid) and identities[pid] then
      local p = playerPos(pid)
      if p then players[#players + 1] = {pid = pid, pos = p, id = identities[pid]} end
    end
  end
  local wanted = {}
  for lid, l in pairs(s.listings) do
    if l.status == 'active' and l.display and l.map == cfg.map then
      local current = displayHosts[lid]
      local keep
      for _, pl in ipairs(players) do
        if pl.pid == current and Domain.distance(pl.pos, l.position) < DISPLAY_RANGE then keep = pl.pid end
      end
      local best, bestD
      if not keep then
        for _, pl in ipairs(players) do
          local d = Domain.distance(pl.pos, l.position)
          if pl.id == l.seller then d = d - 200 end
          if d < DISPLAY_RANGE and (not bestD or d < bestD) then best, bestD = pl.pid, d end
        end
      end
      local host = keep or best
      displayHosts[lid] = host
      if host then wanted[host] = wanted[host] or {}; table.insert(wanted[host], lid) end
    else
      displayHosts[lid] = nil
    end
  end
  for lid in pairs(displayHosts) do if not s.listings[lid] then displayHosts[lid] = nil end end
  for _, pl in ipairs(players) do
    local list = wanted[pl.pid] or {}
    table.sort(list)
    local key = table.concat(list, ',')
    if displaySent[pl.pid] ~= key then
      displaySent[pl.pid] = key
      MP.TriggerClientEvent(pl.pid, 'RLDisplays', encode({listings = list}))
    end
  end
end

-- The server knows no roads: clients report roadside spots for NPC sellers and jobs.
local function askForSpots(t)
  local spots = market.state.spots[cfg.map]
  if spots and #spots >= 40 then return end
  if t - lastSpotsAsk < 90 then return end
  local list = {}
  for pid in pairs(MP.GetPlayers() or {}) do if MP.IsPlayerConnected(pid) and identities[pid] then list[#list + 1] = pid end end
  if #list == 0 then return end
  lastSpotsAsk = t
  MP.TriggerClientEvent(list[Util.RandomIntRange(1, #list)], 'RLNeedSpots', encode({map = cfg.map, have = spots and #spots or 0}))
end

local function anyHour()
  for pid in pairs(presence) do if presence[pid].hour then return presence[pid].hour end end
  return 12
end

-- Photos no ad uses any more (sold or expired ads, abandoned drafts) are deleted after a grace
-- period that leaves time to finish publishing.
local PHOTO_GRACE = 6 * 3600
function prunePhotos(t)
  local used = {}
  for _, l in pairs(market.state.listings) do
    for _, ph in ipairs(l.photos or {}) do used[ph] = true end
  end
  local removed = 0
  for key, meta in pairs(photoIndex) do
    if not used[key] and (t or os.time()) - (meta.at or 0) > PHOTO_GRACE then
      local path = ROOT .. 'photos/' .. tostring(meta.file)
      if FS.Exists(path) then FS.Remove(path) end
      photoIndex[key] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then write(ROOT .. 'photos/index.json', photoIndex) end
  return removed
end

function RLTick()
  local t = os.time()
  timerTicks = timerTicks + 1
  for key, u in pairs(uploads) do if t - u.at > 120 then uploads[key] = nil end end
  for key, u in pairs(requestChunks) do if t - u.at > 180 then requestChunks[key] = nil end end
  for key, slot in pairs(slots) do if slot.expires < t then slots[key] = nil end end
  if not market then return end
  if market:needsTick(t) then
    for id, a in pairs(market.state.accounts) do
      if not a.npc then
        local r = market:dispatch(id, {id = 'timer-' .. t .. '-' .. timerTicks, op = 'tick'}, {map = cfg.map, hour = anyHour()})
        if r.ok then dirty = true end
        break
      end
    end
  end
  scheduleNpcs(timerTicks)
  if timerTicks % 3 == 0 then assignDisplays() end
  askForSpots(t)
  if timerTicks % (cfg.presenceSeconds or 2) == 0 then
    local list = presenceSnapshot()
    local bytes = encode({players = list, time = t})
    for pid in pairs(MP.GetPlayers() or {}) do
      if MP.IsPlayerConnected(pid) then MP.TriggerClientEvent(pid, 'RLPlayers', bytes) end
    end
  end
  if timerTicks % 3600 == 0 then
    local removed = collectBlobs()
    if removed > 0 then log('removed ' .. removed .. ' unused vehicle blobs') end
    local photos = prunePhotos(t)
    if photos > 0 then log('removed ' .. photos .. ' unused photos') end
  end
end

function RLFlush()
  if dirty and market then broadcast() end
end

function RLDisconnect(pid)
  local id = identities[pid]
  if id and market.state.accounts[id] then market.state.accounts[id].lastSeen = os.time() end
  -- NPCs driving to or waiting at this player's businesses lived on their client: let the cars go.
  if id and market.state.accounts[id] then
    local r = market:dispatch(id, {id = 'left-' .. os.time() .. '-' .. tostring(pid), op = 'ownerLeft'}, {system = true})
    if r.ok and r.revision then dirty = true end
  end
  identities[pid] = nil; bindings[pid] = nil; rates[pid] = nil; rates['w' .. pid] = nil; presence[pid] = nil; displaySent[pid] = nil
  for lid, host in pairs(displayHosts) do if host == pid then displayHosts[lid] = nil end end
  for key, slot in pairs(slots) do if slot.pid == pid then slots[key] = nil end end
end

function RLJoin(pid)
  if cfg.welcomeMessage then
    MP.SendChatMessage(pid, 'Welcome! This server runs RiverLife: open the PC in any garage or the RiverLife phone app for classifieds, dealerships and workshops. | Bem-vindo! Este servidor usa o RiverLife. Abra o PC de qualquer garagem ou o app RiverLife no celular para classificados, lojas e oficinas.')
  end
end

-- Host console: "rl status", "rl backup", "rl give <playerName> <dollars>"
function RLConsole(input)
  if type(input) ~= 'string' or input:sub(1, 3) ~= 'rl ' then return end
  local args = {}
  for w in input:gmatch('%S+') do args[#args + 1] = w end
  local cmd = args[2]
  if cmd == 'status' then
    local n = 0; for _ in pairs(market.state.accounts) do n = n + 1 end
    local stores, shops, ads = 0, 0, 0
    for _ in pairs(market.state.stores) do stores = stores + 1 end
    for _ in pairs(market.state.workshops) do shops = shops + 1 end
    for _, l in pairs(market.state.listings) do if l.status == 'active' then ads = ads + 1 end end
    local gigs, spots = 0, market.state.spots[cfg.map] and #market.state.spots[cfg.map] or 0
    for _, g in pairs(market.state.gigs) do if g.status == 'open' then gigs = gigs + 1 end end
    return 'RiverLife rev ' .. market.state.revision .. ' | contas ' .. n .. ' | lojas ' .. stores ..
      ' | oficinas ' .. shops .. ' | anúncios ativos ' .. ads .. ' | bicos abertos ' .. gigs .. ' | pontos do mapa ' .. spots
  elseif cmd == 'backup' then
    local name = ROOT .. 'data/backup-' .. os.date('%Y%m%d-%H%M%S') .. '.json'
    write(name, market.state)
    return 'Backup salvo em ' .. name
  elseif cmd == 'give' and args[3] and tonumber(args[4]) then
    for pid, name in pairs(MP.GetPlayers() or {}) do
      if name == args[3] and identities[pid] then
        local account = identities[pid]
        local cents = math.floor(tonumber(args[4]) * 100)
        market.state.accounts[account].balance = market.state.accounts[account].balance + cents
        market.state.revision = market.state.revision + 1
        save(market.state)
        dirty = true
        return 'Creditado $' .. args[4] .. ' para ' .. name .. ' (sincroniza na carreira dele).'
      end
    end
    return 'Jogador não encontrado.'
  end
  return 'Comandos: rl status | rl backup | rl give <nome> <dólares>'
end

function onInit()
  cfg = read(ROOT .. 'config.json') or {}
  for k, v in pairs(DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  FS.CreateDirectory(ROOT .. 'data'); FS.CreateDirectory(ROOT .. 'data/blobs'); FS.CreateDirectory(ROOT .. 'photos')
  photoIndex = read(ROOT .. 'photos/index.json') or {}
  guestTokens = read(ROOT .. 'data/guest-identities.json') or {}
  market = Domain.new({now = os.time, encode = encode, save = save, putBlob = putBlob, getBlob = getBlob,
    photoOwned = function(id, ref) return photoIndex[ref] and photoIndex[ref].owner == id end,
    log = log}, loadState())
  MP.RegisterEvent('RLRequest', 'RLRequest')
  MP.RegisterEvent('RLRequestChunk', 'RLRequestChunk')
  MP.RegisterEvent('RLPhoto', 'RLPhoto')
  MP.RegisterEvent('RLPresence', 'RLPresence')
  MP.RegisterEvent('onPlayerDisconnect', 'RLDisconnect')
  MP.RegisterEvent('onPlayerJoin', 'RLJoin')
  MP.RegisterEvent('onConsoleInput', 'RLConsole')
  MP.RegisterEvent('RLTick', 'RLTick')
  MP.RegisterEvent('RLFlush', 'RLFlush')
  if MP.CancelEventTimer then MP.CancelEventTimer('RLTick'); MP.CancelEventTimer('RLFlush') end
  MP.CreateEventTimer('RLTick', 1000)
  MP.CreateEventTimer('RLFlush', 400)
  log('pronto; schema ' .. market.state.schema .. '; revisão ' .. market.state.revision)
end

MP.RegisterEvent('onInit', 'onInit')
