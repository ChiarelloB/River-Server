-- RiverAdmin BeamMP server plugin. Original code.
-- Moderation for the River server: admins, kick, ban (BeamMP account + IP),
-- whitelist, announcements and rules. Chat commands start with "/"; the host
-- console takes the same commands after "admin " (e.g. "admin ban Fulano").
local ROOT = 'Resources/Server/RiverAdmin/'
local CONFIG = ROOT .. 'config.json'
local BANS = ROOT .. 'bans.json'

local DEFAULTS = {
  admins = {},
  whitelist = {enabled = false, names = {}, allowGuests = false},
  rules = {
    'Respeite os outros jogadores; nada de destruir carros de propósito.',
    'Negócios no RiverLife valem: combinou, cumpre.',
    'Use /ajuda para ver os comandos.',
  },
}

local cfg, bans = nil, {}
local known = {} -- pid -> {name, guest, beammp, ip}

local function log(msg) print('[RiverAdmin] ' .. msg) end
local function lower(s) return string.lower(tostring(s or '')) end
local function read(path)
  local f = io.open(path, 'rb'); if not f then return nil end
  local bytes = f:read('*a'); f:close()
  local ok, data = pcall(Util.JsonDecode, bytes)
  return ok and data or nil
end
local function write(path, data)
  local temp = path .. '.tmp'
  local f = assert(io.open(temp, 'wb')); assert(f:write(Util.JsonEncode(data))); assert(f:close())
  if FS.Exists(path) then FS.Remove(path) end
  assert(FS.Rename(temp, path))
end
local function saveConfig() write(CONFIG, cfg) end
local function saveBans() write(BANS, bans) end
local function list(t) return type(t) == 'table' and t or {} end
local function contains(t, value)
  for _, v in ipairs(list(t)) do if lower(v) == lower(value) then return true end end
  return false
end
local function removeFrom(t, value)
  for i = #t, 1, -1 do if lower(t[i]) == lower(value) then table.remove(t, i) end end
end

local function tell(pid, msg)
  if pid and pid >= 0 then MP.SendChatMessage(pid, msg) else log(msg) end
end

local function identify(pid)
  local p = known[pid] or {}
  p.name = MP.GetPlayerName(pid) or p.name
  p.guest = MP.IsPlayerGuest and MP.IsPlayerGuest(pid) or false
  local ids = MP.GetPlayerIdentifiers and MP.GetPlayerIdentifiers(pid) or {}
  p.beammp = ids.beammp or p.beammp
  p.ip = ids.ip or p.ip
  known[pid] = p
  return p
end

-- Guests get random names each session, so only BeamMP accounts can be admins.
local function isAdmin(pid)
  if pid == -1 then return true end
  local p = identify(pid)
  return not p.guest and contains(cfg.admins, p.name)
end

local function findPlayer(query)
  if not query then return nil, 'Informe o nome ou o número do jogador.' end
  local players = MP.GetPlayers() or {}
  local id = tonumber(query)
  if id and players[id] then return id end
  local q, hits = lower(query), {}
  for pid, name in pairs(players) do
    if lower(name) == q then return pid end
    if lower(name):sub(1, #q) == q then hits[#hits + 1] = pid end
  end
  if #hits == 1 then return hits[1] end
  if #hits > 1 then return nil, 'Mais de um jogador começa com "' .. query .. '"; digite mais letras.' end
  return nil, 'Jogador "' .. query .. '" não está online.'
end

local function banFor(name, guest, identifiers)
  identifiers = identifiers or {}
  for _, b in ipairs(bans) do
    if (b.beammp and identifiers.beammp and tostring(b.beammp) == tostring(identifiers.beammp))
      or (b.ip and identifiers.ip and b.ip == identifiers.ip)
      or (b.name and not guest and lower(b.name) == lower(name)) then
      return b
    end
  end
end

local function rest(args, from)
  local out = {}
  for i = from, #args do out[#out + 1] = args[i] end
  return table.concat(out, ' ')
end

-- Commands ------------------------------------------------------------------------
local COMMANDS, ADMIN_ONLY = {}, {}

function COMMANDS.ajuda(pid)
  tell(pid, 'Comandos: /regras, /jogadores, /admins' .. (isAdmin(pid) and
    ' | admin: /kick <nome> [motivo], /ban <nome> [motivo], /unban <nome|ip>, /bans, /aviso <texto>, ' ..
    '/whitelist on|off|add|remove|lista, /admin add|remove <nome>' or ''))
end

function COMMANDS.regras(pid)
  for i, r in ipairs(list(cfg.rules)) do tell(pid, i .. '. ' .. r) end
end

function COMMANDS.jogadores(pid)
  local names = {}
  for id, name in pairs(MP.GetPlayers() or {}) do names[#names + 1] = '[' .. id .. '] ' .. name end
  table.sort(names)
  tell(pid, #names .. ' online: ' .. table.concat(names, ', '))
end

function COMMANDS.admins(pid)
  tell(pid, 'Admins: ' .. (#list(cfg.admins) > 0 and table.concat(cfg.admins, ', ') or 'nenhum (defina no console: admin add <nome>)'))
end

ADMIN_ONLY.kick = true
function COMMANDS.kick(pid, args, by)
  local target, err = findPlayer(args[2])
  if not target then tell(pid, err); return end
  local reason = rest(args, 3)
  local name = MP.GetPlayerName(target)
  MP.DropPlayer(target, reason ~= '' and reason or 'Removido por um admin.')
  MP.SendChatMessage(-1, name .. ' foi removido por ' .. by .. (reason ~= '' and (': ' .. reason) or '.'))
  log(by .. ' kick ' .. name .. ' ' .. reason)
end

ADMIN_ONLY.ban = true
function COMMANDS.ban(pid, args, by)
  local target, err = findPlayer(args[2])
  if not target then tell(pid, err); return end
  if target == pid then tell(pid, 'Você não pode banir a si mesmo.'); return end
  local p = identify(target)
  local reason = rest(args, 3)
  bans[#bans + 1] = {name = not p.guest and p.name or nil, beammp = p.beammp, ip = p.ip,
    reason = reason ~= '' and reason or nil, by = by, at = os.time()}
  saveBans()
  MP.DropPlayer(target, 'Banido' .. (reason ~= '' and (': ' .. reason) or '.'))
  MP.SendChatMessage(-1, p.name .. ' foi banido por ' .. by .. '.')
  log(by .. ' ban ' .. tostring(p.name) .. ' ip=' .. tostring(p.ip) .. ' ' .. reason)
end

ADMIN_ONLY.unban = true
function COMMANDS.unban(pid, args, by)
  local q = args[2]
  if not q then tell(pid, 'Use /unban <nome|ip>.'); return end
  local removed = 0
  for i = #bans, 1, -1 do
    local b = bans[i]
    if lower(b.name) == lower(q) or b.ip == q or tostring(b.beammp) == q then table.remove(bans, i); removed = removed + 1 end
  end
  saveBans()
  tell(pid, removed > 0 and (q .. ' desbanido.') or ('Nenhum ban encontrado para ' .. q .. '.'))
  if removed > 0 then log(by .. ' unban ' .. q) end
end

ADMIN_ONLY.bans = true
function COMMANDS.bans(pid)
  if #bans == 0 then tell(pid, 'Nenhum jogador banido.'); return end
  for _, b in ipairs(bans) do
    tell(pid, (b.name or 'convidado') .. (b.ip and (' ip ' .. b.ip) or '') .. (b.reason and (' — ' .. b.reason) or '') ..
      ' (por ' .. tostring(b.by) .. ', ' .. os.date('%d/%m %H:%M', b.at or 0) .. ')')
  end
end

ADMIN_ONLY.aviso = true
function COMMANDS.aviso(pid, args, by)
  local text = rest(args, 2)
  if text == '' then tell(pid, 'Use /aviso <texto>.'); return end
  MP.SendChatMessage(-1, '[AVISO] ' .. text)
  log(by .. ' aviso: ' .. text)
end

ADMIN_ONLY.whitelist = true
function COMMANDS.whitelist(pid, args, by)
  local wl, sub, name = cfg.whitelist, lower(args[2]), args[3]
  if sub == 'on' or sub == 'off' then
    wl.enabled = sub == 'on'
    saveConfig()
    tell(pid, 'Whitelist ' .. (wl.enabled and 'ligada' or 'desligada') .. '.')
  elseif (sub == 'add' or sub == 'remove') and name then
    removeFrom(wl.names, name)
    if sub == 'add' then table.insert(wl.names, name) end
    saveConfig()
    tell(pid, name .. (sub == 'add' and ' entrou na' or ' saiu da') .. ' whitelist.')
  else
    tell(pid, 'Whitelist ' .. (wl.enabled and 'ligada' or 'desligada') .. ': ' ..
      (#wl.names > 0 and table.concat(wl.names, ', ') or 'vazia') .. '. Use /whitelist on|off|add <nome>|remove <nome>.')
    return
  end
  log(by .. ' whitelist ' .. sub .. ' ' .. tostring(name or ''))
end

ADMIN_ONLY.admin = true
function COMMANDS.admin(pid, args, by)
  local sub, name = lower(args[2]), args[3]
  if (sub ~= 'add' and sub ~= 'remove') or not name then tell(pid, 'Use /admin add <nome> ou /admin remove <nome>.'); return end
  removeFrom(cfg.admins, name)
  if sub == 'add' then table.insert(cfg.admins, name) end
  saveConfig()
  tell(pid, name .. (sub == 'add' and ' agora é admin.' or ' não é mais admin.'))
  log(by .. ' admin ' .. sub .. ' ' .. name)
end

local ALIASES = {help = 'ajuda', rules = 'regras', players = 'jogadores', say = 'aviso', unbanir = 'unban', banir = 'ban', expulsar = 'kick'}

local function run(pid, line, by)
  local args = {}
  for w in line:gmatch('%S+') do args[#args + 1] = w end
  local cmd = lower(args[1])
  cmd = ALIASES[cmd] or cmd
  args[1] = cmd
  local fn = COMMANDS[cmd]
  if not fn then return false end
  if ADMIN_ONLY[cmd] and not isAdmin(pid) then tell(pid, 'Só admins podem usar /' .. cmd .. '.'); return true end
  local ok, err = pcall(fn, pid, args, by)
  if not ok then tell(pid, 'Erro no comando: ' .. tostring(err)); log('erro em ' .. cmd .. ': ' .. tostring(err)) end
  return true
end

-- Events --------------------------------------------------------------------------
function RAAuth(name, role, isGuest, identifiers)
  local ban = banFor(name, isGuest, identifiers)
  if ban then return 'Você está banido deste servidor' .. (ban.reason and (': ' .. ban.reason) or '.') end
  local wl = cfg.whitelist
  if wl.enabled then
    if isGuest and not wl.allowGuests then return 'Servidor só para membros: entre com sua conta BeamMP.' end
    if not isGuest and not contains(wl.names, name) and not contains(cfg.admins, name) then
      return 'Servidor fechado (whitelist). Peça ao dono para liberar ' .. name .. '.'
    end
  end
end

function RAJoin(pid)
  identify(pid)
  if isAdmin(pid) then MP.SendChatMessage(pid, 'Você é admin aqui. /ajuda mostra os comandos.') end
end

function RALeave(pid) known[pid] = nil end

function RAChat(pid, name, message)
  if type(message) ~= 'string' or message:sub(1, 1) ~= '/' then return end
  if run(pid, message:sub(2), name) then return 1 end
end

function RAConsole(input)
  if type(input) ~= 'string' or input:sub(1, 6) ~= 'admin ' then return end
  local line = input:sub(7)
  local first = lower(line:match('^(%S+)'))
  -- "admin add <nome>" on the console is the bootstrap for the first admin.
  if first == 'add' or first == 'remove' then line = 'admin ' .. line end
  local out = {}
  local realTell = tell
  tell = function(_, msg) out[#out + 1] = msg end
  local handled = run(-1, line, 'console')
  tell = realTell
  if not handled then return 'Comandos: admin add|remove <nome> | admin kick|ban|unban|bans|aviso|whitelist ... | admin jogadores' end
  return table.concat(out, '\n')
end

function onInit()
  cfg = read(CONFIG) or {}
  for k, v in pairs(DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
  cfg.admins = list(cfg.admins)
  cfg.whitelist = type(cfg.whitelist) == 'table' and cfg.whitelist or DEFAULTS.whitelist
  cfg.whitelist.names = list(cfg.whitelist.names)
  bans = list(read(BANS))
  if not FS.Exists(CONFIG) then saveConfig() end
  MP.RegisterEvent('onPlayerAuth', 'RAAuth')
  MP.RegisterEvent('onPlayerJoin', 'RAJoin')
  MP.RegisterEvent('onPlayerDisconnect', 'RALeave')
  MP.RegisterEvent('onChatMessage', 'RAChat')
  MP.RegisterEvent('onConsoleInput', 'RAConsole')
  log('pronto; ' .. #cfg.admins .. ' admin(s), ' .. #bans .. ' ban(s), whitelist ' .. (cfg.whitelist.enabled and 'ligada' or 'desligada'))
end

MP.RegisterEvent('onInit', 'onInit')
