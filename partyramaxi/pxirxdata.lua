--[[
* RecastXI - rxdata.lua
* Recast reading, name resolution, job tables and the known spell/ability lists.
*
--]]

local M = {};

M.JOBS = { 'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
           'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN' };

-- SP1 (recast timer 0, slot 0) and SP2 (recast timer 254, needs main job level 96 on retail).
M.SP = {
    { 'Mighty Strikes', 'Brazen Rush' },       { 'Hundred Fists', 'Inner Strength' },
    { 'Benediction', 'Asylum' },               { 'Manafont', 'Subtle Sorcery' },
    { 'Chainspell', 'Stymie' },                { 'Perfect Dodge', 'Larceny' },
    { 'Invincible', 'Intervene' },             { 'Blood Weapon', 'Soul Enslavement' },
    { 'Familiar', 'Unleash' },                 { 'Soul Voice', 'Clarion Call' },
    { 'Eagle Eye Shot', 'Overkill' },          { 'Meikyo Shisui', 'Yaegasumi' },
    { 'Mijin Gakure', 'Mikage' },              { 'Spirit Surge', 'Fly High' },
    { 'Astral Flow', 'Astral Conduit' },       { 'Azure Lore', 'Unbridled Wisdom' },
    { 'Wild Card', 'Cutting Cards' },          { 'Overdrive', 'Heady Artifice' },
    { 'Trance', 'Grand Pas' },                 { 'Tabula Rasa', 'Caper Emissarius' },
    { 'Bolster', 'Widened Compass' },          { 'Elemental Sforzo', 'Odyllic Subterfuge' },
};
M.SP1_TIMER, M.SP2_TIMER, M.SP2_LEVEL = 0, 254, 96;
M.SP_DEFAULT_TOTAL = 3600;   -- seconds; the pie uses max(seen, this)

-- Recast timer ids shared by several abilities -> one sensible row name.
M.SHARED = {
    [231] = 'Stratagems', [102] = 'Ready / Sic', [173] = 'Blood Pact: Rage', [174] = 'Blood Pact: Ward',
    [195] = 'Quick Draw', [193] = 'Phantom Roll', [216] = 'Sambas', [217] = 'Waltzes', [218] = 'Jigs',
    [220] = 'Steps', [221] = 'Flourishes I', [222] = 'Flourishes II', [226] = 'Flourishes III',
    [92] = 'Rune Enchantment',
};

M.ELEMENTS = { [0] = 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' };
M.SKILL_CAT = { [32] = 'divine', [33] = 'healing', [34] = 'enhancing', [35] = 'enfeebling', [36] = 'elemental',
                [37] = 'dark', [38] = 'summoning', [39] = 'ninjutsu', [40] = 'song', [41] = 'song', [42] = 'song',
                [43] = 'blue', [44] = 'geomancy', [45] = 'geomancy' };
-- Ability resource types that never have a recast row (weapon skills, traits, monster skills).
M.SKIP_TYPES = { [3] = true, [4] = true, [20] = true };
M.ABILITY_MIN, M.ABILITY_MAX = 0x200, 0x600;
M.SPELL_MAX = 1023;

-- Interned key strings (no per-frame string building).
local KEY_S, KEY_A = {}, {};
function M.key_spell(id) local k = KEY_S[id]; if (k == nil) then k = 's' .. id; KEY_S[id] = k; end return k; end
function M.key_ability(tid) local k = KEY_A[tid]; if (k == nil) then k = 'a' .. tid; KEY_A[tid] = k; end return k; end

local floor = math.floor;

-- Reads a resource Name[1] (table, userdata or string), never errors.
local function res_name(r)
    if (r == nil) then return nil; end
    local ok, n = pcall(function () local nm = r.Name; if (type(nm) == 'string') then return nm; end return nm[1]; end);
    if (ok and type(n) == 'string' and n ~= '') then return n; end
    return nil;
end
M.res_name = res_name;
local function field(r, k) local ok, v = pcall(function () return r[k]; end); if (ok) then return v; end return nil; end
local function level_at(levels, job)
    if (levels == nil or job == nil or job <= 0) then return nil; end
    local ok, v = pcall(function () return levels[job + 1]; end);
    if (ok and type(v) == 'number') then return v; end
    return nil;
end

local function core() return rawget(_G, 'AshitaCore'); end
local function mm() local c = core(); return c and c:GetMemoryManager() or nil; end
local function resm() local c = core(); return c and c:GetResourceManager() or nil; end
local function player() local m = mm(); return m and m:GetPlayer() or nil; end

M.state = {
    recs = {},                  -- key -> record (persistent, reused)
    spells = { n = 0 }, abilities = { n = 0 },   -- active records this scan (arrays + n)
    sp = { { rem = 0, total = M.SP_DEFAULT_TOTAL, shown = false, available = false, name = '' },
           { rem = 0, total = M.SP_DEFAULT_TOTAL, shown = false, available = false, name = '' } },
    scan_time = -1, scans = 0, job_sig = -1, main = 0, sub = 0, mainlv = 0, sublv = 0,
    test = false, test_t0 = 0,
};
M.units = { ability = 60, spell = 60 };
M.sp2_mode = 'auto';
-- v1.2.0: SP1/SP2 as normal ability rows (keys 'a0' / 'a254') instead of header badges.
M.sp_rows = false;
M.SP_KEY = { [1] = 'a0', [2] = 'a254' };
M.SP_TID = { [1] = 0, [2] = 254 };

-- Ability index: timer id -> { {id=, name=, type=}, ... } built once per session (lazily).
M.index = nil;
function M.build_index()
    local r = resm();
    local idx = {};
    if (r == nil) then return idx; end      -- v1.2.0: not cached, retried once resources exist
    local n = 0;
    for id = M.ABILITY_MIN, M.ABILITY_MAX do
        local ok, ab = pcall(r.GetAbilityById, r, id);
        if (ok and ab ~= nil) then
            local name = res_name(ab);
            local typ = field(ab, 'Type') or 0;
            local tid = field(ab, 'RecastTimerId');
            if (name ~= nil and type(tid) == 'number' and not M.SKIP_TYPES[typ]) then
                local l = idx[tid];
                if (l == nil) then l = {}; idx[tid] = l; end
                l[#l + 1] = { id = field(ab, 'Id') or id, name = name, type = typ };
                n = n + 1;
            end
        end
    end
    if (n > 0) then M.index = idx; end
    return idx;
end

local function has_ability(p, id)
    if (p == nil) then return false; end
    local ok, v = pcall(p.HasAbility, p, id);
    return ok and v == true;
end
local function has_spell(p, id)
    if (p == nil) then return false; end
    local ok, v = pcall(p.HasSpell, p, id);
    return ok and v == true;
end

-- Name + icon resource id for an ability timer row (cached per job signature).
local tname_cache, tres_cache = {}, {};
function M.ability_info(tid)
    local n = tname_cache[tid];
    if (n ~= nil) then return n, tres_cache[tid]; end
    local idx = M.index or M.build_index();
    local p = player();
    local list = idx[tid];
    local known, first = 0, nil;
    local names = nil;
    if (list ~= nil) then
        for i = 1, #list do
            local c = list[i];
            if (has_ability(p, c.id)) then
                known = known + 1;
                if (first == nil) then first = c; end
                names = names or {};
                names[#names + 1] = c.name;
            end
        end
    end
    local res_id = nil;
    if (known == 1) then
        n, res_id = first.name, first.id;
    elseif (known > 1) then
        n = M.SHARED[tid];
        if (n == nil) then
            n = names[1] .. ' / ' .. names[2];
            if (known > 2) then n = n .. ' +' .. (known - 2); end
        end
        res_id = first.id;
    else
        local r = resm();
        local ab = nil;
        if (r ~= nil) then local ok, v = pcall(r.GetAbilityByTimerId, r, tid); if (ok) then ab = v; end end
        n = M.SHARED[tid] or res_name(ab) or ('Ability #' .. tid);
        res_id = ab and field(ab, 'Id') or (list and list[1] and list[1].id) or nil;
    end
    tname_cache[tid], tres_cache[tid] = n, res_id or false;
    return n, res_id or false;
end

local sname_cache, selem_cache, scat_cache = {}, {}, {};
function M.spell_info(id)
    local n = sname_cache[id];
    if (n ~= nil) then return n, selem_cache[id], scat_cache[id]; end
    local r = resm();
    local sp = nil;
    if (r ~= nil) then local ok, v = pcall(r.GetSpellById, r, id); if (ok) then sp = v; end end
    n = res_name(sp) or ('Spell #' .. id);
    local el = sp and field(sp, 'Element') or nil;
    local sk = sp and field(sp, 'Skill') or nil;
    sname_cache[id] = n;
    selem_cache[id] = (type(el) == 'number' and M.ELEMENTS[el]) or false;
    scat_cache[id] = (type(sk) == 'number' and M.SKILL_CAT[sk]) or 'magic';
    return n, selem_cache[id], scat_cache[id];
end

function M.clear_caches()
    tname_cache, tres_cache = {}, {};
end

local function get_rec(key, kind, id)
    local r = M.state.recs[key];
    if (r == nil) then
        r = { key = key, fkey = key, kind = kind, id = id, rem = 0, total = 0, seen = false, active = false,
              name = nil, element = false, cat = false, res_id = false, test = false };
        M.state.recs[key] = r;
    end
    return r;
end
M.get_rec = get_rec;

-- Job signature: refresh names/known lists when main/sub/levels change.
function M.update_job()
    local p = player();
    local st = M.state;
    if (p == nil) then return false; end
    local ok1, main = pcall(p.GetMainJob, p);
    local ok2, mainlv = pcall(p.GetMainJobLevel, p);
    local ok3, sub = pcall(p.GetSubJob, p);
    local ok4, sublv = pcall(p.GetSubJobLevel, p);
    if (not (ok1 and ok2 and ok3 and ok4)) then return false; end
    main, mainlv, sub, sublv = main or 0, mainlv or 0, sub or 0, sublv or 0;
    local sig = ((main * 256 + mainlv) * 256 + sub) * 256 + sublv;
    if (sig ~= st.job_sig) then
        st.job_sig, st.main, st.mainlv, st.sub, st.sublv = sig, main, mainlv, sub, sublv;
        M.clear_caches();
        -- re-resolve ability names on the next scan that sees them (keep the old name meanwhile,
        -- so rows still sliding out never lose their label)
        for _, r in pairs(st.recs) do if (r.kind == 'ability' and not r.test) then r.stale = true; end end
        return true;
    end
    return false;
end

function M.job_abbr(id) return M.JOBS[id or 0] or 'NON'; end

local function finish_sp(i, rem)
    local s = M.state.sp[i];
    if (rem > 0) then
        if (s.rem <= 0 or rem > s.total) then s.total = math.max(rem, M.SP_DEFAULT_TOTAL); end
    end
    s.rem = rem;
end

--[[
* SP badges (v1.1.0). For each slot: shown (draw a badge), available (the job can use it now) and,
* at draw time, ready = available and no time left.
*   SP1: available from main job level 1 (any job).
*   SP2: available at main job level 96+ (M.SP2_LEVEL), or whenever its timer (254) is running.
* sp2_mode: 'auto' shows SP2 only when available; 'always' always shows it, MUTED when not
* available (never 'ready'); 'never' hides it.
--]]
function M.update_sp_shown()
    local st = M.state;
    local names = M.SP[st.main];
    local s1, s2 = st.sp[1], st.sp[2];
    s1.name = names and names[1] or '';
    s2.name = names and names[2] or '';
    s1.available = names ~= nil and st.mainlv >= 1;
    s2.available = names ~= nil and (st.mainlv >= M.SP2_LEVEL or s2.rem > 0);
    s1.shown = s1.available;
    local m = M.sp2_mode;
    if (m == 'always') then s2.shown = names ~= nil;
    elseif (m == 'never') then s2.shown = false;
    else s2.shown = s2.available; end
    if (st.test) then
        s1.shown, s1.available = true, true;
        if (m ~= 'never') then s2.shown = true; end
        if (st.main == 0) then s1.name, s2.name = 'Chainspell', 'Stymie'; end
        s2.available = s2.available or s2.shown;
    end
    if (M.sp_rows) then s1.shown, s2.shown = false, false; end   -- v1.2.0: shown as list rows instead
end
-- Ashita ability id of the current job's SP1/SP2 (for icons), from the ability index by name.
function M.sp_res_id(i)
    local name = M.state.sp[i].name;
    if (name == nil or name == '') then return false; end
    local idx = M.index or M.build_index();
    local l = idx[M.SP_TID[i]];
    if (l ~= nil) then for k = 1, #l do if (l[k].name == name) then return l[k].id; end end end
    return false;
end
function M.sp_name(i)
    local n = M.state.sp[i].name;
    if (n == nil or n == '') then return (i == 1) and 'SP1' or 'SP2'; end
    return n;
end
-- 'ready' | 'cooldown' | 'unavailable'
function M.sp_state(i, now)
    local s = M.state.sp[i];
    if (not s.available) then return 'unavailable'; end
    if (M.sp_remaining(i, now) > 0) then return 'cooldown'; end
    return 'ready';
end

local function push(list, r) list.n = list.n + 1; list[list.n] = r; end
local function trim(list, from) for i = from, #list do list[i] = nil; end end

--[[
* Scans the recast memory. Fills state.spells / state.abilities with records whose .rem is the
* remaining time in seconds at state.scan_time. Records not seen this scan get active=false.
--]]
function M.scan(now)
    local st = M.state;
    st.scans = st.scans + 1;
    st.scan_time = now;
    M.update_job();
    local sp, ab = st.spells, st.abilities;
    for i = 1, sp.n do sp[i].seen = false; end
    for i = 1, ab.n do ab[i].seen = false; end
    local old_sn, old_an = sp.n, ab.n;
    sp.n, ab.n = 0, 0;
    if (st.test) then
        M.test_fill(now);
    else
        local m = mm();
        local rc = m and m:GetRecast() or nil;
        local sp1, sp2 = 0, 0;
        if (rc ~= nil) then
            local ua, us = M.units.ability, M.units.spell;
            for x = 0, 31 do
                local tid = rc:GetAbilityTimerId(x) or 0;
                local t = rc:GetAbilityTimer(x) or 0;
                if (t > 0) then
                    if (x == 0 and tid == 0) then
                        sp1 = t / ua;
                    elseif (tid == M.SP2_TIMER) then
                        sp2 = t / ua;
                    elseif (tid ~= 0) then
                        local r = get_rec(M.key_ability(tid), 'ability', tid);
                        if (r.name == nil or r.stale) then r.name, r.res_id = M.ability_info(tid); r.cat = 'ability'; r.stale = false; end
                        r.rem = t / ua;
                        if (not r.active or r.rem > r.total) then r.total = r.rem; end
                        r.seen = true; push(ab, r);
                    end
                end
            end
            for id = 0, M.SPELL_MAX do
                local t = rc:GetSpellTimer(id) or 0;
                if (t > 0) then
                    local r = get_rec(M.key_spell(id), 'spell', id);
                    if (r.name == nil) then r.name, r.element, r.cat = M.spell_info(id); r.res_id = id; end
                    r.rem = t / us;
                    if (not r.active or r.rem > r.total) then r.total = r.rem; end
                    r.seen = true; push(sp, r);
                end
            end
        end
        finish_sp(1, sp1); finish_sp(2, sp2);
        if (M.sp_rows) then
            for i = 1, 2 do
                local rem = (i == 1) and sp1 or sp2;
                if (rem > 0) then
                    local r = get_rec(M.SP_KEY[i], 'ability', M.SP_TID[i]);
                    r.sp, r.cat = i, 'ability';
                    if (r.name ~= M.sp_name(i)) then r.name = M.sp_name(i); r.res_id = M.sp_res_id(i); end
                    r.rem = rem;
                    if (not r.active or r.rem > r.total) then r.total = math.max(r.rem, st.sp[i].total); end
                    r.seen = true; push(ab, r);
                end
            end
        end
    end
    -- records that dropped out are no longer active
    for _, r in pairs(st.recs) do
        if (r.active and not r.seen) then r.active = false; r.rem = 0; end
        if (r.seen) then r.active = true; end
    end
    trim(sp, sp.n + 1); trim(ab, ab.n + 1);
    M.update_sp_shown();
    return old_sn ~= sp.n or old_an ~= ab.n;
end

-- Remaining seconds of a record now (interpolated between scans).
function M.remaining(r, now)
    if (not r.active) then return 0; end
    local v = r.rem - (now - M.state.scan_time);
    if (v < 0) then return 0; end
    return v;
end
function M.sp_remaining(i, now)
    local s = M.state.sp[i];
    if (s.rem <= 0) then return 0; end
    local v = s.rem - (now - M.state.scan_time);
    if (v < 0) then return 0; end
    return v;
end

--[[ Test mode: sample data with real spell ids, timers that count down and loop. ]]
M.SAMPLE = {
    { 'spell', 109, 'Refresh', 40, 'Light', 'enhancing' }, { 'spell', 106, 'Phalanx', 10, 'Light', 'enhancing' },
    { 'spell', 57, 'Haste', 20, 'Wind', 'enhancing' },     { 'spell', 3, 'Cure III', 9, 'Light', 'healing' },
    { 'spell', 216, 'Gravity', 15, 'Wind', 'enfeebling' }, { 'spell', 24, 'Dia II', 30, 'Light', 'enfeebling' },
    { 'spell', 54, 'Stoneskin', 60, 'Earth', 'enhancing' },
    { 'ability', 49, 'Convert', 600, false, 'ability' },  { 'ability', 26, 'Divine Seal', 600, false, 'ability' },
};
M.SAMPLE_OFFSET = { 2, 5.8, 13, 1.2, 1, 4, 8, 188, 367 };
local SAMPLE_KEYS = {};
function M.set_test(on, now)
    local st = M.state;
    st.test = on and true or false;
    st.test_t0 = now or 0;
    for k, r in pairs(st.recs) do if (r.test) then st.recs[k] = nil; end end
    M.update_sp_shown();
end
function M.test_fill(now)
    local st = M.state;
    local el = now - st.test_t0;
    for i, s in ipairs(M.SAMPLE) do
        local kind, id, name, total, elem, cat = s[1], s[2], s[3], s[4], s[5], s[6];
        local period = total + 4;             -- each timer runs out, shows Ready, then restarts
        local rem = total - ((el + M.SAMPLE_OFFSET[i]) % period);
        local key = SAMPLE_KEYS[i];
        if (key == nil) then key = (kind == 'spell') and ('t' .. M.key_spell(id)) or ('t' .. M.key_ability(id)); SAMPLE_KEYS[i] = key; end
        if (rem > 0) then
            local r = get_rec(key, kind, id);
            r.test, r.name, r.element, r.cat, r.res_id = true, name, elem, cat, (kind == 'spell') and id or false;
            r.fkey = (kind == 'spell') and M.key_spell(id) or M.key_ability(id);
            r.rem = rem; if (not r.active or rem > r.total) then r.total = total; end
            r.seen = true;
            push(kind == 'spell' and st.spells or st.abilities, r);
        end
    end
    local s1, s2 = st.sp[1], st.sp[2];
    s1.rem = 0; s2.total = 3600; s2.rem = 2832 - el; if (s2.rem < 0) then s2.rem = 0; end
    if (M.sp_rows and s2.rem > 0) then
        local r = get_rec('t' .. M.SP_KEY[2], 'ability', M.SP_TID[2]);
        r.test, r.sp, r.fkey, r.cat, r.res_id = true, 2, M.SP_KEY[2], 'ability', false;
        r.name = M.sp_name(2);
        r.rem, r.total, r.seen = s2.rem, 3600, true;
        push(st.abilities, r);
    end
end

--[[ Known lists for the config window (built on demand, not per frame). ]]
local function usable(levels, job, lv)
    local req = level_at(levels, job);
    return req ~= nil and req >= 1 and req <= 99 and req <= lv;
end
function M.known_spells()
    local out = {};
    local r, p = resm(), player();
    if (r == nil or p == nil) then return out; end
    M.update_job();
    local st = M.state;
    for id = 1, M.SPELL_MAX do
        local ok, s = pcall(r.GetSpellById, r, id);
        if (ok and s ~= nil) then
            local name = res_name(s);
            local index = field(s, 'Index') or id;
            if (name ~= nil and has_spell(p, index)) then
                local lv = field(s, 'LevelRequired');
                local main_ok = usable(lv, st.main, st.mainlv);
                local sub_ok = usable(lv, st.sub, st.sublv);
                if (main_ok or sub_ok) then
                    local el = field(s, 'Element');
                    out[#out + 1] = { key = M.key_spell(id), id = id, name = name, sub = (not main_ok) and sub_ok,
                                      element = (type(el) == 'number' and M.ELEMENTS[el]) or false,
                                      cat = M.SKILL_CAT[field(s, 'Skill') or -1] or 'magic', res_id = id, kind = 'spell' };
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.name < b.name; end);
    return out;
end
function M.known_abilities()
    local out, header = {}, {};
    local p = player();
    if (p == nil) then return out, header; end
    M.update_job();
    local idx = M.index or M.build_index();
    for tid, list in pairs(idx) do
        if (tid ~= M.SP1_TIMER and tid ~= M.SP2_TIMER) then
            for i = 1, #list do
                if (has_ability(p, list[i].id)) then
                    local name, res_id = M.ability_info(tid);
                    out[#out + 1] = { key = M.key_ability(tid), id = tid, name = name, res_id = res_id, cat = 'ability', element = false, kind = 'ability' };
                    break;
                end
            end
        end
    end
    local st = M.state;
    if (M.sp_rows) then
        for i = 1, 2 do
            if (st.sp[i].available) then
                out[#out + 1] = { key = M.SP_KEY[i], id = M.SP_TID[i], name = M.sp_name(i), res_id = M.sp_res_id(i), cat = 'ability', element = false, kind = 'ability', sp = i };
            end
        end
    end
    table.sort(out, function (a, b) return a.name < b.name; end);
    for i = 1, 2 do if (st.sp[i].shown) then header[#header + 1] = { name = st.sp[i].name, slot = i }; end end
    return out, header;
end

--[[
* v1.2.0 availability: can the character use this entry right now?
*   spell   : learned (HasSpell) AND the main or the sub job meets the level at the CURRENT levels
*             (level sync, level-down, sub job disabled -> level 0, sub job change all count)
*   ability : any ability on that recast timer that the player has right now (HasAbility)
*   SP1/SP2 : the badge availability (SP2 needs main level 96)
* Never errors: missing player/resources -> not available. Cached per job signature for 5 s.
* Test mode sample entries are always available.
--]]
local SAMPLE_FKEY = nil;
local function sample_fkeys()
    if (SAMPLE_FKEY == nil) then
        SAMPLE_FKEY = {};
        for _, smp in ipairs(M.SAMPLE) do
            SAMPLE_FKEY[(smp[1] == 'spell') and M.key_spell(smp[2]) or M.key_ability(smp[2])] = true;
        end
    end
    return SAMPLE_FKEY;
end
local function compute_available(rec)
    local st = M.state;
    if (rec.sp ~= nil) then return st.sp[rec.sp] ~= nil and st.sp[rec.sp].available == true; end
    if (st.test and (rec.test or sample_fkeys()[rec.fkey])) then return true; end
    local p = player();
    if (p == nil or type(rec.id) ~= 'number') then return false; end
    if (rec.kind == 'spell') then
        local r = resm();
        if (r == nil) then return false; end
        local ok, sp = pcall(r.GetSpellById, r, rec.id);
        if (not ok or sp == nil) then return false; end
        local index = field(sp, 'Index') or rec.id;
        if (not has_spell(p, index)) then return false; end
        local lv = field(sp, 'LevelRequired');
        return usable(lv, st.main, st.mainlv) or usable(lv, st.sub, st.sublv);
    end
    local idx = M.index or M.build_index();
    local l = idx[rec.id];
    if (l == nil) then return false; end
    for i = 1, #l do if (has_ability(p, l[i].id)) then return true; end end
    return false;
end
M.AVAIL_TTL = 5;
function M.available(rec, now)
    if (rec == nil) then return false; end
    local st = M.state;
    now = now or st.scan_time;
    if (rec.av_sig ~= st.job_sig or rec.av_test ~= st.test or now >= (rec.av_t or -1) + M.AVAIL_TTL or now < (rec.av_t or 0)) then
        local ok, v = pcall(compute_available, rec);
        rec.av = ok and v == true;
        rec.av_sig, rec.av_test, rec.av_t = st.job_sig, st.test, now;
    end
    return rec.av;
end
function M.invalidate_available() for _, r in pairs(M.state.recs) do r.av_sig = nil; end end

--[[
* v1.2.0: record for a pinned filter key ('s<id>' / 'a<timer id>'), for "keep pinned visible".
* Returns nil for malformed keys. In test mode the sample record for that key is used when it
* exists, so a pinned sample never shows twice.
--]]
local PIN_PARSE = {};   -- fkey -> { kind, id, test key } (parsed once; no per-frame strings)
function M.pinned_rec(fkey)
    if (type(fkey) ~= 'string') then return nil; end
    local pp = PIN_PARSE[fkey];
    if (pp == nil) then pp = { fkey:sub(1, 1), tonumber(fkey:sub(2)), 't' .. fkey }; PIN_PARSE[fkey] = pp; end
    local st = M.state;
    if (st.test) then local tr = st.recs[pp[3]]; if (tr ~= nil) then return tr; end end
    local kind, id = pp[1], pp[2];
    if (id == nil or id < 0 or id ~= floor(id)) then return nil; end
    if (kind == 's') then
        if (id > M.SPELL_MAX) then return nil; end
        local r = get_rec(fkey, 'spell', id);
        if (r.name == nil) then r.name, r.element, r.cat = M.spell_info(id); r.res_id = id; end
        return r;
    elseif (kind == 'a') then
        if (id > 1023) then return nil; end
        local r = get_rec(fkey, 'ability', id);
        if (id == M.SP_TID[1] or id == M.SP_TID[2]) then
            r.sp = (id == M.SP_TID[1]) and 1 or 2; r.cat = 'ability';
            if (r.name ~= M.sp_name(r.sp)) then r.name = M.sp_name(r.sp); r.res_id = M.sp_res_id(r.sp); end
        elseif (r.name == nil or r.stale) then
            r.name, r.res_id = M.ability_info(id); r.cat = 'ability'; r.stale = false;
        end
        return r;
    end
    return nil;
end

-- Raw recast slots for '/recastxi debug'.
function M.debug_lines()
    local lines = {};
    local m = mm();
    local rc = m and m:GetRecast() or nil;
    if (rc == nil) then lines[1] = 'GetRecast() returned nil.'; return lines; end
    lines[#lines + 1] = ('Units: ability /%d, spell /%d (1/60 s = 60).'):format(M.units.ability, M.units.spell);
    for x = 0, 31 do
        local tid, t = rc:GetAbilityTimerId(x) or 0, rc:GetAbilityTimer(x) or 0;
        if (t > 0 or tid ~= 0) then
            local name = (x == 0 and tid == 0) and ('SP1 ' .. (M.state.sp[1].name or '')) or
                         (tid == M.SP2_TIMER and ('SP2 ' .. (M.state.sp[2].name or ''))) or (M.ability_info(tid));
            lines[#lines + 1] = ('ability slot %2d  timer id %3d  raw %6d  = %.1f s  %s'):format(x, tid, t, t / M.units.ability, name);
        end
    end
    for id = 0, M.SPELL_MAX do
        local t = rc:GetSpellTimer(id) or 0;
        if (t > 0) then
            lines[#lines + 1] = ('spell %4d  raw %6d  = %.1f s  %s'):format(id, t, t / M.units.spell, (M.spell_info(id)));
        end
    end
    return lines;
end

return M;
