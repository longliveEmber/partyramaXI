--[[
* PartyramaXI - action buffer (2.5.0).
*
* A spell or job ability used a moment too early (its recast still has up to 'window' seconds left) is not sent to
* the game, which would only answer "unable to cast". It is held instead and sent again the moment the recast is
* ready, on the same target. 2.5.1: the game hands commands over with the target already turned into a number
* (/ma "Cure" 1683 = entity index 1683), and that text can't be typed back, so the held action is sent as the
* game's own action packet (0x1A) on the target it was meant for. Without a known target it is re-sent as text.
* Cursor targets (<st>, <stpc>, ...) are never held. One action is held at a time; a newer one replaces it, and
* any other spell or ability you use in the meantime drops it.
--]]
local M = {}

local SPELL_CMDS = { ['/ma'] = true, ['/magic'] = true, ['/nin'] = true, ['/ninjutsu'] = true, ['/song'] = true, ['/sing'] = true, ['/so'] = true }
local ABIL_CMDS  = { ['/ja'] = true, ['/jobability'] = true, ['/pet'] = true }
local MAX_HOLD   = 3.0      -- a held action older than this is dropped (with a chat line saying why)
local MARGIN     = 0.05     -- sent this long after the recast should be ready

M.held = nil                -- { cmd, name, kind, id, fire, at, tok, sid, idx, pc, pname }
M.passing = nil             -- the command we are re-sending ourselves (let through once)

-- '/ma "Cure IV" <t>' -> '/ma', 'Cure IV', '<t>'
function M.parse(cmd)
    local c, rest = cmd:match('^%s*(/%S+)%s*(.*)$')
    if c == nil then return nil end
    c = c:lower()
    local name, tgt
    if rest:sub(1, 1) == '"' then name, tgt = rest:match('^"([^"]+)"%s*(.*)$')
    else name, tgt = rest:match('^(%S+)%s*(.*)$') end
    if name == nil then return nil end
    return c, name, (tgt or ''):gsub('%s+$', '')
end

local function recast_left(api, kind, name, units)
    local res = api.res()
    local rc = api.recast()
    if res == nil or rc == nil then return nil end
    if kind == 'spell' then
        local sp = res:GetSpellByName(name, 0)
        local id = sp and (sp.Index or sp.Id)
        if id == nil then return nil end
        return (rc:GetSpellTimer(id) or 0) / (units.spell or 60), id
    end
    local ab = res:GetAbilityByName(name, 0)
    local tid = ab and ab.RecastTimerId
    if tid == nil then return nil end
    for x = 0, 31 do
        if (rc:GetAbilityTimerId(x) or -1) == tid then
            local t = rc:GetAbilityTimer(x) or 0
            if t > 0 then return t / (units.ability or 60), tid, ab.Id end
        end
    end
    return 0, tid, ab.Id
end

-- The entity index a target token stands for: <t>, nothing, a number (index, or a server id), <me>, <p0>-<p5>.
local function target_of(api, tok)
    local n = tonumber(tok)
    if n ~= nil then
        -- 2.5.3: <stpc> / <st> picks reach us as a number. Match it against the party first (target index or
        -- server id), then the entity list, then whoever the game's cursor or your target is on right now.
        if api.party_index ~= nil then
            for k = 0, 17 do
                local i = api.party_index(k)
                if i ~= nil and i ~= 0 and (i == n or (api.party_sid ~= nil and api.party_sid(k) == n)) then return i, 'party ' .. k end
            end
        end
        local e = api.entity()
        if e ~= nil and n > 0 and n < 0x900 and (e:GetServerId(n) or 0) ~= 0 then return n, 'entity' end
        local i = api.index_of_sid and api.index_of_sid(n) or nil
        if i ~= nil then return i, 'server id' end
        i = api.cursor and api.cursor() or nil
        if i ~= nil and i ~= 0 then return i, 'cursor' end
        return nil
    end
    if tok == '<t>' or tok == '' then local i = api.target() or 0; return i ~= 0 and i or nil, 'target' end
    if tok == '<me>' then return api.party_index and api.party_index(0) or nil, 'me' end
    local p = tok:match('^<p(%d)>$')
    if p ~= nil then return api.party_index and api.party_index(tonumber(p)) or nil, 'party' end
    return nil
end
M.target_of = target_of

-- Action packet 0x1A: target server id, target index, category (3 = magic, 9 = job ability), param (spell id /
-- ability id), then x, y, z = 0. 28 bytes, header included (size byte 0x0E).
local function action_packet(sid, idx, cat, param)
    local b = { 0x1A, 0x0E, 0, 0 }
    for k = 0, 3 do b[#b + 1] = math.floor(sid / 256 ^ k) % 256 end
    b[#b + 1] = idx % 256; b[#b + 1] = math.floor(idx / 256) % 256
    b[#b + 1] = cat; b[#b + 1] = 0
    b[#b + 1] = param % 256; b[#b + 1] = math.floor(param / 256) % 256
    for _ = 1, 14 do b[#b + 1] = 0 end
    return b
end
M.action_packet = action_packet

--[[
* Called from the command event for every command. Returns true when the command was held (block it).
* api: res(), recast(), target() -> main target index, entity(), units = { spell, ability }, now, msg(text)
--]]
function M.command(cfg, api, cmd)
    if M.passing ~= nil and api.now - (M.passing_at or 0) > 1 then M.passing = nil end   -- our resend never came back
    if M.passing ~= nil and M.passing == cmd then M.passing = nil; return false end
    local c, name, tgt = M.parse(cmd)
    if c == nil then return false end
    local kind = SPELL_CMDS[c] and 'spell' or (ABIL_CMDS[c] and 'ability') or nil
    if kind == nil then return false end
    if not cfg.enabled or tgt:find('<st', 1, true) then M.held = nil; return false end
    local ok, left, id, aid = pcall(recast_left, api, kind, name, api.units)
    if not ok or left == nil or left <= 0 or left > (cfg.window or 0.5) then M.held = nil; return false end
    local h = { cmd = cmd, name = name, kind = kind, id = id, fire = api.now + left + MARGIN, at = api.now, tok = tgt:lower() }
    if kind == 'spell' then h.cat, h.param = 3, id
    elseif type(aid) == 'number' and c ~= '/pet' then h.cat, h.param = 9, (aid >= 0x200) and (aid - 0x200) or aid end
    local okt, idx, how = pcall(target_of, api, h.tok)
    local e = api.entity()
    if okt and idx ~= nil and e ~= nil then
        h.idx, h.sid = idx, e:GetServerId(idx)
        if (h.sid or 0) == 0 then h.sid = api.party_sid_of and api.party_sid_of(idx) or nil end
        if (h.sid or 0) == 0 then h.sid = nil end
    end
    M.held = h
    if cfg.messages then
        local me = api.party_index and api.party_index(0) or 0
        api.msg(('Held %s: ready in %.2f s (target %s: %s; you are %s, id %s).'):format(name, left, tostring(h.tok),
            okt and idx and (tostring(idx) .. ' via ' .. tostring(how)) or (okt and 'not found' or ('error ' .. tostring(idx))),
            tostring(me), tostring(api.party_sid and api.party_sid(0) or '?')))
    end
    return true
end

-- Every frame (or probe): sends the held action once its recast is ready.
function M.tick(cfg, api)
    local h = M.held
    if h == nil then return end
    local now = api.now
    if not cfg.enabled then M.held = nil; return end
    if now - h.at > MAX_HOLD + (tonumber(cfg.delay) or 0) then
        M.held = nil
        local okl, l = pcall(recast_left, api, h.kind, h.name, api.units)
        api.msg(('%s was dropped: its recast still read %s after %.0f s.'):format(h.name, okl and tostring(l) or ('error ' .. tostring(l)), MAX_HOLD))
        return
    end
    if now < h.fire then return end
    local ok, left = pcall(recast_left, api, h.kind, h.name, api.units)
    if ok and left ~= nil and left > 0 then h.fire = now + math.min(left, 0.1); return end
    -- 2.5.4: the recast reads 0 a moment before the game accepts the action; wait 'delay' more seconds
    if h.ready_at == nil then h.ready_at = now end
    if now < h.ready_at + (tonumber(cfg.delay) or 0) then return end
    M.held = nil
    -- 2.5.2: as text when the target can be written as a token (the client then handles it as if you had typed it):
    -- the current target -> <t>, you -> <me>, a party member -> <pN>. Anything else goes as the action packet.
    local tok = nil
    if h.idx ~= nil then
        if api.party_index ~= nil then
            for k = 0, 5 do if api.party_index(k) == h.idx then tok = (k == 0) and '<me>' or ('<p' .. k .. '>'); break end end
        end
        if tok == nil and h.idx == (api.target() or 0) then tok = '<t>' end
    end
    if tok == nil and h.idx == nil and tonumber(h.tok) ~= nil then
        -- 2.5.3: a picked target we could not identify is not sent back as a number (the game ignores that)
        api.msg(('%s was not used: could not tell who target %s is (send the "Held" chat line to the addon author).'):format(h.name, h.tok))
        return
    end
    if tok ~= nil then
        local c = M.parse(h.cmd)
        local cmd = ('%s "%s" %s'):format(c, h.name, tok)
        M.passing, M.passing_at = cmd, now
        api.send(cmd)
        if cfg.messages then api.msg(('Used %s: sent %s'):format(h.name, cmd)) end
        return
    end
    if h.sid ~= nil and h.cat ~= nil and api.packet ~= nil then
        api.packet(action_packet(h.sid, h.idx, h.cat, h.param))
        if cfg.messages then api.msg(('Used %s on target %d (action packet).'):format(h.name, h.idx)) end
        return
    end
    local cmd = h.cmd
    M.passing, M.passing_at = cmd, now
    api.send(cmd)
    if cfg.messages then api.msg(('Used %s: sent %s (no target found)'):format(h.name, cmd)) end
end

return M
