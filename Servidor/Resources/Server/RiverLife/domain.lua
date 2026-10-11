-- RiverLife. Original code.
-- Shared transaction engine for solo RLS careers and the BeamMP server.
-- Runs on LuaJIT (game) and Lua 5.3 (BeamMP server): no goto, no bit ops.
-- Money is integer cents. Every request is applied to a copy of the state and
-- only exposed after env.save confirms it is durable; request ids make retries
-- idempotent. Heavy vehicle payloads live in blobs (env.putBlob/getBlob).
local M = {}
M.SCHEMA = 3

local C = {
  LISTING_TTL = 7 * 86400, VISIT_TTL = 1800, OFFER_TTL = 300, MAX_OFFER_ROUNDS = 12,
  DEPOSIT_RATE = 0.01, DEPOSIT_MAX = 50000,
  BUYER_RADIUS = 18, SELLER_RADIUS = 35, VEHICLE_RADIUS = 25,
  MIN_PRICE = 100, MAX_PRICE = 500000000,
  STORE_COST = 2500000, STORE_RENT = 25000, STORE_CAPACITY = 4, STORE_MAX_CAPACITY = 12,
  STORE_FEE_RATE = 0.015, STORE_RADIUS = 35, STORE_SPACING = 75,
  SHOP_COST = 4000000, SHOP_RENT = 30000, SHOP_BAYS = 2, SHOP_MAX_BAYS = 6,
  SHOP_RADIUS = 30, BAY_RADIUS = 14, SHOP_SPACING = 60,
  ORDER_TTL = 3600, QUOTE_TTL = 900,
  NPC_TTL = 900, NPC_ROUNDS = 3,
  MESSAGE_LIMIT = 120, REQUEST_CACHE_SECONDS = 3600, RECEIPT_HISTORY = 400,
  -- Car lot: stock cars stand on marked spots with a price sign; buyers walk up.
  LOT_RADIUS = 60, LOT_SPACING = 3.2, LOT_BUY_RADIUS = 15, LOT_TTL = 30 * 86400,
  -- Staff: wages per real day in cents, scaled by skill (1..5).
  STAFF = {
    store = {
      vendedor = {label = 'Vendedor(a)', wage = 15000, commission = 2},
      comprador = {label = 'Comprador(a) / avaliador(a)', wage = 18000, commission = 0},
    },
    shop = {
      mecanico = {label = 'Mecânico(a)', wage = 20000, commission = 10},
    },
  },
  STAFF_LIMIT = {vendedor = 2, comprador = 1, mecanico = 6},
  -- The living economy runs every SIM_INTERVAL seconds on the server tick.
  SIM_INTERVAL = 300, NPC_SALE_CHANCE = 0.05, NPC_BUY_CHANCE = 0.2, SHOP_JOB_CHANCE = 0.25,
  NPC_ADS = 6, NPC_AD_TTL = 3 * 3600, GIGS_OPEN = 5, GIG_TTL = 2 * 3600, SPOTS_MAX = 80, SPOT_SPACING = 25,
  INSPECTION_FEE = 15000, GIG_RADIUS = 20, INSPECT_RADIUS = 10, FEED_LIMIT = 60,
  -- Cars standing on a lot or by the road get photographed where they are by the client that shows them.
  DISPLAY_PHOTOS = 3,
  -- Visits are booked at most VISIT_AHEAD ahead and a buyer holds at most OPEN_VISITS cars at once.
  VISIT_AHEAD = 2 * 3600, OPEN_VISITS = 2,
  -- Finished visits/offers and closed orders/ads are dropped after this long (receipts keep the record).
  HISTORY_SECONDS = 3 * 86400, CLOSED_ADS_SECONDS = 7 * 86400,
  -- NPC money is anchored to what the car is worth, not to the asking price.
  NPC_BUDGET_CAP = 1.15, NPC_LOT_CAP = 1.3,
  -- "Tabela FIPE do River": reference price per model/version from the last sales.
  FIPE_SAMPLES = 9, FIPE_MIN_SALES = 3,
  -- "Vende-se" on the street: a parked car with a floor price that sells while the owner is away.
  STREET_MAX = 2, STREET_TTL = 3 * 86400, STREET_SALE_CHANCE = 0.03,
  -- First steps for new players: one-off rewards (cents) and a starter transfer job nearby.
  FIRST_STEPS = {view = 50000, news = 50000, walkIn = 100000, gig = 200000}, FIRST_STEPS_BONUS = 500000,
  STARTER_GIG_RADIUS = 1500,
}
M.C = C

-- Vanilla cars the server can create on its own (NPC classifieds, trade-ins,
-- transfer jobs). Values in dollars. Filled from the game's own config list.
M.CARS = {
  {model = "barstow", config = "vehicles/barstow/i6a.pc", name = "Gavril Barstow 232 I6 (A)", value = 34000},
  {model = "barstow", config = "vehicles/barstow/353m.pc", name = "Gavril Barstow 353 V8 (M)", value = 42000},
  {model = "barstow", config = "vehicles/barstow/353a_sport.pc", name = "Gavril Barstow 353 V8 RoadSport Package (A)", value = 48000},
  {model = "bastion", config = "vehicles/bastion/base_v6_A.pc", name = "Bruckell Bastion SE 3.5 (A)", value = 34500},
  {model = "bastion", config = "vehicles/bastion/sport_M.pc", name = "Bruckell Bastion Sport 5.7 (M)", value = 46000},
  {model = "bastion", config = "vehicles/bastion/street_tuned.pc", name = "Bruckell Bastion Ajustado para a rua (A)", value = 76100},
  {model = "bluebuck", config = "vehicles/bluebuck/i6a_2door.pc", name = "Gavril Bluebuck 232 I6 sedã de 2 portas (A)", value = 39000},
  {model = "bluebuck", config = "vehicles/bluebuck/291a_2door_mid.pc", name = "Gavril Bluebuck 291 V8 Marshal sedã de 2 portas (A)", value = 45500},
  {model = "bluebuck", config = "vehicles/bluebuck/353m_4door_hardtop.pc", name = "Gavril Bluebuck 353 V8 Marshal Hardtop de 4 portas (M)", value = 51000},
  {model = "burnside", config = "vehicles/burnside/2door_utility_early_3M.pc", name = "Burnside Special 252 V8 sedã utilitário de 2 portas (M)", value = 41000, year = 1952},
  {model = "burnside", config = "vehicles/burnside/4door_late_v8_3M.pc", name = "Burnside Special 274 V8 sedã de 4 portas (M)", value = 48000, year = 1953},
  {model = "burnside", config = "vehicles/burnside/2doorSport_late_3A.pc", name = "Burnside Special 313 V8 coupé esportivo de 2 portas (A)", value = 54000, year = 1953},
  {model = "bx", config = "vehicles/bx/diana_base_M.pc", name = "Ibishu BX Diana Base (M)", value = 28500},
  {model = "bx", config = "vehicles/bx/diana_type_l_M.pc", name = "Ibishu BX Diana Type-L (M)", value = 31500},
  {model = "bx", config = "vehicles/bx/diana_type_ls_A.pc", name = "Ibishu BX Diana Type-LS (A)", value = 34800},
  {model = "covet", config = "vehicles/covet/13s_M.pc", name = "Ibishu Covet 13S (M)", value = 18200},
  {model = "covet", config = "vehicles/covet/LXi_M.pc", name = "Ibishu Covet 1.5 LXi (M)", value = 21000},
  {model = "covet", config = "vehicles/covet/type_LS_M.pc", name = "Ibishu Covet Type-LS (M)", value = 30600},
  {model = "etk800", config = "vehicles/etk800/844_150_M.pc", name = "ETK 800 844 150 (M)", value = 34000},
  {model = "etk800", config = "vehicles/etk800/854_190d_A.pc", name = "ETK 800 854 190d (A)", value = 43000},
  {model = "etk800", config = "vehicles/etk800/846_340_A.pc", name = "ETK 800 846tt 340 (A)", value = 61800},
  {model = "etkc", config = "vehicles/etkc/kc4_250_M.pc", name = "ETK K-Series Kc4 250 (M)", value = 50000},
  {model = "etkc", config = "vehicles/etkc/kc6_360_A.pc", name = "ETK K-Series Kc6 360 (A)", value = 73000},
  {model = "etkc", config = "vehicles/etkc/kc6x_310d_driving_experience_M.pc", name = "ETK K-Series Kc6x 310d Driving Experience (M)", value = 85000},
  {model = "etki", config = "vehicles/etki/2400_M.pc", name = "ETK I-Series 2400 (M)", value = 49900, year = 1985},
  {model = "etki", config = "vehicles/etki/2400ix_A.pc", name = "ETK I-Series 2400ix (A)", value = 57000, year = 1987},
  {model = "etki", config = "vehicles/etki/3000ix_M_alt.pc", name = "ETK I-Series 3000ix (M)", value = 70500, year = 1990},
  {model = "fullsize", config = "vehicles/fullsize/fleet.pc", name = "Gavril Grand Marshal Frota (A)", value = 39900, year = 1993},
  {model = "fullsize", config = "vehicles/fullsize/sport.pc", name = "Gavril Grand Marshal V8 Sport (A)", value = 55500, year = 1990},
  {model = "hopper", config = "vehicles/hopper/xt4_M.pc", name = "Ibishu Hopper XT-4 (M)", value = 37800, year = 1989},
  {model = "hopper", config = "vehicles/hopper/xt6_M.pc", name = "Ibishu Hopper XT-6 (M)", value = 45000, year = 1991},
  {model = "hopper", config = "vehicles/hopper/sport_M.pc", name = "Ibishu Hopper Sport Special (M)", value = 57200, year = 1991},
  {model = "lansdale", config = "vehicles/lansdale/22_cargo_A.pc", name = "Soliad Lansdale 2.2 Cargo (A)", value = 29800, year = 1996},
  {model = "lansdale", config = "vehicles/lansdale/25_TD_late_M.pc", name = "Soliad Lansdale TD 2.5 – EUDM (M)", value = 43000, year = 2003},
  {model = "lansdale", config = "vehicles/lansdale/38_overland_AWD_A.pc", name = "Soliad Lansdale 3.8 SE AWD Overland (A)", value = 69000, year = 1996},
  {model = "legran", config = "vehicles/legran/base_i4_M.pc", name = "Bruckell LeGran Regulier (M)", value = 29800},
  {model = "legran", config = "vehicles/legran/se_i4_wagon_facelift_A.pc", name = "Bruckell LeGran SE Wagon (Facelift) (A)", value = 43500, year = 1989},
  {model = "legran", config = "vehicles/legran/luxe_v6_wagon_A.pc", name = "Bruckell LeGran Luxe Grandiose V6 (A)", value = 66000},
  {model = "md_series", config = "vehicles/md_series/md_70_regular_cab.pc", name = "Gavril MD MD70 Cabine Comum (M)", value = 70000, year = 1986},
  {model = "md_series", config = "vehicles/md_series/md_60_flatbed.pc", name = "Gavril MD MD60 Plateau (M)", value = 80000, year = 1986},
  {model = "md_series", config = "vehicles/md_series/md_70_cargobox_facelift.pc", name = "Gavril MD Facelift de Caixa de Carga MD70 (A)", value = 89000, year = 1992},
  {model = "midsize", config = "vehicles/midsize/DX_A.pc", name = "Ibishu Pessima (90s) 1.8 DX (A)", value = 24300},
  {model = "midsize", config = "vehicles/midsize/LX_sport_A.pc", name = "Ibishu Pessima (90s) 2.0 LX Sport (A)", value = 28300},
  {model = "midsize", config = "vehicles/midsize/LX_V6_sport_M.pc", name = "Ibishu Pessima (90s) 2.7 LX V6 Sport (M)", value = 34700},
  {model = "miramar", config = "vehicles/miramar/base_M.pc", name = "Ibishu Miramar Base (M)", value = 24500, year = 1963},
  {model = "miramar", config = "vehicles/miramar/base_export_M_late.pc", name = "Ibishu Miramar Export Base (M)", value = 27000, year = 1967},
  {model = "miramar", config = "vehicles/miramar/luxe_coupe_facelift_A.pc", name = "Ibishu Miramar Luxe Coupe Mira-Matic (A)", value = 31000, year = 1967},
  {model = "moonhawk", config = "vehicles/moonhawk/i6m.pc", name = "Bruckell Moonhawk 244 I6 (M)", value = 36000, year = 1976},
  {model = "moonhawk", config = "vehicles/moonhawk/v8m_alt.pc", name = "Bruckell Moonhawk 309 V8 (M)", value = 44000, year = 1973},
  {model = "moonhawk", config = "vehicles/moonhawk/v8m_sport.pc", name = "Bruckell Moonhawk 448 V8 Sport (M)", value = 53000, year = 1976},
  {model = "nine", config = "vehicles/nine/nine_pickup_short.pc", name = "Bruckell Nine Caçamba Curta (M)", value = 45000},
  {model = "nine", config = "vehicles/nine/nine_coupe_luxe.pc", name = "Bruckell Nine Deluxe Coupé (M)", value = 55000},
  {model = "nine", config = "vehicles/nine/nine_pickup_hotrod.pc", name = "Bruckell Nine Bullet Proof (M)", value = 81000},
  {model = "pessima", config = "vehicles/pessima/DX_A.pc", name = "Ibishu Pessima 1.8 DX (A)", value = 24300},
  {model = "pessima", config = "vehicles/pessima/LX_M.pc", name = "Ibishu Pessima 2.0 LX (M)", value = 27700},
  {model = "pessima", config = "vehicles/pessima/ZX_4ws_M.pc", name = "Ibishu Pessima 2.0 ZX AWS (M)", value = 37000},
  {model = "pickup", config = "vehicles/pickup/d15_fleet_M_facelift.pc", name = "Gavril D-Series D15 Fleet (M)", value = 31000, year = 1998},
  {model = "pickup", config = "vehicles/pickup/d15_ext_4wd_M.pc", name = "Gavril D-Series D15 V8 4WD Cabine Estendida (M)", value = 46550, year = 1992},
  {model = "pickup", config = "vehicles/pickup/d25_longbed_4wd_lifted_A.pc", name = "Gavril D-Series D25 Lifted (A)", value = 62500, year = 1986},
  {model = "roamer", config = "vehicles/roamer/i6_m.pc", name = "Gavril Roamer I6 (M)", value = 40000, year = 1992},
  {model = "roamer", config = "vehicles/roamer/facelift.pc", name = "Gavril Roamer Base (A) (Facelift)", value = 54900, year = 1999},
  {model = "roamer", config = "vehicles/roamer/sport.pc", name = "Gavril Roamer V8 RoadSport (A)", value = 72000, year = 1992},
  {model = "sbr", config = "vehicles/sbr/base_RWD_M.pc", name = "Hirochi SBR4 RWD Base (M)", value = 48500},
  {model = "sbr", config = "vehicles/sbr/S_AWD_DCT.pc", name = "Hirochi SBR4 AWD S (DCT)", value = 61000},
  {model = "sbr", config = "vehicles/sbr/electric_300.pc", name = "Hirochi SBR4 eSBR 300", value = 90000},
  {model = "sunburst2", config = "vehicles/sunburst2/base_EU_M.pc", name = "Hirochi Sunburst 1.6 Base FWD (M)", value = 25500},
  {model = "sunburst2", config = "vehicles/sunburst2/comfort_M.pc", name = "Hirochi Sunburst 2.0 Comfort AWD (M)", value = 33000},
  {model = "sunburst2", config = "vehicles/sunburst2/sport_RS_M.pc", name = "Hirochi Sunburst 2.5 Sport RS AWD (M)", value = 58000},
  {model = "van", config = "vehicles/van/h15_vanster.pc", name = "Gavril H-Series H15 Vanster (A)", value = 33000, year = 1993},
  {model = "van", config = "vehicles/van/h25_ext_vanster_4wd.pc", name = "Gavril H-Series H25 4WD Vanster Long Wheelbase (A)", value = 48000, year = 1993},
  {model = "van", config = "vehicles/van/h35_ext_vanster_4wd.pc", name = "Gavril H-Series H35 4WD Vanster Long Wheelbase (A)", value = 61500, year = 2006},
  {model = "vivace", config = "vehicles/vivace/vivace_110_M.pc", name = "Cherrier Vivace Vivace 110 (M)", value = 23500},
  {model = "vivace", config = "vehicles/vivace/tograc_150dqX_DCT.pc", name = "Cherrier Vivace Tograc 150dQX (DCT)", value = 36500},
  {model = "vivace", config = "vehicles/vivace/ardente_ev.pc", name = "Cherrier Vivace Ardente Lumiere", value = 51000},
  {model = "wendover", config = "vehicles/wendover/base_v6_A.pc", name = "Soliad Wendover 3300 (A)", value = 36000},
  {model = "wendover", config = "vehicles/wendover/sport_s_v6_A.pc", name = "Soliad Wendover Sport S 3800 (A)", value = 43000},
  {model = "wendover", config = "vehicles/wendover/sport_se_v6_M_facelift.pc", name = "Soliad Wendover Sport SE 3800 (Facelift) (M)", value = 50600, year = 1992},
}

local function copy(v, seen)
  if type(v) ~= 'table' then return v end
  seen = seen or {}
  if seen[v] then error('cyclic data') end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x, seen) end
  seen[v] = nil
  return out
end
local function check(ok, code) if not ok then error({code = code}, 0) end end
local function integer(v, low, high)
  return type(v) == 'number' and v == v and v % 1 == 0 and v >= low and v <= high
end
local function text(v, max) return type(v) == 'string' and #v > 0 and #v <= max and not v:find('%z') end
local function optText(v, max) return v == nil or (type(v) == 'string' and #v <= max and not v:find('%z')) end
local function position(p)
  return type(p) == 'table' and type(p.x) == 'number' and p.x == p.x and math.abs(p.x) < 100000 and
    type(p.y) == 'number' and p.y == p.y and math.abs(p.y) < 100000 and
    type(p.z) == 'number' and p.z == p.z and math.abs(p.z) < 100000
end
local function distance(a, b)
  if not position(a) or not position(b) then return math.huge end
  return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end
local function pos(p) return {x = p.x, y = p.y, z = p.z} end
local function safeConfig(c, depth)
  if type(c) ~= 'table' then return false end
  depth = depth or 0
  if depth > 64 then return false end
  local count = 0
  for k, v in pairs(c) do
    count = count + 1
    if count > 8192 then return false end
    if type(k) ~= 'string' and type(k) ~= 'number' then return false end
    if type(k) == 'string' and (#k > 256 or k:find('%z')) then return false end
    if type(v) == 'table' then
      if not safeConfig(v, depth + 1) then return false end
    elseif type(v) == 'string' then
      if #v > 2097152 or v:find('%z') then return false end
    elseif type(v) == 'number' then
      if v ~= v or math.abs(v) > 1e15 then return false end
    elseif type(v) ~= 'boolean' then
      return false
    end
  end
  return true
end
local function withinHours(opensAt, closesAt, hour)
  if opensAt == closesAt then return true end
  if opensAt < closesAt then return hour >= opensAt and hour < closesAt end
  return hour >= opensAt or hour < closesAt
end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
M.copy, M.distance, M.safeConfig, M.withinHours = copy, distance, safeConfig, withinHours

local TABLES = {'accounts', 'assets', 'listings', 'visits', 'offers', 'stores', 'workshops', 'orders', 'receipts',
  'npcs', 'messages', 'requests', 'vacancies', 'gigs', 'spots', 'spotsMeta', 'feed', 'fipe'}

function M.newState()
  local s = {schema = M.SCHEMA, revision = 0, sequence = 0, treasury = 0, seed = 20261008, simAt = 0}
  for _, key in ipairs(TABLES) do s[key] = {} end
  return s
end

local function businessDefaults(b, kind)
  b.staff = b.staff or {}
  b.policy = b.policy or {}
  local p = b.policy
  if kind == 'store' then
    if p.autoSell == nil then p.autoSell = true end
    p.minPct = p.minPct or 90
    if p.autoBuy == nil then p.autoBuy = true end
    p.buyPct = p.buyPct or 65
    p.markupPct = p.markupPct or 25
    b.lot = b.lot or {}
  else
    if p.autoQuote == nil then p.autoQuote = true end
    p.markupPct = p.markupPct or 30
  end
end

-- Schema 1 (RiverMarket) and 2 states are upgraded in place.
function M.migrate(state)
  if type(state) ~= 'table' then return M.newState() end
  for _, key in ipairs(TABLES) do
    state[key] = state[key] or {}
  end
  state.seed = state.seed or 20261008
  state.simAt = state.simAt or 0
  for _, st in pairs(state.stores) do businessDefaults(st, 'store') end
  for _, w in pairs(state.workshops) do businessDefaults(w, 'shop') end
  if state.npcVisits then
    for id, n in pairs(state.npcVisits) do
      n.kind = n.kind or 'buyer'; n.owner = n.owner or n.seller
      state.npcs[id] = n
    end
    state.npcVisits = nil
  end
  state.treasury = state.treasury or 0
  state.sequence = state.sequence or 0
  state.revision = state.revision or 0
  state.schema = M.SCHEMA
  return state
end

-- What clients should report next for a map: roadside points (gigs) until there are 40, then parking
-- spots (NPC sellers) until there are 40 or as many as the map has.
function M.spotsNeeded(s, map)
  local road, parking = 0, 0
  for _, sp in ipairs((s.spots or {})[map] or {}) do if sp.k == 'p' then parking = parking + 1 else road = road + 1 end end
  local meta = (s.spotsMeta or {})[map]
  if road < 40 or not meta then return true end
  return meta.parking > 0 and parking < math.min(40, meta.parking)
end

local function summarize(data)
  return {model = data.model, niceName = data.niceName, mileage = data.mileage or 0, year = data.year,
    value = data.configBaseValue or data.value, condition = data.condition,
    brokenParts = data.damageSummary and data.damageSummary.brokenParts,
    thumbnail = data.thumbnail, config = type(data.config) == 'string' and data.config or nil}
end
M.summarize = summarize

function M.new(env, state)
  local self = {state = M.migrate(state or M.newState())}
  -- JSON round trips may turn integers into floats on Lua 5.3; ids stay "x-12".
  local function nextId(s, prefix)
    s.sequence = math.floor(s.sequence) + 1
    return prefix .. string.format('%d', s.sequence)
  end
  local function now() return math.floor(env.now()) end
  local function account(s, id) check(s.accounts[id], 'account_missing'); return s.accounts[id] end
  local function listing(s, id) check(s.listings[id], 'listing_missing'); return s.listings[id] end
  local function own(s, id, owner) local l = listing(s, id); check(l.seller == owner, 'not_owner'); return l end
  local function credit(s, id, amount) local a = account(s, id); a.balance = a.balance + amount; return a end
  local function debit(s, id, amount)
    local a = account(s, id); check(a.balance >= amount, 'insufficient_funds'); a.balance = a.balance - amount; return a
  end
  local function putBlob(data) return env.putBlob and env.putBlob(data) or data end
  local function getBlob(ref) if type(ref) == 'table' then return ref end; return env.getBlob and env.getBlob(ref) end

  local function notify(s, to, subject, body, meta)
    if not s.accounts[to] or s.accounts[to].npc then return end
    local mid = nextId(s, 'msg-')
    s.messages[mid] = {id = mid, from = 'system', to = to, subject = subject, body = body, createdAt = now(),
      meta = meta, read = false}
  end

  -- Deterministic pseudo random (Park-Miller): same results on LuaJIT and Lua 5.3,
  -- and a request replay never rolls different dice than the saved outcome.
  local function rnd(s)
    local seed = math.floor(s.seed or 20261008) % 2147483647
    if seed <= 0 then seed = seed + 2147483646 end
    seed = (seed * 16807) % 2147483647
    s.seed = seed
    return seed / 2147483647
  end
  local function between(s, lo, hi) return lo + rnd(s) * (hi - lo) end
  local function pickFrom(s, list) return list[math.min(#list, 1 + math.floor(rnd(s) * #list))] end
  local FIRST = {'Marcos', 'Camila', 'João', 'Patrícia', 'Rafael', 'Luiza', 'Thiago', 'Fernanda', 'Bruno', 'Juliana',
    'Diego', 'Aline', 'Gustavo', 'Larissa', 'Felipe', 'Bianca', 'Rodrigo', 'Carla', 'Eduardo', 'Natália', 'Vinícius',
    'Renata', 'Lucas', 'Mariana', 'André', 'Paula', 'Caio', 'Débora', 'Otávio', 'Simone', 'Heitor', 'Yasmin'}
  local LAST = {'Silva', 'Souza', 'Oliveira', 'Pereira', 'Costa', 'Rodrigues', 'Almeida', 'Nascimento', 'Lima',
    'Araújo', 'Fernandes', 'Carvalho', 'Gomes', 'Martins', 'Rocha', 'Ribeiro', 'Barbosa', 'Moreira', 'Teixeira'}
  local function personName(s) return pickFrom(s, FIRST) .. ' ' .. pickFrom(s, LAST) end
  local function money(c)
    local digits = string.format('%d', math.floor((c or 0) / 100))
    local out = digits:reverse():gsub('(%d%d%d)', '%1.'):reverse()
    return '$' .. out:gsub('^%.', '')
  end

  -- Public news feed: what happens on the server, newest first.
  local function event(s, kind, text, meta)
    table.insert(s.feed, 1, {at = now(), kind = kind, text = text, meta = meta})
    while #s.feed > C.FEED_LIMIT do table.remove(s.feed) end
  end

  local function profession(s, id, key, earned)
    local a = s.accounts[id]
    if not a or a.npc then return end
    a.prof = a.prof or {}
    local p = a.prof[key] or {done = 0, earned = 0}
    p.done = p.done + 1; p.earned = p.earned + (earned or 0)
    p.level = math.min(10, math.floor(math.sqrt(p.done)))
    a.prof[key] = p
  end
  local function level(s, id, key)
    local a = s.accounts[id]
    return a and a.prof and a.prof[key] and a.prof[key].level or 0
  end

  -- Staff ----------------------------------------------------------------------
  local function business(s, bid)
    if s.stores[bid] then return s.stores[bid], 'store' end
    if s.workshops[bid] then return s.workshops[bid], 'shop' end
  end
  local function staffWith(b, role)
    local list = {}
    for _, m in pairs(b.staff or {}) do if m.role == role then list[#list + 1] = m end end
    table.sort(list, function(x, y) return (x.skill or 0) > (y.skill or 0) or (x.skill == y.skill and x.id < y.id) end)
    return list
  end
  local function npcStaff(b, role)
    for _, m in ipairs(staffWith(b, role)) do if m.kind == 'npc' then return m end end
  end
  -- Players hired by a business act on its behalf for their role.
  local function playerRole(b, id, role)
    for _, m in pairs(b.staff or {}) do
      if m.kind == 'player' and m.account == id and (role == nil or m.role == role) then return m end
    end
  end
  local function actsForStore(s, id, st) return st and (st.owner == id or playerRole(st, id, 'vendedor') ~= nil) end
  local function actsForShop(s, id, w) return w and (w.owner == id or playerRole(w, id, 'mecanico') ~= nil) end

  local function refund(s, v)
    if v.deposit and v.deposit > 0 and not v.refunded and s.accounts[v.buyer] then
      credit(s, v.buyer, v.deposit); v.refunded = true
    end
  end
  local function cancelVisit(s, v, reason)
    refund(s, v); v.status = reason
    local l = s.listings[v.listingId]
    if l and l.reservation == v.id then l.reservation = nil end
    for _, o in pairs(s.offers) do if o.visitId == v.id and o.status == 'pending' then o.status = reason end end
    local n = s.npcs[v.buyer]
    if n and n.status ~= 'purchased' then n.status = 'leaving' end
  end
  local function refundOrder(s, o, reason)
    if o.paid and o.paid > 0 and not o.refunded and s.accounts[o.customer] then
      credit(s, o.customer, o.paid); o.refunded = true
    end
    o.status = reason
    local n = s.npcs[o.customer]
    if n and n.status ~= 'served' then n.status = 'leaving' end
  end

  -- A car standing on a lot or by the road goes back to its owner, on its spot.
  local function returnDisplayCar(s, l, owner)
    local a = s.assets[l.assetId]
    if not a then return nil end
    a.listingId = nil; a.location = nil
    local rid = nextId(s, 'stock-')
    s.receipts[rid] = {id = rid, kind = 'stock_out', assetId = a.id, listingId = l.id, buyer = owner, seller = owner, price = 0,
      fee = 0, createdAt = now(), dataRef = a.dataRef, summary = copy(a.summary), buyerApplied = false, sellerApplied = true,
      pickup = {x = l.position.x, y = l.position.y, z = l.position.z, h = l.heading or 0}}
    a.lastReceipt = rid
    return s.receipts[rid]
  end

  local function expire(s)
    local t = now()
    for _, v in pairs(s.visits) do
      if (v.status == 'scheduled' or v.status == 'arrived') and v.expiresAt <= t then cancelVisit(s, v, 'expired') end
    end
    for _, l in pairs(s.listings) do
      if l.status == 'active' and l.expiresAt <= t then
        if l.reservation and s.visits[l.reservation] then cancelVisit(s, s.visits[l.reservation], 'expired') end
        l.status = 'expired'
        local a = s.assets[l.assetId]
        if a and l.street and a.owner == l.seller and s.accounts[l.seller] then
          returnDisplayCar(s, l, l.seller)
          notify(s, l.seller, 'Anúncio de rua encerrado', l.title .. ' não foi vendido em 3 dias. Retire o carro no lugar onde ele está.',
            {listingId = l.id})
        elseif a then a.listingId = nil end
      end
    end
    for _, o in pairs(s.offers) do if o.status == 'pending' and o.expiresAt <= t then o.status = 'expired' end end
    for _, g in pairs(s.gigs) do
      if g.status == 'open' and g.expiresAt <= t then
        g.status = 'expired'; g.closedAt = t
        if g.payer and s.accounts[g.payer] then credit(s, g.payer, g.pay) end
      elseif g.status == 'taken' and g.deadline and g.deadline + 1800 <= t then
        g.status = 'failed'; g.closedAt = t
        if g.payer and s.accounts[g.payer] then credit(s, g.payer, g.pay) end
      end
    end
    for _, o in pairs(s.orders) do
      if (o.status == 'requested' or o.status == 'quoted') and o.expiresAt <= t then refundOrder(s, o, 'expired') end
    end
    for _, n in pairs(s.npcs) do
      if (n.status == 'travelling' or n.status == 'negotiating' or n.status == 'waiting') and n.expiresAt <= t then
        n.status = 'leaving'
        if n.visitId and s.visits[n.visitId] then
          local v = s.visits[n.visitId]
          if v.status == 'scheduled' or v.status == 'arrived' then cancelVisit(s, v, 'expired') end
        end
        if n.orderId and s.orders[n.orderId] then
          local o = s.orders[n.orderId]
          if o.status == 'requested' or o.status == 'quoted' then refundOrder(s, o, 'expired') end
        end
      end
    end
  end

  -- Old idempotency records and finished history are pruned so the state stays small.
  local function prune(s)
    local t = now()
    for key, r in pairs(s.requests) do
      if (r.at or 0) < t - C.REQUEST_CACHE_SECONDS then s.requests[key] = nil end
    end
    local perAccount = {}
    for id, m in pairs(s.messages) do
      perAccount[m.to] = perAccount[m.to] or {}
      table.insert(perAccount[m.to], m)
    end
    for _, list in pairs(perAccount) do
      if #list > C.MESSAGE_LIMIT then
        table.sort(list, function(a, b) return a.createdAt > b.createdAt end)
        for i = C.MESSAGE_LIMIT + 1, #list do s.messages[list[i].id] = nil end
      end
    end
    for id, n in pairs(s.npcs) do
      if (n.status == 'leaving' or n.status == 'purchased' or n.status == 'served' or n.status == 'sold')
        and (n.closedAt or n.createdAt) < t - 1800 then
        s.npcs[id] = nil
        s.accounts[id] = nil
      end
    end
    for gid, g in pairs(s.gigs) do
      if g.status ~= 'open' and g.status ~= 'taken' and (g.closedAt or g.createdAt) < t - 3600 then s.gigs[gid] = nil end
    end
    for vid, vac in pairs(s.vacancies) do
      if vac.status ~= 'open' and vac.createdAt < t - 86400 then s.vacancies[vid] = nil end
    end
    for lid, l in pairs(s.listings) do
      if l.npcSeller and l.status ~= 'active' and (l.soldAt or l.expiresAt or 0) < t - 3600 then
        local a = s.assets[l.assetId]
        if a and a.owner == l.seller then s.assets[l.assetId] = nil end
        if s.accounts[l.seller] and s.accounts[l.seller].npc then s.accounts[l.seller] = nil end
        s.listings[lid] = nil
      end
    end
    for aid, a in pairs(s.accounts) do
      if a.transient and (a.createdAt or 0) < t - 3600 then s.accounts[aid] = nil end
    end
    for vin, a in pairs(s.assets) do
      if a.owner == 'npc' and not a.listingId and (a.importedAt or 0) < t - 86400 then s.assets[vin] = nil end
    end
    -- Finished history: visits, offers, orders and player ads nobody can act on any more.
    local OPEN_VISIT = {scheduled = true, arrived = true}
    local OPEN_ORDER = {requested = true, quoted = true, accepted = true, in_progress = true, waiting = true}
    for vid, v in pairs(s.visits) do
      if not OPEN_VISIT[v.status] and (v.expiresAt or v.createdAt or 0) < t - C.HISTORY_SECONDS then s.visits[vid] = nil end
    end
    for oid, o in pairs(s.offers) do
      if o.status ~= 'pending' and ((o.expiresAt or o.createdAt or 0) < t - C.HISTORY_SECONDS or not s.visits[o.visitId]) then
        s.offers[oid] = nil
      end
    end
    for oid, o in pairs(s.orders) do
      if not OPEN_ORDER[o.status] and (o.completedAt or o.expiresAt or o.createdAt or 0) < t - C.CLOSED_ADS_SECONDS then
        s.orders[oid] = nil
      end
    end
    for lid, l in pairs(s.listings) do
      local a = s.assets[l.assetId]
      if l.status ~= 'active' and not l.reservation and not (a and a.listingId == lid)
        and (l.soldAt or l.closedAt or l.expiresAt or l.createdAt or 0) < t - C.CLOSED_ADS_SECONDS then
        s.listings[lid] = nil
      end
    end
    local done = {}
    for rid, r in pairs(s.receipts) do if r.buyerApplied and r.sellerApplied then done[#done + 1] = r end end
    if #done > C.RECEIPT_HISTORY then
      table.sort(done, function(a, b) return a.createdAt > b.createdAt or (a.createdAt == b.createdAt and a.id > b.id) end)
      for i = C.RECEIPT_HISTORY + 1, #done do s.receipts[done[i].id] = nil end
    end
  end

  -- Tabela FIPE do River: model/version key, reference = blend of what the car is worth and the
  -- median of the last sales of that version (needs a few sales to move).
  local function fipeKey(sum)
    if type(sum) ~= 'table' or type(sum.model) ~= 'string' then return nil end
    local version = type(sum.config) == 'string' and sum.config:match('([^/]+)%.pc$') or nil
    return sum.model .. (version and ('|' .. version) or '')
  end
  local function median(list)
    local t = {}
    for i, v in ipairs(list) do t[i] = v end
    table.sort(t)
    local n = #t
    if n == 0 then return nil end
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return math.floor((t[n / 2] + t[n / 2 + 1]) / 2)
  end
  local function fipeOf(s, sum)
    local worth = sum and tonumber(sum.value)
    worth = worth and worth > 0 and math.floor(worth * 100) or nil
    local key = fipeKey(sum)
    local rec = key and s.fipe[key]
    local n = rec and #(rec.samples or {}) or 0
    if n >= C.FIPE_MIN_SALES then
      local market = median(rec.samples)
      if worth then return math.floor(clamp((market + worth) / 2, worth * 0.6, worth * 1.5) / 100) * 100, n end
      return market, n
    end
    return worth and math.floor(worth / 100) * 100 or nil, n
  end
  local function recordFipe(s, sum, price)
    local key = fipeKey(sum)
    if not key or not integer(price, C.MIN_PRICE, C.MAX_PRICE) then return end
    local rec = s.fipe[key] or {name = sum.niceName, samples = {}}
    rec.samples[#rec.samples + 1] = price
    while #rec.samples > C.FIPE_SAMPLES do table.remove(rec.samples, 1) end
    rec.name = rec.name or sum.niceName
    rec.at = now()
    s.fipe[key] = rec
  end

  -- Primeiros passos: each step pays once per account; all four pay a bonus.
  local function firstStep(s, id, step)
    local a = s.accounts[id]
    local reward = C.FIRST_STEPS[step]
    if not a or a.npc or not reward then return end
    a.firstSteps = a.firstSteps or {}
    if a.firstSteps[step] then return end
    a.firstSteps[step] = now()
    credit(s, id, reward)
    local done = 0
    for key in pairs(C.FIRST_STEPS) do if a.firstSteps[key] then done = done + 1 end end
    local total = 0
    for _ in pairs(C.FIRST_STEPS) do total = total + 1 end
    if done == total and not a.firstSteps.bonus then
      a.firstSteps.bonus = now(); credit(s, id, C.FIRST_STEPS_BONUS)
      notify(s, id, 'Primeiros passos concluídos!', 'Você completou todos os passos e ganhou ' .. money(C.FIRST_STEPS_BONUS) ..
        ' de bônus. Agora é com você: abra uma loja, uma oficina ou viva de bicos.', {})
    else
      notify(s, id, 'Primeiros passos', 'Passo concluído (' .. done .. '/' .. total .. '): +' .. money(reward) .. '.', {})
    end
  end

  local function publicListing(s, l)
    local a = s.assets[l.assetId] or {summary = {}}
    local store = l.storeId and s.stores[l.storeId]
    local sum = a.summary or {}
    local seller = s.accounts[l.seller]
    local fipe, fipeSales = fipeOf(s, sum)
    return {id = l.id, seller = l.seller, sellerName = seller and seller.name or '?', status = l.status,
      title = l.title, description = l.description, price = l.price, photos = copy(l.photos),
      position = copy(l.position), map = l.map, createdAt = l.createdAt, expiresAt = l.expiresAt,
      storeId = l.storeId, storeName = store and store.name, reserved = l.reservation ~= nil,
      model = sum.model, niceName = sum.niceName, mileage = sum.mileage or 0, year = sum.year,
      condition = sum.condition, value = sum.value, brokenParts = sum.brokenParts,
      views = l.views or 0, negotiable = l.negotiable, revision = l.revision, assetId = l.assetId,
      sellerReputation = seller and seller.reputation or 0,
      lot = l.lot, lotSpot = l.lotSpot, heading = l.heading, display = l.display, npcSeller = l.npcSeller,
      fipe = fipe, fipeSales = fipeSales, street = l.street,
      inspection = copy(l.inspection), config = l.display and sum.config or nil, staffed = store and
        store.policy and store.policy.autoSell and npcStaff(store, 'vendedor') ~= nil or nil}
  end

  -- Job candidates: a fresh list per business each real day, the same for every
  -- client and the server (derived from the business id, not from the state).
  local function hashSeed(str)
    local h = 7
    for i = 1, #str do h = (h * 31 + str:byte(i)) % 2147483647 end
    return h
  end
  local function candidatesFor(b, kind)
    local day = math.floor(now() / 86400)
    local seed = hashSeed(b.id .. ':' .. day)
    local g = {seed = seed}
    local out = {}
    for role, def in pairs(C.STAFF[kind] or {}) do
      for i = 1, 3 do
        local skill = 1 + math.floor(rnd(g) * 5)
        local wage = math.floor(def.wage * (0.7 + 0.15 * skill) / 100) * 100
        out[#out + 1] = {id = b.id .. '-' .. role .. '-' .. day .. '-' .. i, role = role, label = def.label,
          name = personName(g), skill = skill, wage = wage, commission = def.commission}
      end
    end
    table.sort(out, function(x, y) return x.id < y.id end)
    return out
  end

  local function businessView(s, b, id, kind)
    local x = copy(b)
    x.ownerName = s.accounts[b.owner] and s.accounts[b.owner].name
    local inside = b.owner == id or playerRole(b, id) ~= nil
    if not inside then x.policy = nil end
    if b.owner == id then x.candidates = candidatesFor(b, kind) end
    x.myRole = (b.owner == id and 'owner') or (playerRole(b, id) and playerRole(b, id).role) or nil
    return x
  end

  local function snapshot(s, id)
    local me = copy(account(s, id))
    local out = {revision = s.revision, me = me, listings = {}, stores = {}, workshops = {}, visits = {},
      offers = {}, receipts = {}, assets = {}, npcs = {}, orders = {}, messages = {}, accounts = {},
      feed = copy(s.feed), gigs = {}, vacancies = {}, jobs = {}, now = now(), spotsCount = {}, fipe = {},
      firstSteps = {rewards = copy(C.FIRST_STEPS), bonus = C.FIRST_STEPS_BONUS}}
    for key, rec in pairs(s.fipe) do
      local n = #(rec.samples or {})
      if n > 0 then out.fipe[#out.fipe + 1] = {key = key, name = rec.name, sales = n, median = median(rec.samples), at = rec.at} end
    end
    table.sort(out.fipe, function(a, b) return (a.at or 0) > (b.at or 0) end)
    while #out.fipe > 60 do table.remove(out.fipe) end
    for map, list in pairs(s.spots) do out.spotsCount[map] = #list end
    out.spotsNeeded = {}
    for map in pairs(s.spots) do out.spotsNeeded[map] = M.spotsNeeded(s, map) end
    for _, l in pairs(s.listings) do
      if l.status == 'active' or l.seller == id then out.listings[#out.listings + 1] = publicListing(s, l) end
    end
    table.sort(out.listings, function(a, b) return a.createdAt > b.createdAt or a.createdAt == b.createdAt and a.id > b.id end)
    for _, st in pairs(s.stores) do
      local x = businessView(s, st, id, 'store')
      local stock = 0
      for _, l in pairs(s.listings) do if l.storeId == st.id and l.status == 'active' then stock = stock + 1 end end
      x.stock = stock
      out.stores[#out.stores + 1] = x
      if x.myRole and x.myRole ~= 'owner' then out.jobs[#out.jobs + 1] = {businessId = st.id, kind = 'store', name = st.name, role = x.myRole} end
    end
    for _, w in pairs(s.workshops) do
      local x = businessView(s, w, id, 'shop')
      local busy = 0
      for _, o in pairs(s.orders) do if o.workshopId == w.id and o.status == 'in_progress' then busy = busy + 1 end end
      x.busyBays = busy
      out.workshops[#out.workshops + 1] = x
      if x.myRole and x.myRole ~= 'owner' then out.jobs[#out.jobs + 1] = {businessId = w.id, kind = 'shop', name = w.name, role = x.myRole} end
    end
    for _, g in pairs(s.gigs) do
      if (g.status == 'open' and (not g.reservedFor or g.reservedFor == id)) or g.taker == id or g.client == id then
        out.gigs[#out.gigs + 1] = copy(g)
      end
    end
    table.sort(out.gigs, function(a, b) return a.createdAt > b.createdAt or a.createdAt == b.createdAt and a.id > b.id end)
    for _, vac in pairs(s.vacancies) do if vac.status == 'open' then out.vacancies[#out.vacancies + 1] = copy(vac) end end
    -- Staff of a store answer its offers and see its visits.
    local staffStores = {}
    for _, st in pairs(s.stores) do if actsForStore(s, id, st) then staffStores[st.id] = st.owner end end
    local function sellsFor(v)
      local l = s.listings[v.listingId]
      return l and l.storeId and staffStores[l.storeId] == v.seller
    end
    for _, v in pairs(s.visits) do
      if v.buyer == id or v.seller == id or sellsFor(v) then out.visits[#out.visits + 1] = copy(v) end
    end
    for _, o in pairs(s.offers) do
      local v = s.visits[o.visitId]
      if o.buyer == id or o.seller == id or (v and sellsFor(v)) then out.offers[#out.offers + 1] = copy(o) end
    end
    for _, r in pairs(s.receipts) do
      if r.buyer == id or r.seller == id then
        local receipt = {}
        for k, v in pairs(r) do if k ~= 'dataRef' then receipt[k] = copy(v) end end
        receipt.title = s.listings[r.listingId] and s.listings[r.listingId].title or (r.summary and r.summary.niceName)
        out.receipts[#out.receipts + 1] = receipt
      end
    end
    for vin, a in pairs(s.assets) do
      if a.owner == id then
        local asset = {}
        for k, v in pairs(a) do if k ~= 'dataRef' then asset[k] = copy(v) end end
        out.assets[vin] = asset
      end
    end
    for _, n in pairs(s.npcs) do if n.owner == id then out.npcs[#out.npcs + 1] = copy(n) end end
    for _, o in pairs(s.orders) do
      local w = s.workshops[o.workshopId]
      if o.customer == id or o.shopOwner == id or (w and playerRole(w, id, 'mecanico')) then out.orders[#out.orders + 1] = copy(o) end
    end
    for _, m in pairs(s.messages) do
      if m.to == id or m.from == id then out.messages[#out.messages + 1] = copy(m) end
    end
    table.sort(out.messages, function(a, b) return a.createdAt > b.createdAt end)
    for aid, a in pairs(s.accounts) do
      if not a.npc then
        out.accounts[#out.accounts + 1] = {id = aid, name = a.name, reputation = a.reputation, sales = a.sales,
          lastSeen = a.lastSeen}
      end
    end
    return out
  end

  local validSpots, newNpcAccount, retireNpcAds
  local handlers = {}
  -- Internal callbacks shared across sections (never request operations).
  local hooks = {}

  -- Accounts and wallet ------------------------------------------------------
  function handlers.hello(s, id, p, ctx)
    check(text(ctx.name, 64), 'invalid_name')
    if not s.accounts[id] then
      check(ctx.allowImport == true, 'career_import_disabled')
      check(integer(p.balance, 0, 10000000000), 'invalid_balance')
      s.accounts[id] = {id = id, name = ctx.name, balance = p.balance, reputation = 0, sales = 0, purchases = 0,
        earnings = 0, careerRevision = 0, createdAt = now()}
    else
      s.accounts[id].name = ctx.name
    end
    s.accounts[id].lastSeen = now()
    return snapshot(s, id)
  end
  function handlers.wallet(s, id, p, ctx)
    check(ctx.allowImport == true, 'career_import_disabled')
    local a = account(s, id)
    check(integer(p.delta, -10000000000, 10000000000), 'invalid_balance')
    check(integer(p.revision, 1, 2147483647) and p.revision == a.careerRevision + 1, 'wallet_revision')
    check(a.balance + p.delta >= 0, 'insufficient_funds')
    a.balance = a.balance + p.delta; a.careerRevision = p.revision
    return {balance = a.balance, careerRevision = a.careerRevision}
  end
  function handlers.profile(s, id, p)
    local a = account(s, id)
    check(optText(p.bio, 280), 'invalid_text')
    a.bio = p.bio
    return copy(a)
  end

  -- Vehicles -------------------------------------------------------------------
  function handlers.import(s, id, p, ctx)
    account(s, id); check(ctx.allowImport == true, 'career_import_disabled')
    check(text(p.localId, 64) and type(p.data) == 'table', 'invalid_vehicle')
    check(text(p.data.model, 64) and p.data.model:match('^[%w_%-%.]+$'), 'invalid_model')
    check(safeConfig(p.data), 'invalid_config')
    local function store(a)
      a.dataRef = putBlob(copy(p.data)); a.summary = summarize(p.data); a.updatedAt = now()
    end
    if p.assetId and s.assets[p.assetId] and s.assets[p.assetId].owner == id then
      local a = s.assets[p.assetId]
      check(not a.listingId, 'vehicle_locked')
      a.localId = p.localId; store(a); return {assetId = a.id}
    end
    for vin, a in pairs(s.assets) do
      if a.owner == id and a.localId == p.localId then
        check(not a.listingId, 'vehicle_locked'); store(a); return {assetId = vin}
      end
    end
    local vin = nextId(s, 'RH-')
    s.assets[vin] = {id = vin, owner = id, originAccount = id, originLocalId = p.localId, localId = p.localId,
      importedAt = now()}
    store(s.assets[vin])
    return {assetId = vin}
  end
  function handlers.updateVehicle(s, id, p, ctx)
    check(ctx.allowImport == true, 'career_import_disabled')
    local a = s.assets[p.assetId]; check(a and a.owner == id, 'not_owner')
    check(type(p.data) == 'table' and safeConfig(p.data), 'invalid_vehicle')
    check(a.summary == nil or p.data.model == a.summary.model, 'invalid_vehicle')
    a.dataRef = putBlob(copy(p.data)); a.summary = summarize(p.data); a.updatedAt = now()
    return {assetId = a.id}
  end
  function handlers.delivery(s, id, p)
    local r = s.receipts[p.receiptId]
    check(r and r.buyer == id, 'not_owner')
    check(not s.assets[r.assetId] or s.assets[r.assetId].owner == id, 'not_owner')
    local out = copy(r); out.data = getBlob(r.dataRef); out.dataRef = nil
    check(type(out.data) == 'table', 'vehicle_data_missing')
    return out
  end

  -- Classifieds -----------------------------------------------------------------
  function handlers.publish(s, id, p, ctx)
    local a = s.assets[p.assetId]; check(a and a.owner == id, 'not_owner'); check(not a.listingId, 'already_listed')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price'); check(text(p.title, 100), 'invalid_title')
    check(type(p.description) == 'string' and #p.description <= 1600, 'invalid_description')
    check(type(p.photos) == 'table' and #p.photos >= 2 and #p.photos <= 6, 'photos_required')
    local seen = {}
    for _, photo in ipairs(p.photos) do
      check(text(photo, 128) and not seen[photo] and env.photoOwned(id, photo), 'invalid_photo'); seen[photo] = true
    end
    check(position(ctx.position), 'location_unavailable')
    check(text(ctx.map, 64), 'invalid_map')
    if p.storeId then
      local st = s.stores[p.storeId]; check(st and st.owner == id, 'store_missing')
      local stock = 0
      for _, l in pairs(s.listings) do if l.storeId == st.id and l.status == 'active' then stock = stock + 1 end end
      check(stock < st.capacity, 'store_full'); check(distance(ctx.position, st.position) < C.STORE_RADIUS, 'outside_store')
    end
    local lid = nextId(s, 'ad-')
    s.listings[lid] = {id = lid, assetId = a.id, seller = id, status = 'active', title = p.title,
      description = p.description, price = p.price, photos = copy(p.photos), position = pos(ctx.position),
      map = ctx.map, storeId = p.storeId, createdAt = now(), expiresAt = now() + C.LISTING_TTL, views = 0,
      negotiable = p.negotiable ~= false, revision = 1}
    a.listingId = lid
    return {listingId = lid}
  end
  function handlers.edit(s, id, p)
    local l = own(s, p.listingId, id); check(l.status == 'active' and not l.reservation, 'listing_locked')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(type(p.description) == 'string' and #p.description <= 1600, 'invalid_description')
    if p.title ~= nil then check(text(p.title, 100), 'invalid_title'); l.title = p.title end
    l.price = p.price; l.description = p.description; l.negotiable = p.negotiable ~= false; l.revision = l.revision + 1
    l.expiresAt = math.max(l.expiresAt, now() + C.LISTING_TTL)
    return publicListing(s, l)
  end
  function handlers.cancel(s, id, p)
    local l = own(s, p.listingId, id); check(l.status ~= 'sold', 'already_sold')
    if l.reservation and s.visits[l.reservation] then cancelVisit(s, s.visits[l.reservation], 'cancelled') end
    l.status = 'cancelled'; l.closedAt = now()
    if s.assets[l.assetId] then s.assets[l.assetId].listingId = nil end
    return {cancelled = l.id}
  end
  function handlers.view(s, id, p)
    local l = listing(s, p.listingId)
    if l.seller ~= id then l.views = (l.views or 0) + 1; firstStep(s, id, 'view') end
    return {views = l.views}
  end
  function handlers.visit(s, id, p, ctx)
    local l = listing(s, p.listingId); check(l.status == 'active', 'listing_unavailable')
    check(l.seller ~= id, 'own_listing'); check(l.map == ctx.map, 'wrong_map')
    check(not l.reservation, 'already_reserved')
    local scheduledAt = p.scheduledAt or now()
    check(integer(scheduledAt, now() - 5, now() + C.VISIT_AHEAD), 'invalid_time')
    local holding = 0
    for _, other in pairs(s.visits) do
      if other.buyer == id and (other.status == 'scheduled' or other.status == 'arrived') then holding = holding + 1 end
    end
    check(holding < C.OPEN_VISITS, 'too_many_visits')
    local deposit = math.min(C.DEPOSIT_MAX, math.max(0, math.floor(l.price * C.DEPOSIT_RATE)))
    debit(s, id, deposit)
    local vid = nextId(s, 'visit-')
    s.visits[vid] = {id = vid, listingId = l.id, seller = l.seller, buyer = id, status = 'scheduled',
      position = copy(l.position), map = l.map, scheduledAt = scheduledAt, expiresAt = scheduledAt + C.VISIT_TTL,
      deposit = deposit, createdAt = now()}
    l.reservation = vid
    notify(s, l.seller, 'Visita marcada', account(s, id).name .. ' marcou uma visita para ver ' .. l.title .. '.',
      {visitId = vid, listingId = l.id})
    return copy(s.visits[vid])
  end
  function handlers.cancelVisit(s, id, p)
    local v = s.visits[p.visitId]; check(v and (v.buyer == id or v.seller == id), 'visit_missing')
    check(v.status == 'scheduled' or v.status == 'arrived', 'visit_closed')
    cancelVisit(s, v, 'cancelled')
    notify(s, v.buyer == id and v.seller or v.buyer, 'Visita cancelada', 'A visita foi cancelada.', {visitId = v.id})
    return {cancelled = v.id}
  end
  function handlers.arrive(s, id, p, ctx)
    local v = s.visits[p.visitId]; check(v and v.buyer == id, 'visit_missing')
    check(v.status == 'scheduled' or v.status == 'arrived', 'visit_closed')
    check(v.map == ctx.map, 'wrong_map'); check(now() >= v.scheduledAt - 300, 'too_early')
    check(distance(ctx.position, v.position) <= C.BUYER_RADIUS, 'visit_required')
    local l = listing(s, v.listingId)
    -- Lot and roadside cars stand where the ad says; the seller need not be there.
    if not l.display then
      check(ctx.sellerPosition and distance(ctx.sellerPosition, v.position) <= C.SELLER_RADIUS, 'seller_absent')
      check(ctx.vehiclePosition and distance(ctx.vehiclePosition, v.position) <= C.VEHICLE_RADIUS, 'vehicle_absent')
    end
    if v.status ~= 'arrived' then
      v.status = 'arrived'; v.arrivedAt = now(); l.views = (l.views or 0) + 1
      notify(s, v.seller, 'Comprador chegou', account(s, id).name .. ' chegou para ver ' .. l.title .. '.', {visitId = v.id})
    end
    return copy(v)
  end
  -- internal: offers placed by the automatic seller itself (no auto reply).
  function handlers.offer(s, id, p, ctx, internal)
    local v = s.visits[p.visitId]; check(v, 'visit_missing')
    local l = listing(s, v.listingId)
    local st = l.storeId and s.stores[l.storeId]
    local employee = not internal and id ~= v.seller and id ~= v.buyer and st and playerRole(st, id, 'vendedor')
    check(v.buyer == id or v.seller == id or employee, 'visit_missing')
    check(v.status == 'arrived', 'visit_required')
    check(l.status == 'active', 'listing_unavailable')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(l.negotiable or p.price == l.price, 'not_negotiable')
    local rounds = 0
    for _, o in pairs(s.offers) do
      if o.visitId == v.id then
        rounds = rounds + 1
        if o.status == 'pending' then o.status = 'superseded' end
      end
    end
    check(rounds < C.MAX_OFFER_ROUNDS, 'too_many_offers')
    local fromSeller = id == v.seller or employee
    local oid = nextId(s, 'offer-')
    s.offers[oid] = {id = oid, visitId = v.id, listingId = l.id, buyer = v.buyer, seller = v.seller,
      from = fromSeller and v.seller or id, by = employee and id or nil,
      price = p.price, createdAt = now(), expiresAt = now() + C.OFFER_TTL, status = 'pending'}
    local out = copy(s.offers[oid])
    if not internal and not fromSeller and hooks.autoRespond then
      out.reply = hooks.autoRespond(s, v, l, s.offers[oid], ctx)
    end
    return out
  end
  local function closeSale(s, o, v, l, ctx, kind, staff)
    local buyer, seller = account(s, o.buyer), account(s, o.seller)
    check(buyer.balance + (v.refunded and 0 or v.deposit) >= o.price, 'insufficient_funds')
    local a = s.assets[l.assetId]; check(a and a.owner == l.seller, 'ownership_changed')
    local st = l.storeId and s.stores[l.storeId]
    if not staff and st and o.by then staff = playerRole(st, o.by, 'vendedor') end
    local fee = l.storeId and math.floor(o.price * C.STORE_FEE_RATE) or 0
    local commission = staff and math.floor(o.price * (staff.commission or 0) / 100) or 0
    refund(s, v)
    buyer.balance = buyer.balance - o.price
    seller.balance = seller.balance + o.price - fee - commission
    s.treasury = s.treasury + fee
    if staff then
      staff.sales = (staff.sales or 0) + 1; staff.earned = (staff.earned or 0) + commission
      if staff.kind == 'player' and s.accounts[staff.account] then
        credit(s, staff.account, commission); profession(s, staff.account, 'vendedor', commission)
      else
        s.treasury = s.treasury + commission
      end
    end
    seller.sales = (seller.sales or 0) + 1; buyer.purchases = (buyer.purchases or 0) + 1
    seller.earnings = (seller.earnings or 0) + o.price - fee - commission
    seller.reputation = math.min(100, (seller.reputation or 0) + 2)
    a.owner = o.buyer; a.listingId = nil; a.location = nil; a.transferCount = (a.transferCount or 0) + 1
    local rid = nextId(s, 'sale-')
    local r = {id = rid, kind = kind or 'sale', assetId = a.id, listingId = l.id, buyer = o.buyer, seller = o.seller,
      price = o.price, fee = fee, commission = commission > 0 and commission or nil, staffName = staff and staff.name or nil,
      createdAt = now(), dataRef = a.dataRef, summary = copy(a.summary),
      sellerLocalId = a.localId, buyerApplied = false, sellerApplied = false, storeId = l.storeId}
    -- Cars that stand on a lot or by the road are handed over right there.
    if l.display then
      r.pickup = {x = l.position.x, y = l.position.y, z = l.position.z, h = l.heading or 0}
      if seller.npc then r.sellerApplied = true end
    end
    s.receipts[rid] = r; a.lastReceipt = rid
    if (kind or 'sale') == 'sale' then recordFipe(s, a.summary, o.price) end
    l.status = 'sold'; l.soldAt = now(); l.reservation = nil
    o.status = 'accepted'; v.status = 'completed'; v.receiptId = rid
    if st then
      st.sales = (st.sales or 0) + 1; st.revenue = (st.revenue or 0) + o.price - fee - commission
      st.reputation = math.min(100, (st.reputation or 0) + 2)
    end
    local n = s.npcs[o.buyer]
    if n then n.status = 'purchased'; n.closedAt = now(); r.buyerApplied = true; a.owner = 'npc'; a.npcBuyer = n.id end
    notify(s, o.seller, 'Venda concluída', l.title .. ' vendido para ' .. buyer.name ..
      (staff and (' por ' .. staff.name) or '') .. ' por ' .. money(o.price) .. '.', {receiptId = rid})
    notify(s, o.buyer, 'Compra concluída', 'Você comprou ' .. l.title .. '.', {receiptId = rid})
    if not seller.npc or not buyer.npc then
      event(s, 'venda', (st and st.name or seller.name) .. ' vendeu ' .. l.title .. ' para ' .. buyer.name .. ' por ' ..
        money(o.price) .. '.', {listingId = l.id})
    end
    return r
  end
  hooks.closeSale = closeSale
  function handlers.accept(s, id, p, ctx)
    local o = s.offers[p.offerId]; check(o and o.status == 'pending', 'offer_unavailable')
    local v = s.visits[o.visitId]; check(v.status == 'arrived', 'visit_required')
    local l = listing(s, o.listingId); check(l.status == 'active' and l.reservation == v.id, 'listing_unavailable')
    local st = l.storeId and s.stores[l.storeId]
    local employee = st and id ~= o.seller and id ~= o.buyer and playerRole(st, id, 'vendedor') or nil
    local side = (id == o.buyer and 'buyer') or ((id == o.seller or employee) and 'seller') or nil
    check(side and ((side == 'buyer' and o.from ~= o.buyer) or (side == 'seller' and o.from ~= o.seller)), 'not_counterparty')
    check(ctx.map == l.map, 'wrong_map')
    if l.display then
      if side == 'buyer' then check(distance(ctx.position, l.position) <= C.LOT_BUY_RADIUS * 1.5, 'visit_required') end
    else
      check(distance(ctx.buyerPosition, l.position) <= C.BUYER_RADIUS and
        distance(ctx.sellerPosition, l.position) <= C.SELLER_RADIUS, 'visit_required')
      check(distance(ctx.vehiclePosition, l.position) <= C.VEHICLE_RADIUS, 'vehicle_absent')
    end
    local r = closeSale(s, o, v, l, ctx, nil, employee)
    local out = copy(r); out.dataRef = nil
    return out
  end
  function handlers.ack(s, id, p)
    local r = s.receipts[p.receiptId]; check(r, 'receipt_missing')
    if r.buyer == id then
      check(text(p.localId, 64), 'invalid_vehicle'); r.buyerApplied = true
      if s.assets[r.assetId] then s.assets[r.assetId].localId = p.localId end
    elseif r.seller == id then
      r.sellerApplied = true
    else
      check(false, 'not_counterparty')
    end
    return {receiptId = r.id, buyerApplied = r.buyerApplied, sellerApplied = r.sellerApplied}
  end

  -- Car dealership -------------------------------------------------------------
  function handlers.openStore(s, id, p, ctx)
    check(text(p.name, 64), 'invalid_name')
    check(position(ctx.position), 'location_unavailable')
    for _, st in pairs(s.stores) do
      check(st.owner ~= id, 'store_already_owned')
      check(st.map ~= ctx.map or distance(st.position, ctx.position) >= C.STORE_SPACING, 'store_too_close')
    end
    for _, w in pairs(s.workshops) do
      check(w.map ~= ctx.map or distance(w.position, ctx.position) >= C.SHOP_SPACING, 'too_close_to_workshop')
    end
    debit(s, id, C.STORE_COST); s.treasury = s.treasury + C.STORE_COST
    local sid = nextId(s, 'store-')
    s.stores[sid] = {id = sid, owner = id, name = p.name, position = pos(ctx.position), heading = ctx.heading,
      map = ctx.map, capacity = C.STORE_CAPACITY, open = true, opensAt = 8, closesAt = 20, reputation = 0, sales = 0,
      purchases = 0, revenue = 0, spent = 0, rent = C.STORE_RENT, nextRentAt = now() + 86400, createdAt = now(),
      npcEnabled = true, npcSellersEnabled = true, tradeBudget = 5000000}
    local st = s.stores[sid]
    businessDefaults(st, 'store')
    if p.lot ~= nil then
      check(validSpots(st, p.lot), 'invalid_spots')
      for i, sp in ipairs(p.lot) do st.lot[i] = {x = sp.x, y = sp.y, z = sp.z, h = sp.h or 0} end
    end
    event(s, 'loja', account(s, id).name .. ' abriu a loja de carros ' .. p.name .. '.', {storeId = sid})
    return copy(st)
  end
  function handlers.store(s, id, p)
    local st = s.stores[p.storeId]; check(st and st.owner == id, 'store_missing')
    if p.payRent and st.rentOverdue then
      debit(s, id, st.rentOverdue); s.treasury = s.treasury + st.rentOverdue; st.rentOverdue = nil
    end
    if p.name then check(text(p.name, 64), 'invalid_name'); st.name = p.name end
    if p.open ~= nil then check(not p.open or not st.rentOverdue, 'rent_overdue'); st.open = p.open == true end
    if p.npcEnabled ~= nil then st.npcEnabled = p.npcEnabled == true end
    if p.npcSellersEnabled ~= nil then st.npcSellersEnabled = p.npcSellersEnabled == true end
    if p.tradeBudget ~= nil then check(integer(p.tradeBudget, 0, C.MAX_PRICE), 'invalid_price'); st.tradeBudget = p.tradeBudget end
    if p.opensAt ~= nil then check(integer(p.opensAt, 0, 23), 'invalid_hours'); st.opensAt = p.opensAt end
    if p.closesAt ~= nil then check(integer(p.closesAt, 0, 23), 'invalid_hours'); st.closesAt = p.closesAt end
    if p.upgrade then
      check(st.capacity < C.STORE_MAX_CAPACITY, 'store_max_capacity')
      local cost = st.capacity * 500000
      debit(s, id, cost); s.treasury = s.treasury + cost; st.capacity = st.capacity + 2
    end
    return copy(st)
  end
  function handlers.closeStore(s, id, p)
    local st = s.stores[p.storeId]; check(st and st.owner == id, 'store_missing')
    for _, l in pairs(s.listings) do
      check(not (l.storeId == st.id and l.status == 'active'), 'store_has_stock')
    end
    for _, n in pairs(s.npcs) do
      if n.storeId == st.id and (n.status == 'travelling' or n.status == 'negotiating' or n.status == 'waiting') then
        n.status = 'leaving'; n.closedAt = now()
      end
    end
    local refundValue = math.floor(C.STORE_COST * 0.5) - (st.rentOverdue or 0)
    if refundValue > 0 then credit(s, id, refundValue) end
    s.treasury = s.treasury - math.max(0, refundValue)
    s.stores[st.id] = nil
    return {closed = st.id, refunded = math.max(0, refundValue)}
  end

  -- The owner left the server: their NPC visitors (simulated on that client) go away and free the cars.
  function handlers.ownerLeft(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local released = 0
    for _, n in pairs(s.npcs) do
      if n.owner == id and (n.status == 'travelling' or n.status == 'negotiating' or n.status == 'waiting') then
        n.status = 'leaving'; n.closedAt = now(); released = released + 1
        local v = n.visitId and s.visits[n.visitId]
        if v and (v.status == 'scheduled' or v.status == 'arrived') then cancelVisit(s, v, 'expired') end
        local o = n.orderId and s.orders[n.orderId]
        if o and (o.status == 'requested' or o.status == 'quoted') then refundOrder(s, o, 'expired') end
      end
    end
    return {released = released}
  end

  -- What a listed car is worth (cents), from its imported data; nil when unknown.
  local function fairValue(s, l)
    local a = l and s.assets[l.assetId]
    local v = a and a.summary and tonumber(a.summary.value)
    if v and v > 0 then return math.floor(v * 100) end
  end

  -- NPC buyers visit store stock. Details come from the owner's client inside
  -- server-enforced bounds; the server decides when a slot exists.
  function handlers.npcCreate(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local l = own(s, p.listingId, id); local st = l.storeId and s.stores[l.storeId]
    check(st and st.open and st.npcEnabled and l.status == 'active' and not l.reservation, 'store_unavailable')
    check(withinHours(st.opensAt, st.closesAt, ctx.hour or 12), 'store_closed')
    check(text(p.name, 64) and text(p.personality, 40), 'invalid_npc')
    check(integer(p.budget, C.MIN_PRICE, C.MAX_PRICE) and integer(p.firstOffer, C.MIN_PRICE, p.budget), 'invalid_price')
    check(p.budget <= math.floor(l.price * 1.25) and p.budget >= math.floor(l.price * 0.6), 'invalid_price')
    -- An overpriced car does not get rich buyers: budgets stop at a bit over what it is worth.
    local fair = fairValue(s, l)
    check(not fair or p.budget <= math.floor(fair * C.NPC_BUDGET_CAP), 'overpriced')
    local nid = nextId(s, 'npc-'); local vid = nextId(s, 'visit-')
    s.accounts[nid] = {id = nid, name = p.name, balance = p.budget, reputation = 0, sales = 0, earnings = 0,
      careerRevision = 0, npc = true}
    s.npcs[nid] = {id = nid, kind = 'buyer', owner = id, storeId = st.id, listingId = l.id, visitId = vid,
      name = p.name, personality = p.personality, budget = p.budget, firstOffer = p.firstOffer, status = 'travelling',
      rounds = 0, createdAt = now(), expiresAt = now() + C.NPC_TTL, vehicle = copy(p.vehicle)}
    s.visits[vid] = {id = vid, listingId = l.id, seller = id, buyer = nid, status = 'scheduled', npc = true,
      position = copy(l.position), map = l.map, scheduledAt = now(), expiresAt = now() + C.NPC_TTL, deposit = 0,
      createdAt = now()}
    l.reservation = vid
    notify(s, id, 'Cliente a caminho', p.name .. ' está vindo ver ' .. l.title .. '.', {npcId = nid})
    return copy(s.npcs[nid])
  end
  function handlers.npcArrive(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local n = s.npcs[p.npcId]; check(n and n.owner == id and n.status == 'travelling', 'npc_missing')
    n.status = 'negotiating'; n.arrivedAt = now(); n.expiresAt = now() + C.NPC_TTL
    if n.kind == 'buyer' then
      local v = s.visits[n.visitId]
      local result = handlers.arrive(s, n.id, {visitId = v.id}, ctx)
      local o = handlers.offer(s, n.id, {visitId = v.id, price = n.firstOffer})
      return {npc = copy(n), visit = result, offer = o}
    end
    if n.kind == 'customer' and n.orderId and s.orders[n.orderId] then
      s.orders[n.orderId].arrivedAt = now()
      if hooks.autoStart then hooks.autoStart(s, s.orders[n.orderId], ctx) end
    end
    if n.kind == 'seller' and hooks.autoTrade then
      local deal = hooks.autoTrade(s, n, ctx)
      if deal then return {npc = copy(n), trade = deal} end
    end
    return {npc = copy(n)}
  end
  -- Personalities negotiate differently; the reply is deterministic for a
  -- given state so retries and the server always agree.
  local style = {
    Entusiasta = {stretch = 1.12, step = 0.6}, ['Família'] = {stretch = 1.05, step = 0.5},
    Colecionador = {stretch = 1.2, step = 0.4}, Revendedor = {stretch = 1.02, step = 0.35},
    Apressado = {stretch = 1.08, step = 0.75}, ['Pechincheiro'] = {stretch = 1.0, step = 0.3},
  }
  local function npcStyle(n) return style[n.personality] or {stretch = 1.06, step = 0.5} end
  function handlers.npcReply(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local n = s.npcs[p.npcId]; check(n and n.owner == id and n.status == 'negotiating' and n.kind == 'buyer', 'npc_missing')
    local v = s.visits[n.visitId]; check(v.status == 'arrived', 'visit_closed')
    local sellerOffer
    for _, o in pairs(s.offers) do if o.visitId == v.id and o.status == 'pending' and o.from == id then sellerOffer = o end end
    check(sellerOffer, 'offer_unavailable')
    n.rounds = n.rounds + 1
    if sellerOffer.price <= n.budget then
      local l = listing(s, v.listingId)
      local r = closeSale(s, sellerOffer, v, l, ctx, 'sale')
      local out = copy(r); out.dataRef = nil
      return {receipt = out, npc = copy(n), message = 'Fechado! Pode preparar a papelada.'}
    end
    local st = npcStyle(n)
    if n.rounds >= C.NPC_ROUNDS or sellerOffer.price > math.floor(n.budget * st.stretch * 1.25) then
      cancelVisit(s, v, 'declined'); n.status = 'leaving'; n.closedAt = now()
      return {npc = copy(n), message = 'Passou do que eu posso pagar. Obrigado pela atenção.'}
    end
    local price = math.min(n.budget, math.floor(n.firstOffer + (n.budget - n.firstOffer) * st.step))
    if price <= n.firstOffer then price = math.min(n.budget, n.firstOffer + math.max(10000, math.floor(n.budget * 0.02))) end
    n.firstOffer = price
    local o = handlers.offer(s, n.id, {visitId = v.id, price = price})
    return {npc = copy(n), offer = o, message = 'Consigo chegar nesse valor.'}
  end

  -- NPC sellers bring cars to trade in at the store.
  function handlers.npcSellerCreate(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local st = s.stores[p.storeId]; check(st and st.owner == id and st.open and st.npcSellersEnabled, 'store_unavailable')
    check(withinHours(st.opensAt, st.closesAt, ctx.hour or 12), 'store_closed')
    check(text(p.name, 64) and text(p.personality, 40), 'invalid_npc')
    check(type(p.vehicle) == 'table' and text(p.vehicle.model, 64) and safeConfig(p.vehicle), 'invalid_vehicle')
    check(integer(p.vehicle.value, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(integer(p.asking, C.MIN_PRICE, C.MAX_PRICE) and integer(p.minimum, C.MIN_PRICE, p.asking), 'invalid_price')
    check(p.asking <= math.floor(p.vehicle.value * 1.1) and p.minimum >= math.floor(p.vehicle.value * 0.45), 'invalid_price')
    check(p.asking <= (st.tradeBudget or C.MAX_PRICE), 'over_trade_budget')
    for _, other in pairs(s.npcs) do
      check(not (other.storeId == st.id and other.kind == 'seller' and
        (other.status == 'travelling' or other.status == 'negotiating')), 'npc_busy')
    end
    local nid = nextId(s, 'npc-')
    s.accounts[nid] = {id = nid, name = p.name, balance = 0, reputation = 0, sales = 0, earnings = 0,
      careerRevision = 0, npc = true}
    s.npcs[nid] = {id = nid, kind = 'seller', owner = id, storeId = st.id, name = p.name, personality = p.personality,
      asking = p.asking, minimum = p.minimum, status = 'travelling', rounds = 0, createdAt = now(),
      expiresAt = now() + C.NPC_TTL, vehicle = {model = p.vehicle.model, config = p.vehicle.config,
      niceName = p.vehicle.niceName, value = p.vehicle.value, mileage = p.vehicle.mileage, year = p.vehicle.year,
      condition = p.vehicle.condition, wear = p.vehicle.wear}, position = copy(st.position), map = st.map}
    notify(s, id, 'Cliente quer vender', p.name .. ' está trazendo um ' .. (p.vehicle.niceName or p.vehicle.model) ..
      ' para avaliação.', {npcId = nid})
    return copy(s.npcs[nid])
  end
  -- The store owner counters or accepts the NPC seller's price.
  function handlers.tradeOffer(s, id, p, ctx)
    local n = s.npcs[p.npcId]; check(n and n.owner == id and n.kind == 'seller' and n.status == 'negotiating', 'npc_missing')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    local st = s.stores[n.storeId]; check(st, 'store_missing')
    check(distance(ctx.position, st.position) <= C.STORE_RADIUS * 1.5, 'outside_store')
    n.rounds = n.rounds + 1
    if p.price >= n.minimum or p.price >= n.asking then
      local price = math.min(p.price, n.asking)
      check(p.listPrice == nil or integer(p.listPrice, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
      local r = hooks.buyTradeIn(s, st, n, price, p.toLot == true, p.listPrice)
      local out = copy(r); out.dataRef = nil
      return {receipt = out, npc = copy(n), message = r.toLot and 'Negócio fechado. O carro já está no seu pátio.' or
        'Negócio fechado. As chaves são suas!'}
    end
    local st2 = npcStyle(n)
    if n.rounds >= C.NPC_ROUNDS + 1 or p.price < math.floor(n.minimum * 0.75) then
      n.status = 'leaving'; n.closedAt = now()
      return {npc = copy(n), message = 'Por esse valor não dá. Vou procurar outra loja.'}
    end
    -- The seller comes down towards its secret minimum.
    local newAsk = math.max(n.minimum, math.floor(n.asking - (n.asking - math.max(p.price, n.minimum)) * st2.step))
    if newAsk >= n.asking then newAsk = math.max(n.minimum, n.asking - math.max(10000, math.floor(n.asking * 0.02))) end
    n.asking = newAsk
    return {npc = copy(n), message = 'Consigo fazer por ' .. string.format('%.0f', newAsk / 100) .. '.'}
  end
  -- Shared by the owner (tradeOffer) and the buyer on staff (autoTrade).
  function hooks.buyTradeIn(s, st, n, price, toLot, listPrice, staffName)
    local id = st.owner
    debit(s, id, price)
    st.purchases = (st.purchases or 0) + 1; st.spent = (st.spent or 0) + price
    local vin = nextId(s, 'RH-')
    local data = {model = n.vehicle.model, config = n.vehicle.config, niceName = n.vehicle.niceName,
      mileage = n.vehicle.mileage, year = n.vehicle.year, configBaseValue = n.vehicle.value and math.floor(n.vehicle.value / 100),
      value = n.vehicle.value and math.floor(n.vehicle.value / 100), wear = n.vehicle.wear,
      condition = n.vehicle.condition, tradeIn = true}
    s.assets[vin] = {id = vin, owner = id, originAccount = n.id, importedAt = now(), dataRef = putBlob(data),
      summary = summarize(data)}
    local rid = nextId(s, 'trade-')
    local r = {id = rid, kind = 'trade_in', assetId = vin, buyer = id, seller = n.id, price = price, fee = 0,
      createdAt = now(), dataRef = s.assets[vin].dataRef, summary = copy(s.assets[vin].summary),
      buyerApplied = false, sellerApplied = true, storeId = st.id, staffName = staffName}
    s.receipts[rid] = r
    s.assets[vin].lastReceipt = rid
    if toLot and hooks.lotFor(s, st) then
      local markup = (st.policy and st.policy.markupPct or 25)
      local value = n.vehicle.value or price
      local ask = listPrice or math.max(price + 10000, math.floor(value * (1 + markup / 100) / 10000) * 10000)
      hooks.stockOnLot(s, st, s.assets[vin], ask)
      r.toLot = true; r.buyerApplied = true
    end
    n.status = 'sold'; n.closedAt = now(); n.price = price; n.receiptId = rid
    notify(s, id, 'Carro comprado', (staffName and (staffName .. ' comprou') or 'Você comprou') .. ' o ' ..
      (n.vehicle.niceName or n.vehicle.model) .. ' de ' .. n.name .. ' por ' .. money(price) ..
      (r.toLot and '. Ele já está no pátio.' or '. Ele já está no seu nome.'), {receiptId = rid})
    return r
  end
  -- A buyer on staff closes trade-ins within the store policy, straight to the lot.
  function hooks.autoTrade(s, n, ctx)
    local st = s.stores[n.storeId]
    if not st or not (st.policy and st.policy.autoBuy) then return nil end
    local m = npcStaff(st, 'comprador')
    if not m then return nil end
    local limit = math.floor((n.vehicle.value or 0) * (st.policy.buyPct or 65) / 100)
    if not hooks.lotFor(s, st) or n.minimum > limit or s.accounts[st.owner].balance < n.minimum then
      n.status = 'leaving'; n.closedAt = now()
      return {kind = 'declined', message = m.name .. ' avaliou o ' .. (n.vehicle.niceName or 'carro') .. ' e recusou.'}
    end
    local price = math.max(n.minimum, math.min(n.asking, limit))
    local r = hooks.buyTradeIn(s, st, n, price, true, nil, m.name)
    m.sales = (m.sales or 0) + 1
    return {kind = 'bought', price = price, receiptId = r.id, message = m.name .. ' comprou o carro por ' .. money(price) .. '.'}
  end
  function handlers.dismissNpc(s, id, p)
    local n = s.npcs[p.npcId]; check(n and n.owner == id, 'npc_missing')
    if n.visitId and s.visits[n.visitId] then
      local v = s.visits[n.visitId]
      if v.status == 'scheduled' or v.status == 'arrived' then cancelVisit(s, v, 'declined') end
    end
    if n.orderId and s.orders[n.orderId] then
      local o = s.orders[n.orderId]
      if o.status ~= 'completed' and o.status ~= 'in_progress' then refundOrder(s, o, 'declined') end
    end
    if n.status ~= 'purchased' and n.status ~= 'sold' and n.status ~= 'served' then n.status = 'leaving' end
    n.closedAt = now()
    return copy(n)
  end

  -- Workshops ------------------------------------------------------------------
  function handlers.openShop(s, id, p, ctx)
    check(text(p.name, 64), 'invalid_name')
    check(position(ctx.position), 'location_unavailable')
    for _, w in pairs(s.workshops) do
      check(w.owner ~= id, 'shop_already_owned')
      check(w.map ~= ctx.map or distance(w.position, ctx.position) >= C.SHOP_SPACING, 'shop_too_close')
    end
    for _, st in pairs(s.stores) do
      check(st.map ~= ctx.map or distance(st.position, ctx.position) >= C.SHOP_SPACING, 'too_close_to_store')
    end
    debit(s, id, C.SHOP_COST); s.treasury = s.treasury + C.SHOP_COST
    local wid = nextId(s, 'shop-')
    s.workshops[wid] = {id = wid, owner = id, name = p.name, position = pos(ctx.position), heading = ctx.heading,
      map = ctx.map, bays = C.SHOP_BAYS, open = true, opensAt = 7, closesAt = 19, reputation = 0, jobs = 0,
      revenue = 0, partsSpent = 0, rent = C.SHOP_RENT, nextRentAt = now() + 86400, createdAt = now(),
      npcEnabled = true, laborRate = 12000, markup = 25,
      services = {repair = true, maintenance = true, paint = true, tuning = true}}
    businessDefaults(s.workshops[wid], 'shop')
    event(s, 'oficina', account(s, id).name .. ' abriu a oficina ' .. p.name .. '.', {workshopId = wid})
    return copy(s.workshops[wid])
  end
  function handlers.shop(s, id, p)
    local w = s.workshops[p.workshopId]; check(w and w.owner == id, 'shop_missing')
    if p.payRent and w.rentOverdue then
      debit(s, id, w.rentOverdue); s.treasury = s.treasury + w.rentOverdue; w.rentOverdue = nil
    end
    if p.name then check(text(p.name, 64), 'invalid_name'); w.name = p.name end
    if p.open ~= nil then check(not p.open or not w.rentOverdue, 'rent_overdue'); w.open = p.open == true end
    if p.npcEnabled ~= nil then w.npcEnabled = p.npcEnabled == true end
    if p.opensAt ~= nil then check(integer(p.opensAt, 0, 23), 'invalid_hours'); w.opensAt = p.opensAt end
    if p.closesAt ~= nil then check(integer(p.closesAt, 0, 23), 'invalid_hours'); w.closesAt = p.closesAt end
    if p.laborRate ~= nil then check(integer(p.laborRate, 1000, 1000000), 'invalid_price'); w.laborRate = p.laborRate end
    if p.markup ~= nil then check(integer(p.markup, 0, 200), 'invalid_price'); w.markup = p.markup end
    if type(p.services) == 'table' then
      for _, k in ipairs({'repair', 'maintenance', 'paint', 'tuning'}) do
        if p.services[k] ~= nil then w.services[k] = p.services[k] == true end
      end
    end
    if p.upgrade then
      check(w.bays < C.SHOP_MAX_BAYS, 'shop_max_bays')
      local cost = w.bays * 900000
      debit(s, id, cost); s.treasury = s.treasury + cost; w.bays = w.bays + 1
    end
    return copy(w)
  end
  function handlers.closeShop(s, id, p)
    local w = s.workshops[p.workshopId]; check(w and w.owner == id, 'shop_missing')
    for _, o in pairs(s.orders) do
      check(not (o.workshopId == w.id and (o.status == 'accepted' or o.status == 'in_progress')), 'shop_has_jobs')
    end
    for _, o in pairs(s.orders) do
      if o.workshopId == w.id and (o.status == 'requested' or o.status == 'quoted') then refundOrder(s, o, 'cancelled') end
    end
    local refundValue = math.floor(C.SHOP_COST * 0.5) - (w.rentOverdue or 0)
    if refundValue > 0 then credit(s, id, refundValue) end
    s.treasury = s.treasury - math.max(0, refundValue)
    s.workshops[w.id] = nil
    return {closed = w.id, refunded = math.max(0, refundValue)}
  end

  local function busyBays(s, w)
    local n = 0
    for _, o in pairs(s.orders) do if o.workshopId == w.id and o.status == 'in_progress' then n = n + 1 end end
    return n
  end
  local function validDiagnosis(d)
    return type(d) == 'table' and integer(d.partsCost or 0, 0, C.MAX_PRICE) and integer(d.brokenParts or 0, 0, 100000)
      and optText(d.notes, 600)
  end
  local function serviceItems(items)
    if type(items) ~= 'table' or #items < 1 or #items > 12 then return false end
    for _, it in ipairs(items) do
      if type(it) ~= 'table' or not text(it.label, 80) or not integer(it.amount, 0, C.MAX_PRICE) then return false end
      if it.kind ~= nil and not text(it.kind, 20) then return false end
    end
    return true
  end

  -- A player asks a workshop to look at a car parked at the shop.
  function handlers.serviceRequest(s, id, p, ctx)
    local w = s.workshops[p.workshopId]; check(w and w.open, 'shop_closed')
    check(w.owner ~= id, 'own_shop')
    check(withinHours(w.opensAt, w.closesAt, ctx.hour or 12), 'shop_closed')
    check(type(p.vehicle) == 'table' and text(p.vehicle.localId, 64) and text(p.vehicle.model, 64), 'invalid_vehicle')
    check(validDiagnosis(p.diagnosis), 'invalid_diagnosis')
    check(optText(p.notes, 600), 'invalid_text')
    check(ctx.map == w.map and distance(ctx.position, w.position) <= C.SHOP_RADIUS * 1.5, 'outside_shop')
    check(distance(ctx.vehiclePosition, w.position) <= C.SHOP_RADIUS * 1.5, 'vehicle_absent')
    for _, o in pairs(s.orders) do
      check(not (o.customer == id and o.vehicle.localId == p.vehicle.localId and
        (o.status == 'requested' or o.status == 'quoted' or o.status == 'accepted' or o.status == 'in_progress')),
        'order_exists')
    end
    local oid = nextId(s, 'os-')
    s.orders[oid] = {id = oid, workshopId = w.id, shopName = w.name, shopOwner = w.owner, customer = id,
      customerName = account(s, id).name, status = 'requested',
      vehicle = {localId = p.vehicle.localId, model = p.vehicle.model, niceName = p.vehicle.niceName,
        assetId = p.vehicle.assetId, mileage = p.vehicle.mileage},
      diagnosis = copy(p.diagnosis), notes = p.notes, createdAt = now(), expiresAt = now() + C.ORDER_TTL,
      position = copy(w.position), map = w.map}
    notify(s, w.owner, 'Novo pedido de serviço', account(s, id).name .. ' trouxe um ' .. (p.vehicle.niceName or p.vehicle.model) ..
      ' para a ' .. w.name .. '.', {orderId = oid})
    if hooks.autoQuote then hooks.autoQuote(s, w, s.orders[oid]) end
    return copy(s.orders[oid])
  end
  function handlers.serviceQuote(s, id, p)
    local o = s.orders[p.orderId]
    local w = o and s.workshops[o.workshopId]
    check(o and (o.shopOwner == id or (w and playerRole(w, id, 'mecanico'))), 'order_missing')
    if id ~= o.shopOwner then o.mechanic = id end
    check(o.status == 'requested' or o.status == 'quoted', 'order_closed')
    check(serviceItems(p.items), 'invalid_quote')
    local total, parts = 0, 0
    for _, it in ipairs(p.items) do
      total = total + it.amount
      if it.kind == 'parts' then parts = parts + it.amount end
    end
    check(total >= C.MIN_PRICE and total <= C.MAX_PRICE, 'invalid_price')
    check(integer(p.minutes or 5, 1, 240), 'invalid_time')
    -- The shop pays the real parts cost from the diagnosis; what it charges is its own business.
    local partsCost = (o.diagnosis and o.diagnosis.partsCost) or parts
    o.quote = {items = copy(p.items), total = total, parts = partsCost, charged = parts,
      minutes = p.minutes or 5, quotedAt = now()}
    o.status = 'quoted'; o.expiresAt = now() + C.QUOTE_TTL
    notify(s, o.customer, 'Orçamento recebido', o.shopName .. ' enviou um orçamento.', {orderId = o.id})
    local n = s.npcs[o.customer]
    if n and n.kind == 'customer' then
      -- NPC customers answer immediately within their budget.
      n.rounds = (n.rounds or 0) + 1
      if total <= n.budget then
        o.paid = total; o.status = 'accepted'; o.acceptedAt = now(); n.status = 'waiting'
        o.expiresAt = now() + C.ORDER_TTL
        return {order = copy(o), npc = copy(n), message = 'Pode fazer o serviço.'}
      end
      local st = npcStyle(n)
      if n.rounds >= C.NPC_ROUNDS or total > math.floor(n.budget * st.stretch * 1.3) then
        refundOrder(s, o, 'declined'); n.status = 'leaving'; n.closedAt = now()
        return {order = copy(o), npc = copy(n), message = 'Está caro demais para mim. Vou procurar outra oficina.'}
      end
      return {order = copy(o), npc = copy(n), message = 'Consegue fazer por ' .. string.format('%.0f', n.budget / 100) .. '?'}
    end
    return copy(o)
  end
  function handlers.serviceAccept(s, id, p, ctx)
    local o = s.orders[p.orderId]; check(o and o.customer == id, 'order_missing')
    check(o.status == 'quoted' and o.quote, 'order_closed')
    debit(s, id, o.quote.total)
    o.paid = o.quote.total; o.status = 'accepted'; o.acceptedAt = now(); o.expiresAt = now() + C.ORDER_TTL
    notify(s, o.shopOwner, 'Orçamento aprovado', o.customerName .. ' aprovou o serviço no ' ..
      (o.vehicle.niceName or o.vehicle.model) .. '.', {orderId = o.id})
    if hooks.autoStart then hooks.autoStart(s, o, ctx) end
    return copy(o)
  end
  function handlers.serviceDecline(s, id, p)
    local o = s.orders[p.orderId]; check(o and (o.customer == id or o.shopOwner == id), 'order_missing')
    check(o.status == 'requested' or o.status == 'quoted' or o.status == 'accepted', 'order_closed')
    refundOrder(s, o, o.customer == id and 'declined' or 'rejected')
    notify(s, o.customer == id and o.shopOwner or o.customer, 'Serviço cancelado',
      'O serviço no ' .. (o.vehicle.niceName or o.vehicle.model) .. ' foi cancelado.', {orderId = o.id})
    return copy(o)
  end
  function handlers.serviceStart(s, id, p, ctx, auto)
    local o = s.orders[p.orderId]
    local w = o and s.workshops[o.workshopId]
    check(o and w and (auto or o.shopOwner == id or playerRole(w, id, 'mecanico')), 'order_missing')
    check(o.status == 'accepted', 'order_not_accepted')
    check(busyBays(s, w) < w.bays, 'bays_full')
    if not auto then check(distance(ctx.position, w.position) <= C.SHOP_RADIUS * 1.5, 'outside_shop') end
    if not (auto and o.npc) then check(distance(ctx.vehiclePosition, w.position) <= C.SHOP_RADIUS * 1.5, 'vehicle_absent') end
    if id ~= o.shopOwner and not auto then o.mechanic = id end
    if auto then o.mechanicStaff = auto end
    local parts = o.quote.parts or 0
    debit(s, o.shopOwner, parts); s.treasury = s.treasury + parts
    w.partsSpent = (w.partsSpent or 0) + parts
    o.status = 'in_progress'; o.startedAt = now()
    local minutes = o.quote.minutes or 5
    o.finishesAt = now() + math.floor(minutes * 60 * math.max(0.5, 1 - (w.reputation or 0) / 200))
    o.expiresAt = o.finishesAt + C.ORDER_TTL
    return copy(o)
  end
  local function completeOrder(s, o)
    local id = o.shopOwner
    local w = s.workshops[o.workshopId]
    credit(s, id, o.paid or 0)
    local labor = math.max(0, (o.paid or 0) - ((o.quote and o.quote.charged) or 0))
    local mech = w and ((o.mechanic and playerRole(w, o.mechanic, 'mecanico')) or (o.mechanicStaff and w.staff[o.mechanicStaff]))
    if mech then
      local commission = math.floor(labor * (mech.commission or 0) / 100)
      if commission > 0 and s.accounts[id].balance >= commission then
        s.accounts[id].balance = s.accounts[id].balance - commission
        mech.earned = (mech.earned or 0) + commission
        if mech.kind == 'player' and s.accounts[mech.account] then
          credit(s, mech.account, commission); profession(s, mech.account, 'mecanico', commission)
        else
          s.treasury = s.treasury + commission
        end
      end
      mech.sales = (mech.sales or 0) + 1
    end
    o.status = 'completed'; o.completedAt = now()
    local owner = account(s, id)
    owner.earnings = (owner.earnings or 0) + (o.paid or 0) - (o.quote.parts or 0)
    owner.reputation = math.min(100, (owner.reputation or 0) + 1)
    if w then
      w.jobs = (w.jobs or 0) + 1; w.revenue = (w.revenue or 0) + (o.paid or 0)
      w.reputation = math.min(100, (w.reputation or 0) + 2)
    end
    local n = s.npcs[o.customer]
    if n then n.status = 'served'; n.closedAt = now(); o.customerApplied = true end
    notify(s, o.customer, 'Serviço concluído', 'Seu ' .. (o.vehicle.niceName or o.vehicle.model) ..
      ' está pronto na ' .. o.shopName .. '.', {orderId = o.id})
    notify(s, id, 'Serviço concluído', 'O ' .. (o.vehicle.niceName or o.vehicle.model) .. ' de ' ..
      (o.customerName or 'cliente') .. ' está pronto.', {orderId = o.id})
    return copy(o)
  end
  function handlers.serviceComplete(s, id, p)
    local o = s.orders[p.orderId]; check(o and o.shopOwner == id, 'order_missing')
    check(o.status == 'in_progress', 'order_not_started')
    check(now() >= o.finishesAt, 'service_running')
    return completeOrder(s, o)
  end
  function handlers.serviceAck(s, id, p)
    local o = s.orders[p.orderId]; check(o and o.customer == id and o.status == 'completed', 'order_missing')
    o.customerApplied = true
    return {orderId = o.id, customerApplied = true}
  end
  function handlers.rateShop(s, id, p)
    local o = s.orders[p.orderId]; check(o and o.customer == id and o.status == 'completed', 'order_missing')
    check(not o.rating, 'already_rated'); check(integer(p.stars, 1, 5), 'invalid_rating')
    o.rating = p.stars
    local w = s.workshops[o.workshopId]
    if w then w.reputation = clamp((w.reputation or 0) + (p.stars - 3) * 2, 0, 100) end
    return copy(o)
  end
  -- Mechanics on duty quote with the shop policy and start when a bay is free.
  function hooks.autoQuote(s, w, o)
    if not (w.policy and w.policy.autoQuote) or o.status ~= 'requested' then return end
    if not npcStaff(w, 'mecanico') then return end
    local d = o.diagnosis or {}
    local parts = math.floor((d.partsCost or 0) * (1 + (w.policy.markupPct or 30) / 100))
    local labor = math.floor((w.laborRate or 12000) * (1 + (d.brokenParts or 1) * 0.5))
    local items = {{kind = 'labor', label = 'Mão de obra', amount = math.max(C.MIN_PRICE, labor)}}
    if parts > 0 then table.insert(items, 1, {kind = 'parts', label = 'Peças', amount = parts}) end
    local minutes = math.max(2, math.min(30, (d.minutes or 3) + (d.brokenParts or 0)))
    local ok = pcall(handlers.serviceQuote, s, w.owner, {orderId = o.id, items = items, minutes = minutes})
    if ok then o.autoQuoted = true end
  end
  function hooks.autoStart(s, o, ctx)
    local w = s.workshops[o.workshopId]
    if not w or o.status ~= 'accepted' or not (w.policy and w.policy.autoQuote) then return end
    local m = npcStaff(w, 'mecanico')
    if not m or busyBays(s, w) >= w.bays then return end
    if o.npc and not o.arrivedAt then return end
    pcall(handlers.serviceStart, s, w.owner, {orderId = o.id}, ctx or {}, m.id)
  end

  -- NPC customers: the owner's client describes the job, the server bounds it.
  function handlers.npcCustomerCreate(s, id, p, ctx)
    check(ctx.system == true, 'server_only')
    local w = s.workshops[p.workshopId]; check(w and w.owner == id and w.open and w.npcEnabled, 'shop_unavailable')
    check(withinHours(w.opensAt, w.closesAt, ctx.hour or 12), 'shop_closed')
    check(text(p.name, 64) and text(p.personality, 40), 'invalid_npc')
    check(type(p.vehicle) == 'table' and text(p.vehicle.model, 64) and safeConfig(p.vehicle), 'invalid_vehicle')
    check(validDiagnosis(p.diagnosis), 'invalid_diagnosis')
    check(integer(p.budget, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(p.budget <= math.max(200000, (p.diagnosis.partsCost or 0) * 3 + 300000), 'invalid_price')
    local waiting = 0
    for _, n in pairs(s.npcs) do
      if n.workshopId == w.id and n.kind == 'customer' and n.status ~= 'leaving' and n.status ~= 'served' then waiting = waiting + 1 end
    end
    check(waiting < w.bays + 1, 'npc_busy')
    local nid = nextId(s, 'npc-'); local oid = nextId(s, 'os-')
    s.accounts[nid] = {id = nid, name = p.name, balance = p.budget, reputation = 0, sales = 0, earnings = 0,
      careerRevision = 0, npc = true}
    s.npcs[nid] = {id = nid, kind = 'customer', owner = id, workshopId = w.id, orderId = oid, name = p.name,
      personality = p.personality, budget = p.budget, status = 'travelling', rounds = 0, createdAt = now(),
      expiresAt = now() + C.NPC_TTL, vehicle = copy(p.vehicle), position = copy(w.position), map = w.map}
    s.orders[oid] = {id = oid, workshopId = w.id, shopName = w.name, shopOwner = id, customer = nid,
      customerName = p.name, npc = true, status = 'requested',
      vehicle = {localId = nid, model = p.vehicle.model, niceName = p.vehicle.niceName, mileage = p.vehicle.mileage},
      diagnosis = copy(p.diagnosis), notes = p.diagnosis.notes, createdAt = now(), expiresAt = now() + C.NPC_TTL,
      position = copy(w.position), map = w.map}
    notify(s, id, 'Cliente a caminho', p.name .. ' está trazendo um ' .. (p.vehicle.niceName or p.vehicle.model) ..
      ' para a ' .. w.name .. '.', {orderId = oid, npcId = nid})
    if hooks.autoQuote then hooks.autoQuote(s, w, s.orders[oid]) end
    return copy(s.npcs[nid])
  end

  -- Car lot ----------------------------------------------------------------------
  -- Stock cars leave the owner's garage and stand on the store's marked spots. A
  -- client near the lot spawns them (BeamMP shows them to everyone) with a price
  -- sign; buyers walk up and make offers there.
  function validSpots(st, spots)
    if type(spots) ~= 'table' or #spots > C.STORE_MAX_CAPACITY then return false end
    for i, p in ipairs(spots) do
      if not position(p) or (p.h ~= nil and (type(p.h) ~= 'number' or p.h ~= p.h)) then return false end
      if distance(p, st.position) > C.LOT_RADIUS then return false end
      for j = 1, i - 1 do if distance(p, spots[j]) < C.LOT_SPACING then return false end end
    end
    return true
  end
  local function lotUsage(s, st)
    local used, count = {}, 0
    for _, l in pairs(s.listings) do
      if l.storeId == st.id and l.status == 'active' and l.lot then used[l.lotSpot] = l; count = count + 1 end
    end
    return used, count
  end
  local function freeSpot(s, st)
    local used = lotUsage(s, st)
    for i = 1, math.min(#(st.lot or {}), st.capacity) do if not used[i] then return i end end
  end
  local function stockListing(s, st, a, price, title, description, spot, photos)
    local sp = st.lot[spot]
    local lid = nextId(s, 'ad-')
    s.listings[lid] = {id = lid, assetId = a.id, seller = st.owner, status = 'active',
      title = title or (a.summary and a.summary.niceName) or 'Carro', description = description or '', price = price,
      photos = photos or {}, position = pos(sp), heading = sp.h or 0, map = st.map, storeId = st.id, lot = true,
      display = true, lotSpot = spot, createdAt = now(), expiresAt = now() + C.LOT_TTL, views = 0, negotiable = true,
      revision = 1}
    a.listingId = lid; a.location = 'lot'
    return s.listings[lid]
  end
  function hooks.lotFor(s, st) return st.lot and #st.lot > 0 and freeSpot(s, st) end
  function hooks.stockOnLot(s, st, a, price)
    local spot = freeSpot(s, st)
    if not spot then return nil end
    return stockListing(s, st, a, price, nil, nil, spot, {})
  end
  -- A walk-in NPC buys a lot car from the salesperson (offline economy).
  function hooks.npcLotSale(s, st, l, price, staff)
    local nid = newNpcAccount(s, personName(s))
    s.accounts[nid].balance = price; s.accounts[nid].transient = true; s.accounts[nid].createdAt = now()
    local vid = nextId(s, 'visit-')
    local v = {id = vid, listingId = l.id, seller = l.seller, buyer = nid, status = 'arrived', walkIn = true, npc = true,
      position = copy(l.position), map = l.map, scheduledAt = now(), arrivedAt = now(), expiresAt = now() + 60, deposit = 0,
      createdAt = now()}
    s.visits[vid] = v; l.reservation = vid
    local oid = nextId(s, 'offer-')
    s.offers[oid] = {id = oid, visitId = vid, listingId = l.id, buyer = nid, seller = l.seller, from = nid, price = price,
      createdAt = now(), expiresAt = now() + 60, status = 'pending'}
    local r = closeSale(s, s.offers[oid], v, l, {}, 'sale', staff)
    r.buyerApplied = true
    if s.assets[l.assetId] then s.assets[l.assetId].owner = 'npc' end
    return r
  end
  function handlers.setLot(s, id, p)
    local st = s.stores[p.storeId]; check(st and st.owner == id, 'store_missing')
    check(validSpots(st, p.spots), 'invalid_spots')
    local used = lotUsage(s, st)
    for i in pairs(used) do check(i <= #p.spots, 'lot_in_use') end
    st.lot = {}
    for i, sp in ipairs(p.spots) do st.lot[i] = {x = sp.x, y = sp.y, z = sp.z, h = sp.h or 0} end
    for i, l in pairs(used) do l.position = pos(st.lot[i]); l.heading = st.lot[i].h; l.revision = l.revision + 1 end
    return {lot = copy(st.lot)}
  end
  function handlers.stockIn(s, id, p, ctx)
    local st = s.stores[p.storeId]; check(st and st.owner == id, 'store_missing')
    local a = s.assets[p.assetId]; check(a and a.owner == id, 'not_owner'); check(not a.listingId, 'already_listed')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(optText(p.title, 100) and optText(p.description, 1600), 'invalid_text')
    check(#(st.lot or {}) > 0, 'lot_not_set')
    check(distance(ctx.position, st.position) <= C.LOT_RADIUS * 1.5, 'outside_store')
    check(distance(ctx.vehiclePosition, st.position) <= C.LOT_RADIUS * 1.5, 'vehicle_absent')
    local spot = p.spot
    if spot ~= nil then check(integer(spot, 1, math.min(#st.lot, st.capacity)) and not lotUsage(s, st)[spot], 'spot_taken')
    else spot = freeSpot(s, st) end
    check(spot, 'store_full')
    local photos = {}
    for _, ph in ipairs(type(p.photos) == 'table' and p.photos or {}) do
      if text(ph, 128) and env.photoOwned(id, ph) and #photos < 6 then photos[#photos + 1] = ph end
    end
    local l = stockListing(s, st, a, p.price, p.title, p.description, spot, photos)
    return publicListing(s, l)
  end
  -- The owner takes a lot car back into the garage; it is handed over on its spot.
  function handlers.stockOut(s, id, p)
    local l = listing(s, p.listingId); check((l.lot or l.street) and l.status == 'active', 'listing_unavailable')
    if l.lot then
      local st = s.stores[l.storeId]; check(st and st.owner == id, 'store_missing')
    else
      check(l.seller == id, 'not_owner')
    end
    check(not l.reservation, 'listing_locked')
    local a = s.assets[l.assetId]; check(a and a.owner == id, 'not_owner')
    l.status = 'cancelled'; l.closedAt = now()
    local out = copy(returnDisplayCar(s, l, id)); out.dataRef = nil
    return out
  end

  -- "Vende-se": the owner leaves a parked car with a sign; it answers offers down to the floor price
  -- and NPC buyers may take it while the owner is away.
  function handlers.streetSell(s, id, p, ctx)
    local a = s.assets[p.assetId]; check(a and a.owner == id, 'not_owner'); check(not a.listingId, 'already_listed')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    check(integer(p.minimum, math.floor(p.price * 0.5), p.price), 'invalid_minimum')
    check(optText(p.title, 100) and optText(p.description, 1600), 'invalid_text')
    check(position(ctx.vehiclePosition), 'vehicle_absent')
    check(distance(ctx.position, ctx.vehiclePosition) <= C.LOT_BUY_RADIUS * 2, 'too_far')
    for _, st in pairs(s.stores) do check(distance(st.position, ctx.vehiclePosition) > C.LOT_RADIUS, 'too_close_to_store') end
    local mine = 0
    for _, l in pairs(s.listings) do if l.street and l.seller == id and l.status == 'active' then mine = mine + 1 end end
    check(mine < C.STREET_MAX, 'street_full')
    local lid = nextId(s, 'ad-')
    s.listings[lid] = {id = lid, assetId = a.id, seller = id, status = 'active',
      title = p.title or (a.summary and a.summary.niceName) or 'Carro', description = p.description or '', price = p.price,
      minimum = p.minimum, photos = {}, position = pos(ctx.vehiclePosition), heading = tonumber(p.heading) or 0, map = ctx.map,
      display = true, street = true, createdAt = now(), expiresAt = now() + C.STREET_TTL, views = 0, negotiable = true, revision = 1}
    a.listingId = lid; a.location = 'street'
    event(s, 'rua', account(s, id).name .. ' deixou um ' .. s.listings[lid].title .. ' à venda na rua por ' .. money(p.price) .. '.',
      {listingId = lid})
    return publicListing(s, s.listings[lid])
  end
  function handlers.price(s, id, p)
    local l = listing(s, p.listingId); check(l.status == 'active' and not l.reservation, 'listing_locked')
    local st = l.storeId and s.stores[l.storeId]
    check(l.seller == id or (st and playerRole(st, id, 'vendedor')), 'not_owner')
    check(integer(p.price, C.MIN_PRICE, C.MAX_PRICE), 'invalid_price')
    l.price = p.price; l.revision = l.revision + 1
    return publicListing(s, l)
  end
  -- Light vehicle description for whoever spawns a display car.
  function handlers.displayData(s, id, p)
    local l = listing(s, p.listingId); check(l.display and l.status == 'active', 'listing_unavailable')
    local a = s.assets[l.assetId]; check(a, 'vehicle_data_missing')
    local data = getBlob(a.dataRef) or {}
    return {listingId = l.id, model = data.model, config = data.config, niceName = data.niceName,
      position = copy(l.position), heading = l.heading or 0, revision = l.revision,
      partConditions = data.partConditions and copy(data.partConditions) or nil,
      mileage = data.mileage, wear = data.wear}
  end

  -- Walk-up offer on a car standing on a lot or by the road (NPC private seller).
  function handlers.walkIn(s, id, p, ctx)
    local l = listing(s, p.listingId); check(l.status == 'active' and l.display, 'listing_unavailable')
    check(l.seller ~= id and not actsForStore(s, id, l.storeId and s.stores[l.storeId]), 'own_listing')
    check(ctx.map == nil or ctx.map == l.map, 'wrong_map')
    check(distance(ctx.position, l.position) <= C.LOT_BUY_RADIUS, 'visit_required')
    local v = l.reservation and s.visits[l.reservation]
    if v then
      check(v.buyer == id, 'already_reserved')
    else
      local vid = nextId(s, 'visit-')
      v = {id = vid, listingId = l.id, seller = l.seller, buyer = id, status = 'arrived', walkIn = true,
        position = copy(l.position), map = l.map, scheduledAt = now(), arrivedAt = now(),
        expiresAt = now() + C.VISIT_TTL, deposit = 0, createdAt = now()}
      s.visits[vid] = v; l.reservation = vid; l.views = (l.views or 0) + 1
      notify(s, l.seller, 'Cliente no pátio', account(s, id).name .. ' está olhando ' .. l.title .. '.',
        {visitId = vid, listingId = l.id})
    end
    firstStep(s, id, 'walkIn')
    return handlers.offer(s, id, {visitId = v.id, price = p.price}, ctx)
  end

  -- Who answers a buyer on behalf of the seller without the seller typing:
  -- NPC private sellers, and stores with an NPC salesperson on auto-sell.
  local function autoSeller(s, l)
    local seller = s.accounts[l.seller]
    if seller and seller.npc and l.npcSeller then return {kind = 'npc', minimum = l.minimum or math.floor(l.price * 0.85)} end
    if l.street then return {kind = 'owner', minimum = l.minimum or math.floor(l.price * 0.9)} end
    local st = l.storeId and s.stores[l.storeId]
    if st and st.open and st.policy and st.policy.autoSell then
      local m = npcStaff(st, 'vendedor')
      if m then return {kind = 'staff', staff = m, minimum = math.floor(l.price * clamp(st.policy.minPct or 90, 50, 100) / 100)} end
    end
  end
  local function declineVisit(s, v, message)
    cancelVisit(s, v, 'declined')
    return {kind = 'declined', message = message}
  end
  -- Deterministic haggling: below the floor the seller counters towards it, a
  -- fair offer gets a counter halfway to the asking price, a second fair offer
  -- (or one close to the asking price) closes the deal.
  local function autoRespond(s, v, l, o, ctx)
    local seller = autoSeller(s, l)
    if not seller then return nil end
    local npcBuyer = s.npcs[v.buyer]
    if npcBuyer then
      -- A salesperson and an NPC buyer settle between the floor and the budget.
      if seller.kind ~= 'staff' then return nil end
      if npcBuyer.budget < seller.minimum then
        return declineVisit(s, v, seller.staff.name .. ' não chegou a um acordo com ' .. npcBuyer.name .. '.')
      end
      local price = math.min(l.price, math.max(seller.minimum, math.floor((npcBuyer.budget + seller.minimum) / 2 / 1000) * 1000))
      local final = handlers.offer(s, l.seller, {visitId = v.id, price = price}, ctx, true)
      local r = closeSale(s, s.offers[final.id], v, l, ctx, 'sale', seller.staff)
      return {kind = 'accepted', receiptId = r.id, price = price, message = seller.staff.name .. ' vendeu para ' .. npcBuyer.name .. '.'}
    end
    local rounds = 0
    for _, x in pairs(s.offers) do if x.visitId == v.id and x.from == v.buyer then rounds = rounds + 1 end end
    local who = seller.kind == 'staff' and seller.staff.name or (s.accounts[l.seller] and s.accounts[l.seller].name) or 'Vendedor'
    if o.price >= l.price or (o.price >= seller.minimum and (rounds >= 2 or o.price >= math.floor(l.price * 0.97))) then
      o.by = seller.kind == 'staff' and ('staff:' .. seller.staff.id) or nil
      local r = closeSale(s, o, v, l, ctx, 'sale', seller.kind == 'staff' and seller.staff or nil)
      return {kind = 'accepted', receiptId = r.id, price = o.price, message = who .. ': Fechado! O carro é seu.'}
    end
    if rounds > 4 or o.price < math.floor(seller.minimum * 0.7) then
      return declineVisit(s, v, who .. ': Por esse valor não dá. Obrigado pela visita.')
    end
    local target = o.price >= seller.minimum and math.floor((o.price + l.price) / 2) or
      math.max(seller.minimum, math.floor(l.price - (l.price - seller.minimum) * math.min(1, 0.35 * rounds)))
    target = math.max(target, o.price + 10000)
    target = math.min(l.price, math.floor(target / 1000) * 1000)
    local counter = handlers.offer(s, l.seller, {visitId = v.id, price = target}, ctx, true)
    counter.by = seller.kind == 'staff' and ('staff:' .. seller.staff.id) or 'npc'
    return {kind = 'counter', price = target, offerId = counter.id, message = who .. ': Consigo fazer por ' .. money(target) .. '.'}
  end
  hooks.autoRespond = autoRespond

  -- Staff --------------------------------------------------------------------------
  function handlers.hire(s, id, p)
    local b, kind = business(s, p.businessId); check(b and b.owner == id, 'business_missing')
    local cand
    for _, c in ipairs(candidatesFor(b, kind)) do if c.id == p.candidateId then cand = c end end
    check(cand, 'candidate_missing')
    for _, m in pairs(b.staff) do check(m.candidateId ~= cand.id, 'already_hired') end
    local limit = C.STAFF_LIMIT[cand.role] or 1
    if cand.role == 'mecanico' then limit = math.min(limit, b.bays or C.SHOP_BAYS) end
    check(#staffWith(b, cand.role) < limit, 'staff_full')
    debit(s, id, cand.wage); s.treasury = s.treasury + cand.wage
    local sid = nextId(s, 'staff-')
    b.staff[sid] = {id = sid, kind = 'npc', role = cand.role, label = cand.label, name = cand.name, skill = cand.skill,
      wage = cand.wage, commission = cand.commission, candidateId = cand.id, hiredAt = now(), sales = 0, earned = 0}
    event(s, 'staff', b.name .. ' contratou ' .. cand.name .. ' como ' .. cand.label .. '.', {businessId = b.id})
    return copy(b.staff[sid])
  end
  function handlers.fire(s, id, p)
    local b = business(s, p.businessId); check(b and b.owner == id, 'business_missing')
    local m = b.staff[p.staffId]; check(m, 'staff_missing')
    b.staff[p.staffId] = nil
    if m.kind == 'player' then notify(s, m.account, 'Desligamento', 'Você foi desligado(a) de ' .. b.name .. '.', {businessId = b.id}) end
    return {fired = p.staffId}
  end
  function handlers.policy(s, id, p)
    local b, kind = business(s, p.businessId); check(b and b.owner == id, 'business_missing')
    local pol = b.policy
    if p.autoSell ~= nil then pol.autoSell = p.autoSell == true end
    if p.autoBuy ~= nil then pol.autoBuy = p.autoBuy == true end
    if p.autoQuote ~= nil then pol.autoQuote = p.autoQuote == true end
    if p.minPct ~= nil then check(integer(p.minPct, 50, 100), 'invalid_policy'); pol.minPct = p.minPct end
    if p.buyPct ~= nil then check(integer(p.buyPct, 30, 100), 'invalid_policy'); pol.buyPct = p.buyPct end
    if p.markupPct ~= nil then check(integer(p.markupPct, 0, 200), 'invalid_policy'); pol.markupPct = p.markupPct end
    return copy(pol)
  end
  -- Player jobs at other players' businesses.
  function handlers.postVacancy(s, id, p)
    local b, kind = business(s, p.businessId); check(b and b.owner == id, 'business_missing')
    local def = C.STAFF[kind][p.role]; check(def, 'invalid_role')
    check(integer(p.commission, 0, 50) and integer(p.wage or 0, 0, 5000000), 'invalid_price')
    check(optText(p.note, 280), 'invalid_text')
    for _, vac in pairs(s.vacancies) do
      check(not (vac.businessId == b.id and vac.role == p.role and vac.status == 'open'), 'vacancy_exists')
    end
    local vid = nextId(s, 'vaga-')
    s.vacancies[vid] = {id = vid, businessId = b.id, kind = kind, businessName = b.name, owner = id,
      ownerName = account(s, id).name, role = p.role, label = def.label, commission = p.commission, wage = p.wage or 0,
      note = p.note, status = 'open', createdAt = now(), position = copy(b.position), map = b.map}
    event(s, 'vaga', b.name .. ' está contratando: ' .. def.label .. ' (' .. p.commission .. '% de comissão).', {vacancyId = vid})
    return copy(s.vacancies[vid])
  end
  function handlers.closeVacancy(s, id, p)
    local vac = s.vacancies[p.vacancyId]; check(vac and vac.owner == id, 'vacancy_missing')
    vac.status = 'closed'
    return copy(vac)
  end
  function handlers.applyVacancy(s, id, p)
    local vac = s.vacancies[p.vacancyId]; check(vac and vac.status == 'open', 'vacancy_closed')
    check(vac.owner ~= id, 'own_business')
    local b = business(s, vac.businessId); check(b, 'business_missing')
    check(not playerRole(b, id), 'already_hired')
    local sid = nextId(s, 'staff-')
    b.staff[sid] = {id = sid, kind = 'player', account = id, name = account(s, id).name, role = vac.role, label = vac.label,
      commission = vac.commission, wage = vac.wage, hiredAt = now(), sales = 0, earned = 0}
    vac.status = 'filled'; vac.filledBy = id
    notify(s, vac.owner, 'Vaga preenchida', account(s, id).name .. ' agora trabalha em ' .. b.name .. ' como ' .. vac.label .. '.',
      {businessId = b.id})
    event(s, 'staff', account(s, id).name .. ' começou a trabalhar em ' .. b.name .. '.', {businessId = b.id})
    return copy(b.staff[sid])
  end
  function handlers.quitJob(s, id, p)
    local b = business(s, p.businessId); check(b, 'business_missing')
    local m = playerRole(b, id); check(m, 'staff_missing')
    b.staff[m.id] = nil
    notify(s, b.owner, 'Pedido de demissão', m.name .. ' saiu de ' .. b.name .. '.', {businessId = b.id})
    return {quit = b.id}
  end

  -- Map spots reported by clients, used to place NPC private sellers and transfer jobs anywhere on
  -- the map: roadside points (k = nil) and parking spots clear of the road (k = 'p': driveways, car
  -- parks). NPC sellers only ever park on 'p' spots; p.parking says how many the map has (0: none).
  function handlers.contributeSpots(s, id, p, ctx)
    local map = ctx.map or p.map
    check(text(map, 64) and type(p.spots) == 'table' and #p.spots <= 2 * C.SPOTS_MAX, 'invalid_spots')
    check(p.parking == nil or integer(p.parking, 0, 100000), 'invalid_spots')
    s.spots[map] = s.spots[map] or {}
    local list = s.spots[map]
    local added, parkingAdded = 0, 0
    for _, sp in ipairs(p.spots) do
      if position(sp) and (sp.h == nil or (type(sp.h) == 'number' and sp.h == sp.h)) then
        local kind = sp.k == 'p' and 'p' or nil
        local near = false
        for _, other in ipairs(list) do
          if other.k == kind and distance(other, sp) < C.SPOT_SPACING then near = true; break end
        end
        if not near then
          list[#list + 1] = {x = sp.x, y = sp.y, z = sp.z, h = sp.h or 0, k = kind}
          added = added + 1
          if kind then parkingAdded = parkingAdded + 1 end
        end
      end
    end
    -- At most SPOTS_MAX of each kind; the oldest go first.
    for _, kind in ipairs({'p', 'road'}) do
      local count = 0
      for _, sp in ipairs(list) do if (sp.k or 'road') == kind then count = count + 1 end end
      local i = 1
      while count > C.SPOTS_MAX and i <= #list do
        if (list[i].k or 'road') == kind then table.remove(list, i); count = count - 1 else i = i + 1 end
      end
    end
    if p.parking ~= nil then s.spotsMeta[map] = {parking = p.parking, at = now()} end
    if parkingAdded > 0 then retireNpcAds(s, map, function(l) return not l.parking end) end
    return {added = added, total = #list}
  end

  -- Photos of a display car, taken by the client that spawned it (or by the seller).
  function handlers.displayPhoto(s, id, p, ctx)
    local l = listing(s, p.listingId)
    check(l.status == 'active' and l.display, 'listing_unavailable')
    check(l.seller == id or (ctx and ctx.displayHost), 'not_owner')
    check(text(p.photoId, 128) and env.photoOwned(id, p.photoId), 'invalid_photo')
    l.photos = l.photos or {}
    for _, ph in ipairs(l.photos) do if ph == p.photoId then return publicListing(s, l) end end
    check(#l.photos < C.DISPLAY_PHOTOS, 'photos_full')
    l.photos[#l.photos + 1] = p.photoId
    l.revision = (l.revision or 1) + 1
    return publicListing(s, l)
  end

  -- NPC private sellers ------------------------------------------------------------
  local AD_TEXTS = {'Único dono, revisões em dia.', 'Pneus novos, aceito proposta.', 'Carro de garagem, documentação ok.',
    'Vendo por motivo de mudança.', 'Precisa de uns reparos, preço de ocasião.', 'Motor forte, nunca deixou na mão.',
    'Aceito troca em carro mais novo.', 'Ar gelando, bancos inteiros.', 'Sem detalhes, só rodar.'}
  function newNpcAccount(s, name)
    local nid = nextId(s, 'npc-')
    s.accounts[nid] = {id = nid, name = name, balance = 0, reputation = 0, sales = 0, earnings = 0, careerRevision = 0, npc = true}
    return nid
  end
  local function catalogCar(s, maxValue)
    local options = {}
    for _, car in ipairs(M.CARS) do if not maxValue or car.value * 100 <= maxValue then options[#options + 1] = car end end
    if #options == 0 then return nil end
    return pickFrom(s, options)
  end
  local function carData(s, car, condition, mileage)
    local value = math.floor(car.value * (0.4 + condition * 0.55))
    return {model = car.model, config = car.config, niceName = car.name, mileage = mileage, year = car.year,
      configBaseValue = value, value = value, wear = condition, condition = math.floor(condition * 100), tradeIn = true}
  end
  local function parkingSpots(s, map)
    local out = {}
    for _, sp in ipairs(s.spots[map] or {}) do if sp.k == 'p' then out[#out + 1] = sp end end
    return out
  end
  -- Driveways and car parks when the map has them (gig cars too), otherwise the roadside points.
  local function gigSpots(s, map, minimum)
    local parking = parkingSpots(s, map)
    if #parking >= minimum then return parking end
    return s.spots[map] or {}
  end
  -- NPC ads that should go (parked by the road before the map reported parking spots, or above the
  -- server's limit) leave at the next expiry check, unless a player has a visit booked.
  function retireNpcAds(s, map, which)
    for _, l in pairs(s.listings) do
      if l.npcSeller and l.status == 'active' and l.map == map and not l.reservation and which(l) then l.expiresAt = now() end
    end
  end
  local function freeAdSpot(s, map)
    local spots = parkingSpots(s, map)
    if #spots < 3 then return nil end
    local start = 1 + math.floor(rnd(s) * #spots)
    for k = 0, #spots - 1 do
      local sp = spots[(start + k - 1) % #spots + 1]
      local taken = false
      for _, l in pairs(s.listings) do
        if l.status == 'active' and l.display and distance(l.position, sp) < 12 then taken = true; break end
      end
      for _, st in pairs(s.stores) do if distance(st.position, sp) < 80 then taken = true end end
      for _, w in pairs(s.workshops) do if distance(w.position, sp) < 60 then taken = true end end
      if not taken then return sp end
    end
  end
  local function spawnNpcAd(s, map)
    local sp = freeAdSpot(s, map)
    local car = sp and catalogCar(s)
    if not car then return nil end
    local condition = between(s, 0.45, 0.97)
    local data = carData(s, car, condition, math.floor(between(s, 25000, 320000)) * 1000)
    local value = data.value * 100
    local asking = math.floor(value * between(s, 0.95, 1.18) / 10000) * 10000
    local nid = newNpcAccount(s, personName(s))
    local vin = nextId(s, 'RH-')
    s.assets[vin] = {id = vin, owner = nid, originAccount = nid, importedAt = now(), dataRef = putBlob(data), summary = summarize(data)}
    local lid = nextId(s, 'ad-')
    s.listings[lid] = {id = lid, assetId = vin, seller = nid, status = 'active', title = car.name,
      description = pickFrom(s, AD_TEXTS), price = math.max(C.MIN_PRICE, asking), photos = {}, position = pos(sp),
      heading = sp.h or 0, map = map, display = true, npcSeller = true, parking = true, minimum = math.floor(value * between(s, 0.7, 0.9)),
      createdAt = now(), expiresAt = now() + C.NPC_AD_TTL, views = 0, negotiable = true, revision = 1}
    s.assets[vin].listingId = lid
    return s.listings[lid]
  end

  -- Gigs ("bicos") -------------------------------------------------------------------
  local function spawnGig(s, map)
    local spots = gigSpots(s, map, 4)
    if #spots < 4 then return nil end
    for _ = 1, 10 do
      local a, b = pickFrom(s, spots), pickFrom(s, spots)
      local d = distance(a, b)
      if d >= 500 and d <= 5000 then
        local car = catalogCar(s)
        if not car then return nil end
        local pay = math.floor((15000 + d * 35 + car.value * 100 * 0.004) / 100) * 100
        local gid = nextId(s, 'bico-')
        local condition = between(s, 0.6, 0.98)
        s.gigs[gid] = {id = gid, kind = 'translado', title = 'Levar ' .. car.name, from = pos(a), fromH = a.h or 0,
          to = pos(b), distance = math.floor(d), map = map, client = personName(s),
          car = {model = car.model, config = car.config, name = car.name, value = car.value * 100, wear = condition},
          pay = pay, status = 'open', createdAt = now(), expiresAt = now() + C.GIG_TTL}
        return s.gigs[gid]
      end
    end
  end
  local function activeGig(s, id)
    for _, g in pairs(s.gigs) do if g.taker == id and g.status == 'taken' then return g end end
  end
  function handlers.gigTake(s, id, p)
    local g = s.gigs[p.gigId]; check(g and g.status == 'open' and g.expiresAt > now(), 'gig_unavailable')
    check(not g.reservedFor or g.reservedFor == id, 'gig_unavailable')
    check(g.client ~= id, 'own_gig')
    check(not activeGig(s, id), 'gig_in_progress')
    g.status = 'taken'; g.taker = id; g.takerName = account(s, id).name; g.takenAt = now()
    g.deadline = now() + 600 + math.floor((g.distance or 1000) / 6)
    return copy(g)
  end
  function handlers.gigAbandon(s, id, p)
    local g = s.gigs[p.gigId]; check(g and g.taker == id and g.status == 'taken', 'gig_missing')
    g.status = 'failed'; g.closedAt = now()
    local a = account(s, id); a.reputation = math.max(0, (a.reputation or 0) - 2)
    if g.kind == 'vistoria' and g.payer then
      g.status = 'open'; g.taker = nil; g.takerName = nil; g.deadline = nil
    end
    return copy(g)
  end
  local function payGig(s, g, id, amount, key)
    credit(s, id, amount)
    local a = account(s, id); a.earnings = (a.earnings or 0) + amount
    profession(s, id, key, amount)
    g.status = 'done'; g.closedAt = now(); g.paid = amount
  end
  function handlers.gigDeliver(s, id, p, ctx)
    local g = s.gigs[p.gigId]; check(g and g.taker == id and g.status == 'taken' and g.kind == 'translado', 'gig_missing')
    check(distance(ctx.vehiclePosition, g.to) <= C.GIG_RADIUS, 'not_at_destination')
    check(integer(p.damage or 0, 0, 500), 'invalid_damage')
    -- Nobody drives faster than ~160 km/h on average.
    check(now() - (g.takenAt or 0) >= math.floor((g.distance or 0) / 45), 'too_fast')
    local factor = 1 - math.min(0.6, (p.damage or 0) * 0.06)
    local late = g.deadline and now() > g.deadline
    if late then factor = factor * 0.7 end
    local amount = math.floor(g.pay * factor * (1 + 0.05 * level(s, id, 'translado')) / 100) * 100
    payGig(s, g, id, amount, 'translado')
    g.damage = p.damage or 0; g.late = late or nil
    firstStep(s, id, 'gig')
    if amount >= 100000 then event(s, 'bico', g.takerName .. ' entregou ' .. g.car.name .. ' e recebeu ' .. money(amount) .. '.') end
    return copy(g)
  end
  -- A first transfer job close to a new player (once per account), reserved for them.
  function handlers.starterGig(s, id, p, ctx)
    local a = account(s, id); a.firstSteps = a.firstSteps or {}
    check(not a.firstSteps.gig and not a.firstSteps.starterGig, 'starter_used')
    check(not activeGig(s, id), 'gig_in_progress')
    check(position(ctx.position) and text(ctx.map, 64), 'location_unavailable')
    local spots = gigSpots(s, ctx.map, 4)
    check(#spots >= 4, 'no_spots')
    local near = {}
    for _, sp in ipairs(spots) do
      local d = distance(sp, ctx.position)
      if d >= 60 and d <= C.STARTER_GIG_RADIUS then near[#near + 1] = sp end
    end
    if #near == 0 then -- nothing mapped close by yet: the closest spots there are
      local sorted = {}
      for i, sp in ipairs(spots) do sorted[i] = sp end
      table.sort(sorted, function(a, b) return distance(a, ctx.position) < distance(b, ctx.position) end)
      for i = 1, math.min(5, #sorted) do near[i] = sorted[i] end
    end
    for _ = 1, 20 do
      local from, to = pickFrom(s, near), pickFrom(s, spots)
      local d = distance(from, to)
      if d >= 500 and d <= 2500 then
        local car = catalogCar(s, 4000000) or catalogCar(s)
        check(car, 'no_spots')
        local gid = nextId(s, 'bico-')
        s.gigs[gid] = {id = gid, kind = 'translado', title = 'Primeiro bico: levar ' .. car.name, from = pos(from), fromH = from.h or 0,
          to = pos(to), distance = math.floor(d), map = ctx.map, client = personName(s), reservedFor = id, starter = true,
          car = {model = car.model, config = car.config, name = car.name, value = car.value * 100, wear = 0.9},
          pay = math.floor((15000 + d * 35) / 100) * 100, status = 'open', createdAt = now(), expiresAt = now() + 1800}
        a.firstSteps.starterGig = now()
        return copy(s.gigs[gid])
      end
    end
    check(false, 'no_spots')
  end
  -- Steps the client can only report itself (cheap ones).
  function handlers.firstStep(s, id, p)
    check(p.step == 'news', 'invalid_request')
    firstStep(s, id, p.step)
    return {steps = copy(account(s, id).firstSteps)}
  end

  -- Inspections: a seller pays an inspector to certify the car where it stands.
  function handlers.requestInspection(s, id, p)
    local l = own(s, p.listingId, id); check(l.status == 'active', 'listing_unavailable')
    check(not l.inspection, 'already_inspected')
    for _, g in pairs(s.gigs) do
      check(not (g.kind == 'vistoria' and g.listingId == l.id and (g.status == 'open' or g.status == 'taken')), 'gig_exists')
    end
    debit(s, id, C.INSPECTION_FEE)
    local gid = nextId(s, 'bico-')
    s.gigs[gid] = {id = gid, kind = 'vistoria', title = 'Vistoria: ' .. l.title, listingId = l.id, to = copy(l.position),
      map = l.map, client = id, clientName = account(s, id).name, payer = id, pay = C.INSPECTION_FEE, status = 'open',
      createdAt = now(), expiresAt = l.expiresAt}
    return copy(s.gigs[gid])
  end
  function handlers.inspect(s, id, p, ctx)
    local g = s.gigs[p.gigId]; check(g and g.kind == 'vistoria' and g.taker == id and g.status == 'taken', 'gig_missing')
    local l = s.listings[g.listingId]; check(l and l.status == 'active', 'listing_unavailable')
    check(distance(ctx.position, l.position) <= C.INSPECT_RADIUS, 'too_far')
    local a = s.assets[l.assetId] or {summary = {}}
    local sum = a.summary or {}
    local broken = sum.brokenParts or 0
    local verdict = broken == 0 and 'Aprovado' or (broken <= 3 and 'Aprovado com ressalvas' or 'Reprovado')
    l.inspection = {by = account(s, id).name, at = now(), mileage = sum.mileage, brokenParts = broken,
      condition = sum.condition, value = sum.value, verdict = verdict, notes = type(p.notes) == 'string' and p.notes:sub(1, 280) or nil}
    l.revision = l.revision + 1
    payGig(s, g, id, g.pay, 'vistoria')
    if l.seller ~= id then notify(s, l.seller, 'Vistoria concluída', l.title .. ': ' .. verdict .. '.', {listingId = l.id}) end
    return {gig = copy(g), inspection = copy(l.inspection)}
  end

  -- Messages ---------------------------------------------------------------------
  function handlers.message(s, id, p)
    check(text(p.to, 128) and s.accounts[p.to] and not s.accounts[p.to].npc and p.to ~= id, 'recipient_missing')
    check(text(p.body, 1000) and optText(p.subject, 120), 'invalid_text')
    local mid = nextId(s, 'msg-')
    s.messages[mid] = {id = mid, from = id, fromName = account(s, id).name, to = p.to, subject = p.subject or '',
      body = p.body, createdAt = now(), read = false, meta = type(p.meta) == 'table' and copy(p.meta) or nil}
    return copy(s.messages[mid])
  end
  function handlers.markRead(s, id, p)
    check(type(p.ids) == 'table' and #p.ids <= 200, 'invalid_request')
    for _, mid in ipairs(p.ids) do
      local m = s.messages[mid]
      if m and m.to == id then m.read = true end
    end
    return {ok = true}
  end

  -- Rent, payroll, the living economy and housekeeping --------------------------
  local function payroll(b)
    local total = 0
    for _, m in pairs(b.staff or {}) do total = total + (m.wage or 0) end
    return total
  end
  local function chargeRent(s, b, label)
    local t = now()
    if b.nextRentAt > t then return end
    local days = math.min(7, math.floor((t - b.nextRentAt) / 86400) + 1)
    local a = s.accounts[b.owner]
    if not a then return end
    local wages = payroll(b)
    local amount = (b.rent + wages) * days + (b.rentOverdue or 0)
    if a.balance >= amount then
      a.balance = a.balance - amount; b.rentOverdue = nil
      s.treasury = s.treasury + amount
      for _, m in pairs(b.staff or {}) do
        if m.kind == 'player' and (m.wage or 0) > 0 and s.accounts[m.account] then
          credit(s, m.account, m.wage * days); s.treasury = s.treasury - m.wage * days
          profession(s, m.account, m.role, m.wage * days)
        end
      end
    else
      b.open = false; b.rentOverdue = b.rent * days + (b.rentOverdue or 0)
      local left = 0
      for sid, m in pairs(b.staff or {}) do
        if m.kind == 'npc' then b.staff[sid] = nil; left = left + 1 end
      end
      notify(s, b.owner, label .. ' fechada', 'As despesas de ' .. b.name .. ' estão atrasadas. Pague para reabrir.' ..
        (left > 0 and (' ' .. left .. ' funcionário(s) pediram as contas.') or ''), {})
    end
    b.nextRentAt = t + 86400
  end

  local function simulate(s, ctx)
    for _, st in pairs(s.stores) do
      if st.open then
        local seller = npcStaff(st, 'vendedor')
        if seller and st.policy.autoSell then
          local ids = {}
          for lid, l in pairs(s.listings) do
            if l.storeId == st.id and l.status == 'active' and l.lot and not l.reservation then ids[#ids + 1] = lid end
          end
          table.sort(ids)
          for _, lid in ipairs(ids) do
            local l = s.listings[lid]
            local a = s.assets[l.assetId]
            local value = ((a and a.summary and a.summary.value) or 0) * 100
            -- Only cars priced near what they are worth sell on their own (no value, no automatic sale).
            local attract = value > 0 and l.price <= value * C.NPC_LOT_CAP and clamp(value / l.price, 0.4, 1.6) or 0
            local chance = C.NPC_SALE_CHANCE * attract * (1 + (st.reputation or 0) / 100) * (0.8 + 0.1 * (seller.skill or 1))
            if attract > 0 and rnd(s) < chance then
              local minimum = math.floor(l.price * clamp(st.policy.minPct or 90, 50, 100) / 100)
              local price = math.max(minimum, math.min(l.price, math.floor(between(s, minimum, l.price) / 1000) * 1000))
              if price >= C.MIN_PRICE then hooks.npcLotSale(s, st, l, price, seller) end
            end
          end
        end
        local buyer = npcStaff(st, 'comprador')
        local owner = s.accounts[st.owner]
        if buyer and owner and st.policy.autoBuy and hooks.lotFor(s, st) and rnd(s) < C.NPC_BUY_CHANCE then
          local pct = (st.policy.buyPct or 65) / 100
          local budget = math.min(st.tradeBudget or 5000000, owner.balance)
          local car = catalogCar(s, math.floor(budget / pct))
          if car then
            local data = carData(s, car, between(s, 0.55, 0.97), math.floor(between(s, 20000, 250000)) * 1000)
            local cost = math.floor(data.value * 100 * pct / 1000) * 1000
            if cost >= C.MIN_PRICE and owner.balance >= cost then
              local n = {id = 'oferta', name = personName(s), vehicle = {model = data.model, config = data.config,
                niceName = data.niceName, value = data.value * 100, mileage = data.mileage, wear = data.wear,
                condition = data.condition}}
              hooks.buyTradeIn(s, st, n, cost, true, nil, buyer.name)
              buyer.sales = (buyer.sales or 0) + 1
            end
          end
        end
      end
    end
    for _, w in pairs(s.workshops) do
      local mechanics = staffWith(w, 'mecanico')
      local m = npcStaff(w, 'mecanico')
      if w.open and m and w.policy.autoQuote then
        local free = math.max(0, (w.bays or 2) - busyBays(s, w))
        local done, net = 0, 0
        for i = 1, math.min(free, #mechanics) do
          local worker = mechanics[i]
          -- Expensive shops get fewer walk-in jobs; labor per job is capped.
          local pricing = clamp(12000 / (w.laborRate or 12000), 0.1, 1.5) * clamp(30 / math.max(1, w.policy.markupPct or 30), 0.2, 1.5)
          if worker.kind == 'npc' and rnd(s) < C.SHOP_JOB_CHANCE * pricing * (0.8 + 0.1 * (worker.skill or 1)) * (1 + (w.reputation or 0) / 200) then
            local partsCost = math.floor(between(s, 15000, 180000))
            local charged = math.floor(partsCost * (1 + math.min(w.policy.markupPct or 30, 60) / 100))
            local labor = math.floor(math.min(w.laborRate or 12000, 30000) * between(s, 1, 4))
            local commission = math.floor(labor * (worker.commission or 0) / 100)
            local profit = charged + labor - partsCost - commission
            credit(s, w.owner, profit)
            s.treasury = s.treasury + partsCost + commission
            w.jobs = (w.jobs or 0) + 1; w.revenue = (w.revenue or 0) + charged + labor
            w.partsSpent = (w.partsSpent or 0) + partsCost
            w.reputation = math.min(100, (w.reputation or 0) + 1)
            worker.earned = (worker.earned or 0) + commission; worker.sales = (worker.sales or 0) + 1
            done = done + 1; net = net + profit
          end
        end
        if done > 0 then
          notify(s, w.owner, 'Oficina trabalhando', w.name .. ': ' .. done .. ' serviço(s) feitos pela equipe (lucro ' ..
            money(net) .. ').', {workshopId = w.id})
        end
      end
    end
    -- "Vende-se" cars: a passer-by may buy one at or above the floor, if it is priced near its worth.
    local street = {}
    for lid, l in pairs(s.listings) do if l.street and l.status == 'active' and not l.reservation then street[#street + 1] = lid end end
    table.sort(street)
    for _, lid in ipairs(street) do
      local l = s.listings[lid]
      local a = s.assets[l.assetId]
      local value = ((a and a.summary and a.summary.value) or 0) * 100
      if value > 0 and l.price <= value * C.NPC_LOT_CAP and s.accounts[l.seller] then
        local attract = clamp(value / l.price, 0.4, 1.6)
        if rnd(s) < C.STREET_SALE_CHANCE * attract then
          local floor = l.minimum or math.floor(l.price * 0.9)
          local price = math.max(floor, math.min(l.price, math.floor(between(s, floor, l.price) / 1000) * 1000))
          if price >= C.MIN_PRICE then hooks.npcLotSale(s, nil, l, price, nil) end
        end
      end
    end
    local map = ctx and ctx.map
    if map and s.spots[map] then
      -- The server may lower the number of NPC private sellers (0 turns them off).
      local limit = ctx.npcAds and math.max(0, math.floor(ctx.npcAds)) or C.NPC_ADS
      local ads, gigs = 0, 0
      for _, l in pairs(s.listings) do if l.npcSeller and l.status == 'active' and l.map == map then ads = ads + 1 end end
      for _, g in pairs(s.gigs) do if g.kind == 'translado' and g.status == 'open' and g.map == map and not g.reservedFor then gigs = gigs + 1 end end
      if ads > limit then
        local extra = ads - limit
        retireNpcAds(s, map, function() extra = extra - 1; return extra >= 0 end)
      end
      for _ = ads + 1, limit do if not spawnNpcAd(s, map) then break end end
      for _ = gigs + 1, C.GIGS_OPEN do if not spawnGig(s, map) then break end end
    end
  end

  function handlers.tick(s, id, p, ctx)
    expire(s)
    for _, o in pairs(s.orders) do
      if o.status == 'in_progress' and o.finishesAt <= now() then completeOrder(s, o) end
    end
    -- Waiting NPC customers get a bay as soon as one frees up.
    for _, o in pairs(s.orders) do if o.status == 'accepted' and o.npc then hooks.autoStart(s, o, ctx) end end
    for _, st in pairs(s.stores) do chargeRent(s, st, 'Loja') end
    for _, w in pairs(s.workshops) do chargeRent(s, w, 'Oficina') end
    if now() - (s.simAt or 0) >= C.SIM_INTERVAL then
      s.simAt = now()
      simulate(s, ctx or {})
    end
    prune(s)
    return {tickedAt = now()}
  end
  function M.needsTick(s, t)
    if t - (s.simAt or 0) >= C.SIM_INTERVAL then return true end
    for _, g in pairs(s.gigs) do
      if g.status == 'open' and g.expiresAt <= t then return true end
      if g.status == 'taken' and g.deadline and g.deadline + 1800 <= t then return true end
    end
    for _, v in pairs(s.visits) do if (v.status == 'scheduled' or v.status == 'arrived') and v.expiresAt <= t then return true end end
    for _, o in pairs(s.offers) do if o.status == 'pending' and o.expiresAt <= t then return true end end
    for _, st in pairs(s.stores) do if st.nextRentAt <= t then return true end end
    for _, w in pairs(s.workshops) do if w.nextRentAt <= t then return true end end
    for _, l in pairs(s.listings) do if l.status == 'active' and l.expiresAt <= t then return true end end
    for _, o in pairs(s.orders) do
      if (o.status == 'requested' or o.status == 'quoted') and o.expiresAt <= t then return true end
      if o.status == 'in_progress' and o.finishesAt <= t then return true end
    end
    for _, n in pairs(s.npcs) do
      if (n.status == 'travelling' or n.status == 'negotiating' or n.status == 'waiting') and n.expiresAt <= t then return true end
    end
    return false
  end

  -- Answers that only read (and may carry a whole vehicle) skip the copy, the save and the request cache.
  local READ_ONLY = {delivery = true, displayData = true}
  -- Payloads can hold whole vehicles; a length + sampled hash is enough to notice a reused request id.
  local function fingerprintOf(request)
    local enc = env.encode({op = request.op, payload = request.payload or {}})
    if #enc <= 2048 then return enc end
    local h, step = 5381, math.max(1, math.floor(#enc / 4096))
    for i = 1, #enc, step do h = (h * 33 + enc:byte(i)) % 4294967296 end
    return request.op .. ':' .. #enc .. ':' .. string.format('%d', h)
  end
  function self:dispatch(id, request, ctx)
    if not text(id, 128) or type(request) ~= 'table' or not text(request.id, 96) or not text(request.op, 32) then
      return {ok = false, error = 'invalid_request'}
    end
    if READ_ONLY[request.op] then
      local ok, data = pcall(function()
        account(self.state, id)
        return handlers[request.op](self.state, id, request.payload or {}, ctx or {})
      end)
      return ok and {ok = true, id = request.id, data = data} or
        {ok = false, id = request.id, error = type(data) == 'table' and data.code or 'internal_error'}
    end
    local fingerprint = fingerprintOf(request)
    local key = id .. ':' .. request.id
    local cached = self.state.requests[key]
    if cached then
      if cached.fingerprint ~= fingerprint then return {ok = false, error = 'request_id_reused'} end
      return copy(cached.response)
    end
    if request.op == 'snapshot' then
      local ok, data = pcall(snapshot, self.state, id)
      return ok and {ok = true, id = request.id, data = data} or
        {ok = false, id = request.id, error = type(data) == 'table' and data.code or 'internal_error'}
    end
    local handler = handlers[request.op]
    if not handler then return {ok = false, id = request.id, error = 'unknown_operation'} end
    local working = copy(self.state)
    local ok, result = pcall(function()
      if request.op ~= 'hello' then account(working, id) end
      expire(working)
      return handler(working, id, request.payload or {}, ctx or {})
    end)
    if not ok then
      if type(result) ~= 'table' and env.log then env.log(tostring(result)) end
      return {ok = false, id = request.id, error = type(result) == 'table' and result.code or 'internal_error'}
    end
    working.revision = working.revision + 1
    local response = {ok = true, id = request.id, data = result, revision = working.revision}
    working.requests[key] = {fingerprint = fingerprint, response = copy(response), at = now()}
    -- The save must be durable BEFORE the new state is exposed or acknowledged.
    local saved, err = pcall(env.save, working)
    if not saved or err == false then return {ok = false, id = request.id, error = 'storage_unavailable'} end
    self.state = working
    return response
  end
  self.snapshot = function(_, id) return snapshot(self.state, id) end
  self.needsTick = function(_, t) return M.needsTick(self.state, t or now()) end
  self.handlers = handlers
  return self
end

return M
