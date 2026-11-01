--[[
* RecastXI - rxmp.lua
* "Not enough MP" check for spell rows.
*
* A spell row shows 'Not enough MP' instead of its timer / Ready while your current MP is below what
* the spell would cost you right now. The cost is the spell's own MP cost (from the game's spell
* resource) with the effects that change it applied, in this order:
*
*   Manafont / Manawell     the cost is 0 (the spell is castable at any MP)
*   Light Arts              white magic -10% (the reduction rounds down, so costs of 9 or less stay)
*                           black magic +20% (rounded up)
*   Dark Arts               black magic -10%, white magic +20%, same rounding
*   Penury                  white magic x 0.5 (rounded down)
*   Parsimony               black magic x 0.5 (rounded down)
*
* Not counted: Conserve MP and similar procs (the full cost is needed to start the cast; the saving
* only happens after it), and effects only some servers change. The percentages are the retail ones
* (BG-Wiki); the status ids are the standard FFXI buff ids.
*
* Pure functions (cost / group) have no Ashita calls so they can be tested offline.
--]]

local M = {};
local floor = math.floor;

M.EFFECT = { MANAFONT = 47, MANAWELL = 229, LIGHT_ARTS = 358, DARK_ARTS = 359, PENURY = 360, PARSIMONY = 361 };
M.REFRESH_EVERY = 0.2;     -- seconds between buffer reads (MP and buffs)

-- Spell group from the resource: Type 1 = White Magic, 2 = Black Magic; the skill is only a fallback
-- when the build has no Type field (divine / healing = white, elemental / dark = black).
function M.group(stype, skill)
    if (stype == 1) then return 'white'; end
    if (stype == 2) then return 'black'; end
    if (stype == nil) then
        if (skill == 32 or skill == 33) then return 'white'; end
        if (skill == 36 or skill == 37) then return 'black'; end
    end
    return nil;
end

local function down10(c) return c - floor(c / 10); end             -- -10%, reduction rounded down
local function up20(c) return c + floor((c * 2 + 9) / 10); end     -- +20%, increase rounded up
local function half(c) return floor(c / 2); end

-- fx: { manafont, manawell, light, dark, penury, parsimony } (booleans). Returns the MP the cast costs.
function M.cost(base, group, fx)
    base = floor(tonumber(base) or 0);
    if (base <= 0) then return 0; end
    if (fx.manafont or fx.manawell) then return 0; end
    local c = base;
    if (group == 'white') then
        if (fx.light) then c = down10(c); elseif (fx.dark) then c = up20(c); end
        if (fx.penury) then c = half(c); end
    elseif (group == 'black') then
        if (fx.dark) then c = down10(c); elseif (fx.light) then c = up20(c); end
        if (fx.parsimony) then c = half(c); end
    end
    return c;
end

-- Live state (written by M.update, read by M.short; plain fields, nothing is allocated per frame).
M.fx = { manafont = false, manawell = false, light = false, dark = false, penury = false, parsimony = false };
M.mp, M.maxmp, M.known, M.next_at = 0, 0, false, -1;

local F, E = M.fx, M.EFFECT;
local function see(v)
    v = tonumber(v);
    if (v == nil) then return; end
    v = floor(v);
    if (v >= 32768) then v = v - 65536; end        -- int16 read as uint16
    if (v <= 0 or v == 255) then return; end        -- empty slot
    if (v == E.MANAFONT) then F.manafont = true;
    elseif (v == E.MANAWELL) then F.manawell = true;
    elseif (v == E.LIGHT_ARTS) then F.light = true;
    elseif (v == E.DARK_ARTS) then F.dark = true;
    elseif (v == E.PENURY) then F.penury = true;
    elseif (v == E.PARSIMONY) then F.parsimony = true; end
end
local function at(list, i) return list[i]; end

-- The buff list may be a table (0- or 1-based), a container userdata or an int16[32] cdata.
function M.scan_buffs(list)
    F.manafont, F.manawell, F.light, F.dark, F.penury, F.parsimony = false, false, false, false, false, false;
    local t = type(list);
    if (t == 'table') then
        local lo = (list[0] ~= nil) and 0 or 1;
        for i = lo, lo + 31 do see(list[i]); end
    elseif (t == 'cdata') then
        for i = 0, 31 do see(list[i]); end
    elseif (t == 'userdata') then
        for i = 1, 32 do
            local ok, v = pcall(at, list, i);
            if (not ok) then break; end
            see(v);
        end
        local ok, v = pcall(at, list, 0);
        if (ok and v ~= nil) then see(v); end
    end
end

-- Reads current MP and the buffs (throttled). Safe to call every frame.
function M.update(now)
    if (now < M.next_at) then return; end
    M.next_at = now + M.REFRESH_EVERY;
    local core = rawget(_G, 'AshitaCore');
    if (core == nil) then M.known = false; return; end
    local ok = pcall(function ()
        local mm = core:GetMemoryManager();
        local party = mm:GetParty();
        local p = mm:GetPlayer();
        if (party == nil or p == nil) then M.known = false; return; end
        local mp = party:GetMemberMP(0);
        M.mp, M.maxmp = tonumber(mp) or 0, tonumber(p:GetMPMax()) or 0;
        M.known = (party:GetMemberIsActive(0) == 1) and M.maxmp > 0;
        M.scan_buffs(p:GetBuffs());
    end);
    if (not ok) then M.known = false; end
end

-- Spell resource data, read once per spell: base cost and group.
local meta = {};
local function field(r, k) local ok, v = pcall(function () return r[k]; end); if (ok) then return v; end return nil; end
function M.spell_meta(id)
    local m = meta[id];
    if (m ~= nil) then return m; end
    m = { cost = 0, group = nil, ok = false };
    local core = rawget(_G, 'AshitaCore');
    local rm = core and core:GetResourceManager() or nil;
    if (rm ~= nil) then
        local okk, sp = pcall(rm.GetSpellById, rm, id);
        if (okk and sp ~= nil) then
            local c = tonumber(field(sp, 'ManaCost'));
            m.cost = (c ~= nil and c > 0) and c or 0;
            m.group = M.group(tonumber(field(sp, 'Type')), tonumber(field(sp, 'Skill')));
            m.ok = true;
        end
    end
    if (m.ok) then meta[id] = m; end        -- a failed read is retried next time
    return m;
end

-- MP the spell would cost right now (nil when it has no MP cost, e.g. ninjutsu).
function M.current_cost(id)
    local m = M.spell_meta(id);
    if (m.cost <= 0) then return nil; end
    return M.cost(m.cost, m.group, F);
end

-- True when MP is known and below the cost.
function M.short(id)
    if (not M.known) then return false; end
    local c = M.current_cost(id);
    return c ~= nil and M.mp < c;
end

function M.clear() meta = {}; end

-- Active cost-changing effects as text (for /rxi mp).
function M.effects_text()
    local t = {};
    if (F.manafont) then t[#t + 1] = 'Manafont'; end
    if (F.manawell) then t[#t + 1] = 'Manawell'; end
    if (F.light) then t[#t + 1] = 'Light Arts'; end
    if (F.dark) then t[#t + 1] = 'Dark Arts'; end
    if (F.penury) then t[#t + 1] = 'Penury'; end
    if (F.parsimony) then t[#t + 1] = 'Parsimony'; end
    if (#t == 0) then return 'none'; end
    return table.concat(t, ', ');
end

return M;
