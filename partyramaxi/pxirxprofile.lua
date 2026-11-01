--[[
* RecastXI - rxprofile.lua
* Per-job filters (hidden keys) and pinned priority rows in a manual order.
*
* Stored in settings.profiles[<profile key>]:
*   { hidden = { s109 = true, a12 = true }, pins = { spells = { 's109', 's106' }, abilities = { 'a49' } } }
* The profile key is the main job ('RDM'), or 'RDM_WHM' when 'per_sub' is on.
* Anything not in 'hidden' is shown, so newly learned spells/abilities default to shown.
--]]

local M = {};
M.version = 0;     -- bumped on any change (rank caches compare against it)

function M.key(s, main_abbr, sub_abbr)
    if (s.per_sub and sub_abbr ~= nil and sub_abbr ~= '' and sub_abbr ~= 'NON') then return main_abbr .. '_' .. sub_abbr; end
    return main_abbr;
end

local function ensure(p)
    if (type(p.hidden) ~= 'table') then p.hidden = {}; end
    if (type(p.pins) ~= 'table') then p.pins = {}; end
    if (type(p.pins.spells) ~= 'table') then p.pins.spells = {}; end
    if (type(p.pins.abilities) ~= 'table') then p.pins.abilities = {}; end
    return p;
end

function M.get(s, key, create)
    if (type(s.profiles) ~= 'table') then s.profiles = {}; end
    local p = s.profiles[key];
    if (p == nil) then
        if (not create) then return nil; end
        p = { hidden = {}, pins = { spells = {}, abilities = {} } };
        s.profiles[key] = p;
        M.version = M.version + 1;
    end
    return ensure(p);
end

-- Profile for reading (no write). Returns a shared empty profile when none exists.
local EMPTY = { hidden = {}, pins = { spells = {}, abilities = {} } };
function M.peek(s, key)
    return M.get(s, key, false) or EMPTY;
end

function M.group_of(key) return (key:sub(1, 1) == 's') and 'spells' or 'abilities'; end

function M.is_hidden(p, key) return p.hidden[key] == true; end
function M.set_hidden(p, key, hidden)
    if (hidden) then p.hidden[key] = true; else p.hidden[key] = nil; end
    M.version = M.version + 1;
end

function M.pin_index(p, key)
    local l = p.pins[M.group_of(key)];
    for i = 1, #l do if (l[i] == key) then return i; end end
    return nil;
end
function M.toggle_pin(p, key)
    local g = M.group_of(key);
    local l = p.pins[g];
    local i = M.pin_index(p, key);
    if (i ~= nil) then table.remove(l, i); else l[#l + 1] = key; end
    M.version = M.version + 1;
    return i == nil;
end
-- dir = -1 (up) / +1 (down) / 'top'
function M.move(p, key, dir)
    local l = p.pins[M.group_of(key)];
    local i = M.pin_index(p, key);
    if (i == nil) then return false; end
    local j = (dir == 'top') and 1 or (i + dir);
    if (j < 1 or j > #l or j == i) then return false; end
    table.remove(l, i); table.insert(l, j, key);
    M.version = M.version + 1;
    return true;
end
function M.show_all(p, keys) for i = 1, #keys do p.hidden[keys[i]] = nil; end M.version = M.version + 1; end
function M.hide_all(p, keys) for i = 1, #keys do p.hidden[keys[i]] = true; end M.version = M.version + 1; end
function M.unpin_all(p, group)
    local l = p.pins[group];
    for i = #l, 1, -1 do l[i] = nil; end
    M.version = M.version + 1;
end

-- Validates/cleans a profiles table loaded from disk. Returns number of fixes.
function M.validate(profiles)
    local fixes = 0;
    if (type(profiles) ~= 'table') then return 1; end
    for k, p in pairs(profiles) do
        if (type(k) ~= 'string' or type(p) ~= 'table') then profiles[k] = nil; fixes = fixes + 1;
        else
            ensure(p);
            for hk, v in pairs(p.hidden) do
                if (type(hk) ~= 'string' or not hk:match('^[sa]%d+$') or v ~= true) then p.hidden[hk] = nil; fixes = fixes + 1; end
            end
            for _, g in ipairs({ 'spells', 'abilities' }) do
                local l, seen, out = p.pins[g], {}, {};
                local want = (g == 'spells') and 's' or 'a';
                for i = 1, #l do
                    local v = l[i];
                    if (type(v) == 'string' and v:match('^' .. want .. '%d+$') and not seen[v]) then seen[v] = true; out[#out + 1] = v;
                    else fixes = fixes + 1; end
                end
                if (#out ~= #l) then p.pins[g] = out; end
            end
        end
    end
    return fixes;
end

return M;
