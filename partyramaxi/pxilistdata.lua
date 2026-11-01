--[[
* PartyramaXI - party list data: members, status effects, current actions.
*
*   members  Data.m[slot + 1], slot 0-17 (0-5 party, 6-11 alliance 1, 12-17 alliance 2). One record per
*            slot, reused every frame (nothing is allocated while reading).
*   buffs    you: the player's own status icons. Party members 2-6: packet 0x0076 (the game sends it for
*            your own party only, so alliance members have no effects here).
*   actions  packet 0x0028 for anyone in the party / alliance: spell start (with cast time), weapon skill /
*            ability / item / ranged start and finish, interrupts.
--]]
local M = {}

M.JOB = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG', 'SAM', 'NIN', 'DRG',
          'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN' }      -- job id 1 = WAR
M.ROLE_OF = {
    WAR = 'melee', MNK = 'melee', THF = 'melee', DRK = 'melee', SAM = 'melee', DRG = 'melee', BST = 'melee', DNC = 'melee',
    PLD = 'tank', RUN = 'tank', NIN = 'tank',
    WHM = 'healer', SCH = 'healer',
    BLM = 'caster', RDM = 'caster', BLU = 'caster', SMN = 'caster', GEO = 'caster',
    BRD = 'support', COR = 'support', PUP = 'support',
    RNG = 'ranged',
}
M.ROLE_COLOR = {
    melee = { 0.80, 0.30, 0.26 }, tank = { 0.28, 0.50, 0.86 }, healer = { 0.30, 0.74, 0.46 },
    caster = { 0.66, 0.40, 0.86 }, support = { 0.22, 0.72, 0.74 }, ranged = { 0.90, 0.62, 0.24 },
}

M.m = {}
for i = 1, 18 do
    M.m[i] = {
        slot = i - 1, active = false, name = '', last_name = '', sid = 0, here = true,
        hp = 0, hpp = 0, mp = 0, mpp = 0, tp = 0, mhp = 0, mmp = 0, hp_cache = 0, mp_cache = 0,
        job = 0, lv = 0, sub = 0, sublv = 0, jobtxt = '', zone = 0, zonetxt = '',
        nbuffs = 0, buffs = {},
        act_text = nil, act_kind = nil, act_frac = nil,
    }
end

M.ids = {}        -- server id -> true, for the members found by the last read
M.buffs = {}      -- server id -> { n = count, [1..n] = status ids }
-- Your own effects: status id -> { exp = clock time it ends (from the game's own timer) or nil, raw = that timer,
-- t0 = when it was first seen (for "last applied"), g = last read it was present in }.
M.self = {}
local SGEN = 0
M.act = {}        -- server id -> { text, kind, t0, dur, hold }
M.chat = {}       -- lower case name -> { text, t } (last chat line said by that member)
M.pflags = {}     -- server id -> flag bits from packet 0x00DD (party leader, alliance leader, quartermaster)
M.masks = { leader = 1, aleader = 2, qm = 16 }     -- which bits mean what (settings: list.roles.*_mask; /pxi list flags shows the raw bits)
M.leader_name, M.aleader_name, M.qm_name = nil, nil, nil     -- lower case names set by chat lines or /pxi list leader | qm
M.pets = {}       -- M.pets[slot + 1]: the pet of that member (see read_pets)
M.invite = { active = false, from = '', t0 = 0, resolved = 0, count0 = 0, test = false }
-- has_mp: the pet has a mana pool. The game reports 0% for pets without one (jug pets, wyverns...), so it is only set
-- once this pet (mp_idx) has shown more than 0%.
for i = 1, 18 do M.pets[i] = { slot = i - 1, active = false, owner = nil, name = '', hpp = 0, mpp = 0, tp = 0, has_mptp = false, has_mp = false, mp_idx = 0, idx = 0 } end

local api = nil
--[[ api = { party() -> IParty, player() -> IPlayer|nil, res() -> resource manager|nil, entity() -> IEntity } ]]
function M.init(a) api = a end

function M.reset()
    M.buffs, M.act, M.ids, M.chat, M.pflags = {}, {}, {}, {}, {}
    M.leader_name, M.aleader_name, M.qm_name = nil, nil, nil
    M.invite.active, M.invite.resolved = false, 0
end

-- Real members in your own party (for "show a sample when nobody is there").
function M.count_real()
    local p = api and api.party()
    local n = 0
    if p ~= nil then for s = 0, 5 do if p:GetMemberIsActive(s) == 1 then n = n + 1 end end end
    return n
end

---------------------------------------------------------------------------
-- Names from the game's resources (cached; every lookup is guarded)
---------------------------------------------------------------------------
local names = { spell = {}, ws = {}, ja = {}, item = {}, zone = {} }
local function first_name(o)
    if o == nil then return nil end
    local n = o.Name
    if n == nil then return nil end
    local ok, v = pcall(function () return n[1] end)
    if ok and type(v) == 'string' and v ~= '' then return v end
    return nil
end
local function lookup(kind, id, fetch, fallback)
    local c = names[kind]
    local v = c[id]
    if v ~= nil then return v end
    local ok, r = pcall(function ()
        local res = api and api.res()
        if res == nil then return nil end
        return first_name(fetch(res, id))
    end)
    v = (ok and r) or fallback
    c[id] = v
    return v
end
function M.spell_name(id) return lookup('spell', id, function (r, i) return r:GetSpellById(i) end, 'Spell') end
-- Magic skill of a spell (34 = enhancing, 35 = enfeebling, 37 = dark...), or false when unknown. Cached.
local skills, descs = {}, {}
function M.spell_skill(id)
    local v = skills[id]
    if v ~= nil then return v or nil end
    local ok, r = pcall(function ()
        local res = api and api.res()
        local sp = res and res:GetSpellById(id)
        return sp and tonumber(sp.Skill) or nil
    end)
    v = ok and r or false
    skills[id] = v
    return v or nil
end
-- The game's description of a status effect, or nil (not every Ashita build has the strings). Cached.
function M.buff_desc(id)
    local v = descs[id]
    if v ~= nil then return v or nil end
    local ok, r = pcall(function ()
        local res = api and api.res()
        return res and res:GetString('buffs.descriptions', id) or nil
    end)
    v = (ok and type(r) == 'string' and r ~= '') and r or false
    descs[id] = v
    return v or nil
end
function M.ws_name(id)    return lookup('ws', id, function (r, i) return r:GetAbilityById(i) end, 'Weapon Skill') end
function M.ja_name(id)    return lookup('ja', id, function (r, i) return r:GetAbilityById(i + 512) end, 'Ability') end
function M.item_name(id)  return lookup('item', id, function (r, i) return r:GetItemById(i) end, 'Item') end
function M.zone_name(id)
    local c = names.zone
    local v = c[id]
    if v ~= nil then return v end
    local ok, r = pcall(function ()
        local res = api and api.res()
        if res == nil then return nil end
        return res:GetString('zones.names', id)
    end)
    v = (ok and type(r) == 'string' and r ~= '') and r or ('Zone ' .. tostring(id))
    c[id] = v
    return v
end
local function cast_seconds(id)
    local ok, v = pcall(function ()
        local res = api and api.res()
        local sp = res and res:GetSpellById(id)
        return sp and tonumber(sp.CastTime)
    end)
    if ok and v and v > 0 and v <= 120 then return v / 4 end     -- the table counts quarter seconds
    return 3
end

---------------------------------------------------------------------------
-- Status effects (packet 0x0076)
---------------------------------------------------------------------------
-- e.data_raw as a byte pointer (0-based). Five 0x30 byte entries after a 4 byte header:
--   +0 server id (u32) +4 index (u16) +8 two-bit high parts of the 32 ids (8 bytes) +16 low bytes of the 32 ids.
function M.on_buffs(bytes, size)
    local count = math.min(5, math.floor(((tonumber(size) or 0xF4) - 4) / 0x30))
    for i = 0, count - 1 do
        local base = 4 + i * 0x30
        local sid = bytes[base] + bytes[base + 1] * 256 + bytes[base + 2] * 65536 + bytes[base + 3] * 16777216
        if sid ~= 0 then
            local t = M.buffs[sid]
            if t == nil then t = { n = 0 }; M.buffs[sid] = t end
            local n = 0
            for k = 0, 31 do
                local low = bytes[base + 16 + k]
                if low ~= 255 then
                    local hi = math.floor(bytes[base + 8 + math.floor(k / 4)] / 2 ^ ((k % 4) * 2)) % 4
                    n = n + 1
                    t[n] = low + 256 * hi
                end
            end
            for k = n + 1, t.n do t[k] = nil end
            t.n = n
        end
    end
end

---------------------------------------------------------------------------
-- Actions (packet 0x0028)
---------------------------------------------------------------------------
local START_OK, INTERRUPT = 24931, 28787
-- bits = ashita.bits.unpack_be, d = e.data_raw
function M.on_action(bits, d, now)
    local actor = bits(d, 0, 40, 32)
    if not M.ids[actor] then return end
    local cat, hdr = bits(d, 0, 82, 4), bits(d, 0, 86, 32)
    -- 2.7.0: for a start (spell 8, weapon skill 7, item 9) the upper 16 bits hold the spell group, so the 24931 / 28787
    -- start / interrupt code is only the lower 16 (a cast start was never matched, only its finish showed)
    if cat == 7 or cat == 8 or cat == 9 then hdr = bits(d, 0, 86, 16) end
    local count = bits(d, 0, 72, 6)
    local first = 0
    if count > 0 then first = bits(d, 0, 213, 17) end     -- first target, first action: param
    local text, kind, dur
    if cat == 8 then
        if hdr == START_OK then text, kind, dur = M.spell_name(first), 'cast', cast_seconds(first)
        elseif hdr == INTERRUPT then text, kind = 'Interrupted', 'fail' end
    elseif cat == 4 then text, kind = M.spell_name(hdr), 'done'
    elseif cat == 7 then
        if hdr == START_OK then text, kind, dur = M.ws_name(first), 'ws', 1.5
        elseif hdr == INTERRUPT then text, kind = 'Interrupted', 'fail' end
    elseif cat == 3 then text, kind = M.ws_name(hdr), 'done'
    elseif cat == 6 or cat == 14 then text, kind = M.ja_name(hdr), 'done'
    elseif cat == 9 then
        if hdr == START_OK then text, kind, dur = M.item_name(first), 'item', 2.5 end
    elseif cat == 5 then text, kind = M.item_name(hdr), 'done'
    elseif cat == 12 then text, kind, dur = 'Ranged', 'ranged', 2
    elseif cat == 2 then text, kind = 'Ranged', 'done' end
    if text == nil then return end
    M.act[actor] = { text = text, kind = kind, t0 = now, dur = dur or 0, hold = 0 }
end

local function action_state(r, now, hold)
    local a = M.act[r.sid]
    if a == nil then r.act_text, r.act_kind, r.act_frac = nil, nil, nil; return end
    local age = now - a.t0
    if a.dur > 0 and (a.kind == 'cast' or a.kind == 'ws' or a.kind == 'item' or a.kind == 'ranged') then
        if age < a.dur + 6 then      -- a start with no finish yet: keep it a little past its time, then drop it
            r.act_text, r.act_kind = a.text, a.kind
            r.act_frac = math.min(1, age / a.dur)
            return
        end
    elseif age < hold then
        r.act_text, r.act_kind, r.act_frac = a.text, a.kind, nil
        return
    end
    r.act_text, r.act_kind, r.act_frac = nil, nil, nil
    M.act[r.sid] = nil
end

---------------------------------------------------------------------------
-- Chat lines said by members: "(Name) text" party, "Name : text" say / shout, "<Name> text" linkshell, "Name>> text" tell.
---------------------------------------------------------------------------
function M.on_chat(msg, now, party_only)
    if type(msg) ~= 'string' or #msg > 400 then return end
    msg = msg:gsub('[\30\31].', ''):gsub('\127', ''):gsub('^%s+', '')
    local name, text = msg:match('^%((%a+)%) (.+)$')
    if name == nil and not party_only then
        name, text = msg:match('^(%a+) : (.+)$')
        if name == nil then name, text = msg:match('^<(%a+)> (.+)$') end
        if name == nil then name, text = msg:match('^(%a+)>> (.+)$') end
    end
    if name == nil then return end
    local key = name:lower()
    for i = 1, 18 do
        local r = M.m[i]
        if r.active and r.lname == key then
            M.chat[key] = { text = text:sub(1, 120), t = now }
            return
        end
    end
end

---------------------------------------------------------------------------
-- Leader / quartermaster: flag bits of packet 0x00DD (+0x04 id, +0x14 flags u16), and chat lines as a fallback
---------------------------------------------------------------------------
function M.on_member_update(bytes)
    local sid = bytes[4] + bytes[5] * 256 + bytes[6] * 65536 + bytes[7] * 16777216
    if sid ~= 0 then M.pflags[sid] = bytes[0x14] + bytes[0x15] * 256 end
end

function M.on_role_text(msg)
    if type(msg) ~= 'string' or #msg > 300 then return end
    local l = msg:lower()
    local kind
    if l:find('quartermaster', 1, true) then kind = 'qm_name'
    elseif l:find('alliance leader', 1, true) then kind = 'aleader_name'
    elseif l:find('party leader', 1, true) then kind = 'leader_name' end
    if kind == nil then return end
    local gone = l:find('no longer', 1, true) or l:find('relinquish', 1, true) or l:find('removed', 1, true)
    for i = 1, 18 do
        local r = M.m[i]
        if r.active and r.lname and r.lname ~= '' and l:find(r.lname, 1, true) then
            if gone then if M[kind] == r.lname then M[kind] = nil end else M[kind] = r.lname end
            return
        end
    end
end

-- "/pxi list leader <name>|clear" and "/pxi list qm <name>|clear": set by hand when neither flags nor chat lines work.
function M.set_role(kind, name)
    local key = (kind == 'qm') and 'qm_name' or ((kind == 'aleader') and 'aleader_name' or 'leader_name')
    if name == nil or name == '' or name == 'clear' then M[key] = nil else M[key] = name:lower() end
end

---------------------------------------------------------------------------
-- Pets and summons: the entity of each member's pet (name, health %). Your own pet also has mana % and TP.
---------------------------------------------------------------------------
function M.read_pets(scope, last_slot)
    local ent = api.entity and api.entity()
    local p = api.party()
    for slot = 0, 17 do
        local pr = M.pets[slot + 1]
        local r = M.m[slot + 1]
        pr.active = false
        if ent ~= nil and p ~= nil and slot <= last_slot and r.active and r.here
            and (scope == 'all' or (scope == 'party' and slot <= 5) or (scope == 'me' and slot == 0)) then
            local ok = pcall(function ()
                local oi = p:GetMemberTargetIndex(slot) or 0
                if oi == 0 then return end
                local pi = ent:GetPetTargetIndex(oi) or 0
                if pi == 0 then return end
                local nm = ent:GetName(pi)
                if type(nm) ~= 'string' or nm == '' then return end
                pr.active, pr.owner, pr.name, pr.idx = true, r, nm, pi
                pr.hpp = ent:GetHPPercent(pi) or 0
                pr.has_mptp = false
                if slot == 0 then
                    local pl = api.player and api.player()
                    if pl ~= nil then
                        local mp, tp = pl:GetPetMPPercent(), pl:GetPetTP()
                        if type(mp) == 'number' and type(tp) == 'number' then
                            pr.mpp, pr.tp, pr.has_mptp = mp, tp, true
                            if pr.mp_idx ~= pi then pr.mp_idx, pr.has_mp = pi, false end
                            if mp > 0 then pr.has_mp = true end
                        end
                    end
                end
            end)
            if not ok then pr.active = false end
        end
    end
end

---------------------------------------------------------------------------
-- Party invite: packet 0x00DC (+0x04 inviter id, +0x0C inviter name). Ends when you join (member count grows),
-- when a chat line says you joined / declined / it expired, or after the timeout.
---------------------------------------------------------------------------
function M.invite_start(name, now, count, is_test)
    local I = M.invite
    I.active, I.from, I.t0, I.resolved, I.count0, I.test = true, name or '', now, 0, count or 0, is_test == true
end
function M.invite_resolve(now)
    local I = M.invite
    if I.active and I.resolved == 0 then I.resolved = now end
end
function M.on_invite(bytes, now)
    local chars = {}
    for i = 0, 15 do
        local b = bytes[0x0C + i]
        if b == 0 then break end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then chars[#chars + 1] = string.char(b) else chars = {}; break end
    end
    M.invite_start(table.concat(chars), now, M.count_real(), false)
end
function M.on_invite_text(msg, now)
    if type(msg) ~= 'string' or not M.invite.active or M.invite.test then return end
    local l = msg:lower()
    if l:find('declin', 1, true) or l:find('joined the party', 1, true) or l:find('you join', 1, true)
        or l:find('expired', 1, true) or l:find('invitation', 1, true) and (l:find('cancel', 1, true) or l:find('withdr', 1, true)) then
        M.invite_resolve(now)
    end
end

---------------------------------------------------------------------------
-- Reading the members
---------------------------------------------------------------------------
-- Your own effects come with the game's end time, at the same index as the icon: 1/60 s ticks from a fixed base,
-- wrapping every 2^32 ticks (the encoding Windower's buff tools use: base 0x22222222 + 1009810800 s, Unix time).
-- Anything outside 0 s .. 24 h (Signet and similar run for hours) is treated as unknown, so a wrong guess shows no timer rather than a wrong one.
local TPERIOD, TBASE = 4294967296 / 60, 572662306 + 1009810800
function M.self_left(raw)
    raw = tonumber(raw)
    if raw == nil or raw == 0 or raw == 0x7FFFFFFF or raw == -1 then return nil end
    if raw < 0 then raw = raw + 4294967296 end
    local left = raw / 60 + TBASE - os.time()
    left = left - TPERIOD * math.floor(left / TPERIOD + 0.5)
    if left < 0 or left > 24 * 3600 then return nil end
    return left
end

local function set_job(r, main, mlv, sub, slv)
    if r.job == main and r.lv == mlv and r.sub == sub and r.sublv == slv then return end
    r.job, r.lv, r.sub, r.sublv = main, mlv, sub, slv
    local mj, sj = M.JOB[main] or '???', M.JOB[sub]
    r.main_abbr, r.sub_abbr = mj, sj
end

function M.read(slot, r, now, hold)
    local p = api.party()
    if p == nil or p:GetMemberIsActive(slot) ~= 1 then r.active = false; return false end
    local nm = p:GetMemberName(slot)
    if type(nm) ~= 'string' or nm == '' then nm = '?' end
    if nm ~= r.last_name then r.last_name, r.hp_cache, r.mp_cache = nm, 0, 0 end
    r.active, r.name = true, nm
    r.sid = p:GetMemberServerId(slot) or 0
    r.zone = p:GetMemberZone(slot) or 0
    r.here = r.zone == (p:GetMemberZone(0) or 0)
    r.hp, r.mp, r.tp = p:GetMemberHP(slot) or 0, p:GetMemberMP(slot) or 0, p:GetMemberTP(slot) or 0
    r.hpp, r.mpp = p:GetMemberHPPercent(slot) or 0, p:GetMemberMPPercent(slot) or 0
    local mj, ml, sj, sl = p:GetMemberMainJob(slot) or 0, p:GetMemberMainJobLevel(slot) or 0, p:GetMemberSubJob(slot) or 0, p:GetMemberSubJobLevel(slot) or 0
    if slot == 0 then       -- your own job is more reliable from the player object
        local pl = api.player and api.player()
        if pl ~= nil then
            local a, b, c, d = pl:GetMainJob(), pl:GetMainJobLevel(), pl:GetSubJob(), pl:GetSubJobLevel()
            if (a or 0) > 0 then mj, ml, sj, sl = a, b or ml, c or sj, d or sl end
        end
    end
    set_job(r, mj, ml, sj, sl)
    r.lname = nm:lower()
    r.demo_note = nil
    local ch = M.chat[r.lname]
    if ch ~= nil then r.chat_text, r.chat_t = ch.text, ch.t else r.chat_text, r.chat_t = nil, nil end

    -- maximums: yours are known; for others they are worked out from the percent (kept while it is a safe estimate)
    r.mhp, r.mmp = 0, 0
    if slot == 0 then
        local pl = api.player and api.player()
        if pl ~= nil then r.mhp, r.mmp = pl:GetHPMax() or 0, pl:GetMPMax() or 0 end
    else
        if r.hpp >= 30 then r.hp_cache = math.floor(r.hp * 100 / r.hpp + 0.5) end
        if r.mpp >= 30 then r.mp_cache = math.floor(r.mp * 100 / r.mpp + 0.5) end
        r.mhp, r.mmp = r.hp_cache, r.mp_cache
    end
    if r.mhp < r.hp then r.mhp = r.hp end
    if r.mmp < r.mp then r.mmp = r.mp end

    -- status effects
    local n = 0
    if slot == 0 then
        local pl = api.player and api.player()
        local icons = pl ~= nil and pl:GetStatusIcons() or nil
        local okt, timers = false, nil
        if pl ~= nil and pl.GetStatusTimers ~= nil then okt, timers = pcall(pl.GetStatusTimers, pl) end
        if not okt or type(timers) ~= 'table' and type(timers) ~= 'userdata' then timers = nil end
        local S = M.self
        SGEN = SGEN + 1
        if icons ~= nil then
            for k = 0, 32 do                       -- 0 or 1 based depending on the build; nil entries are skipped
                local id = tonumber(icons[k])
                if id ~= nil and id ~= 255 and id ~= 0xFFFF and id > 0 and n < 32 then
                    n = n + 1; r.buffs[n] = id
                    local e = S[id]
                    if e == nil then e = { t0 = now }; S[id] = e end      -- one small table per new effect only
                    e.g = SGEN
                    local raw = timers and tonumber(timers[k]) or nil
                    if raw ~= e.raw then                 -- the end time is recomputed only when the game's timer changes
                        e.raw = raw
                        local left = raw and M.self_left(raw) or nil
                        e.exp = left and (now + left) or nil
                    end
                end
            end
        end
        for id, e in pairs(S) do if e.g ~= SGEN then S[id] = nil end end
    else
        local t = M.buffs[r.sid]
        if t ~= nil then for k = 1, t.n do n = n + 1; r.buffs[n] = t[k] end end
    end
    for k = n + 1, r.nbuffs do r.buffs[k] = nil end
    r.nbuffs = n

    local fl = M.pflags[r.sid] or 0
    local mk = M.masks
    r.leader = (mk.leader ~= 0 and bit.band(fl, mk.leader) ~= 0) or (M.leader_name ~= nil and M.leader_name == r.lname)
    r.aleader = (mk.aleader ~= 0 and bit.band(fl, mk.aleader) ~= 0) or (M.aleader_name ~= nil and M.aleader_name == r.lname)
    r.qm = (mk.qm ~= 0 and bit.band(fl, mk.qm) ~= 0) or (M.qm_name ~= nil and M.qm_name == r.lname)
    r.flags = fl

    action_state(r, now, hold)
    return true
end

-- Reads every slot. Returns how many are active. Also refreshes the set of party server ids.
function M.read_all(now, hold, last_slot)
    local n = 0
    for k in pairs(M.ids) do M.ids[k] = nil end
    for slot = 0, 17 do
        local r = M.m[slot + 1]
        if slot <= last_slot then
            local ok, active = pcall(M.read, slot, r, now, hold)
            if ok and active then n = n + 1; if r.sid ~= 0 then M.ids[r.sid] = true end else r.active = false end
        else
            r.active = false
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Sample party for the Test button and /pxi test: nine members across party, alliance 1 and 2, animated.
---------------------------------------------------------------------------
local SAMPLE = {
    { 0,  'Altair',  9,  75, 13, 37, 'melee' },
    { 1,  'Vesper',  3,  75, 20, 37, 'heal' },
    { 2,  'Kaelith', 15, 75, 4,  37, 'cast' },
    { 3,  'Rook',    12, 75, 6,  37, 'ws' },
    { 4,  'Tamsin',  10, 75, 3,  37, 'sing' },
    { 5,  'Brannoch', 11, 75, 6, 37, 'idle' },
    { 6,  'Ione',    5,  75, 3,  37, 'idle' },
    { 7,  'Garrick', 1,  75, 7,  37, 'idle' },
    { 8,  'Selene',  3,  75, 20, 37, 'idle' },
    { 12, 'Dov',     14, 75, 12, 37, 'idle' },
    { 13, 'Nyx',     6,  75, 13, 37, 'idle' },
}
-- { name, health, has MP/TP data (own pet only), has a mana pool }
local SAMPLE_PETS = { [0] = { 'Funguar Familiar', 0.82, true, false }, [2] = { 'Garuda', 0.64 }, [12] = { 'Wyvern', 0.9 } }
local SAMPLE_BUFFS = { 33, 40, 41, 42, 43, 68, 94, 66, 37, 116, 125, 91 }

local function wave(now, phase, speed) return 0.5 + 0.5 * math.sin(now * speed + phase) end

-- Which sample members are "in the party" at this moment in the join / leave test (a 22 second loop).
local function cycle_present(now, k)
    local t = now % 22
    return t >= 0.6 + (k - 1) * 0.9 and t < 13 + (k - 1) * 0.55
end

function M.sample(now, last_slot, cycle)
    local n = 0
    for i = 1, 18 do M.m[i].active = false; M.pets[i].active = false end
    for k, s in ipairs(SAMPLE) do
        local slot = s[1]
        if slot <= last_slot and (not cycle or cycle_present(now, k)) then
            local r = M.m[slot + 1]
            n = n + 1
            r.active, r.name, r.sid = true, s[2], 9000 + slot
            r.here = k ~= 6
            r.zone = r.here and 230 or 231
            local pct = math.floor(35 + 65 * wave(now, k * 1.7, 0.35))
            if k == 8 then pct = 100 end
            r.hpp = pct; r.mhp = 1500 + k * 90; r.hp = math.floor(r.mhp * pct / 100)
            r.mpp = math.floor(20 + 80 * wave(now, k * 0.9, 0.22)); r.mmp = 800 + k * 40; r.mp = math.floor(r.mmp * r.mpp / 100)
            r.tp = math.floor(((now * 260 + k * 530) % 3300))
            if r.tp > 3000 then r.tp = 3000 end
            if k == 3 then r.hpp, r.hp = 0, 0 end
            set_job(r, s[3], s[4], s[5], s[6])
            r.lname = s[2]:lower()
            r.demo_note = ({ Altair = 'Tank', Vesper = 'Heals', Tamsin = 'Songs' })[s[2]]
            if k == 2 and (now % 12) < 6 then r.chat_text, r.chat_t = 'Cure incoming!', now - (now % 12) else r.chat_text, r.chat_t = nil, nil end
            r.leader = (slot == 0 or slot == 6 or slot == 12)
            r.aleader = (slot == 0)
            r.qm = (slot == 1)
            local sp = SAMPLE_PETS[slot]
            local pr = M.pets[slot + 1]
            if sp ~= nil then
                pr.active, pr.owner, pr.name = true, r, sp[1]
                pr.hpp = math.floor(100 * math.max(0.25, sp[2] * (0.7 + 0.3 * wave(now, k, 0.5))))
                pr.has_mptp = sp[3] == true
                pr.has_mp = sp[4] == true
                pr.mpp, pr.tp = math.floor(30 + 70 * wave(now, 2 + k, 0.4)), math.floor((now * 300) % 3100)
            end
            -- buffs: a few for the party, none for alliance (the game does not send those)
            local nb = slot <= 5 and (3 + (k * 2) % 9) or 0
            for b = 1, nb do r.buffs[b] = SAMPLE_BUFFS[(b + k) % #SAMPLE_BUFFS + 1] end
            for b = nb + 1, r.nbuffs do r.buffs[b] = nil end
            r.nbuffs = nb
            -- sample countdowns for the Test button (the real ones come from spells the addon sees land)
            local okfx, FXm = pcall(require, 'pxifx')
            if okfx and FXm and FXm.fx then
                local lst = FXm.fx[r.sid]
                if lst == nil then lst = {}; FXm.fx[r.sid] = lst end
                for b = 1, nb do
                    local id = r.buffs[b]
                    if b % 3 ~= 0 then
                        local dur = 20 + ((b * 37 + k * 11) % 140)
                        lst[id] = { status = id, spell = 0, actor = 0, t0 = now, dur = dur, exp = now + dur - ((now + b * 5 + k * 3) % dur) }
                    elseif lst[id] then lst[id] = nil end
                end
            end
            -- actions: a repeating 6 second cycle for the members that "act"
            local ph = (now + k * 1.3) % 6
            r.act_text, r.act_kind, r.act_frac = nil, nil, nil
            if s[7] == 'heal' then
                if ph < 3 then r.act_text, r.act_kind, r.act_frac = 'Cure IV', 'cast', ph / 3
                elseif ph < 4.5 then r.act_text, r.act_kind = 'Cure IV', 'done' end
            elseif s[7] == 'cast' then
                if ph < 4 then r.act_text, r.act_kind, r.act_frac = 'Thunder III', 'cast', ph / 4
                elseif ph < 5 then r.act_text, r.act_kind = 'Interrupted', 'fail' end
            elseif s[7] == 'ws' then
                if ph < 1.5 then r.act_text, r.act_kind, r.act_frac = 'Savage Blade', 'ws', ph / 1.5
                elseif ph < 3 then r.act_text, r.act_kind = 'Savage Blade', 'done' end
            elseif s[7] == 'sing' then
                if ph < 2.5 then r.act_text, r.act_kind, r.act_frac = 'Valor Minuet', 'cast', ph / 2.5 end
            elseif s[7] == 'melee' then
                if ph > 4 then r.act_text, r.act_kind = 'Provoke', 'done' end
            end
        end
    end
    return n
end

return M
