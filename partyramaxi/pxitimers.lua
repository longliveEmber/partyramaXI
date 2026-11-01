--[[
* PartyramaXI - party effect timers that survive zoning, reloads and the next session.
*
* The countdowns of other party members' effects are only known from spells the addon saw land (pxifx.lua), and the
* count-up of effects with no known length starts when the addon first sees them (pxibuffs.lua). Both used to be lost
* on every zone change and reload. This keeps the entries of the people in your party:
*   - in memory across a zone change (pxifx is cleared there because monster ids mean nothing in the next zone),
*   - in data\timers_<character>.txt when the addon unloads (and once a minute while something is kept), read back on
*     the next load. Times are stored as wall-clock seconds, so time that passed while the game was closed counts.
* Your own effects need none of this: the game keeps their timers.
--]]
local M = {}

local function wall() return os.time() end

-- The server ids of the party members on the list (your own included; alliances have no effects here).
local function party_sids(Data)
    local ids = {}
    for i = 1, 6 do
        local r = Data.m and Data.m[i]
        if r and r.active and (r.sid or 0) ~= 0 then ids[r.sid] = true end
    end
    return ids
end

-- Effect entries and first-seen times of the party, as wall-clock records.
function M.snapshot(Fx, Buffs, Data, now)
    local w = wall()
    local out = { fx = {}, seen = {} }
    local ids = party_sids(Data)
    for sid in pairs(ids) do
        local list = Fx.fx[sid]
        if list then
            for st, e in pairs(list) do
                if e.gone == nil and (e.exp == 0 or e.exp > now) then
                    out.fx[#out.fx + 1] = { sid, st, e.spell or 0, e.actor or 0, w + (e.t0 - now), e.dur or 0, e.exp > 0 and (w + (e.exp - now)) or 0 }
                end
            end
        end
        local per = Buffs.seen_table and Buffs.seen_table()[sid]
        if per then
            for st, sn in pairs(per) do out.seen[#out.seen + 1] = { sid, st, w + (sn.t0 - now) } end
        end
    end
    return out
end

-- Puts a snapshot back (entries already present are kept: they are newer).
function M.restore(snap, Fx, Buffs, now)
    if type(snap) ~= 'table' then return 0 end
    local w = wall()
    local n = 0
    for _, r in ipairs(snap.fx or {}) do
        local sid, st, sp, ac, t0, dur, ex = r[1], r[2], r[3], r[4], r[5], r[6], r[7]
        local left = (ex ~= 0) and (ex - w) or nil
        if left == nil or left > 0 then
            local list = Fx.fx[sid]
            if list == nil then list = {}; Fx.fx[sid] = list end
            if list[st] == nil then
                list[st] = { status = st, spell = sp, actor = ac, t0 = now - (w - t0), dur = dur, exp = left and (now + left) or 0 }
                n = n + 1
            end
        end
    end
    if Buffs.seen_put then
        for _, r in ipairs(snap.seen or {}) do Buffs.seen_put(r[1], r[2], now - (w - r[3]), now) end
    end
    return n
end

-- File: one line per record. "F sid status spell actor t0 dur exp" / "S sid status t0" (integers, wall clock).
function M.write(path, snap)
    local f = io.open(path, 'w')
    if f == nil then return false end
    local lines = {}
    for _, r in ipairs(snap.fx) do
        lines[#lines + 1] = ('F %d %d %d %d %d %d %d'):format(r[1], r[2], r[3], r[4], math.floor(r[5]), math.floor((r[6] or 0) * 10), math.floor(r[7]))
    end
    for _, r in ipairs(snap.seen) do lines[#lines + 1] = ('S %d %d %d'):format(r[1], r[2], math.floor(r[3])) end
    f:write(table.concat(lines, '\n'), '\n')
    f:close()
    return true
end

function M.read(path)
    local f = io.open(path, 'r')
    if f == nil then return nil end
    local snap = { fx = {}, seen = {} }
    for line in f:lines() do
        local a, b, c, d, e, g, h = line:match('^F (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)')
        if a then
            snap.fx[#snap.fx + 1] = { tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e), tonumber(g) / 10, tonumber(h) }
        else
            local x, y, z = line:match('^S (%-?%d+) (%-?%d+) (%-?%d+)')
            if x then snap.seen[#snap.seen + 1] = { tonumber(x), tonumber(y), tonumber(z) } end
        end
    end
    f:close()
    return snap
end

-- data\timers_<name>.txt in the addon folder (name cleaned to letters and digits).
function M.path(base, name)
    local n = tostring(name or ''):gsub('[^%w]', '')
    if n == '' then return nil end
    return (base or ''):gsub('[\\/]+$', '') .. '\\data\\timers_' .. n .. '.txt'
end

return M
