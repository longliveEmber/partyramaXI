--[[
* RecastXI - Copyright (c) 2026 Banedon
*
* This program is free software: you can redistribute it and/or modify it under the terms of the
* GNU General Public License as published by the Free Software Foundation, either version 3 of the
* License, or (at your option) any later version. It is distributed in the hope that it will be
* useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
* FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file or <https://www.gnu.org/licenses/>.
--]]

--[[
* RecastXI - spell and ability recast tracker for Ashita v4.
*
* Commands: /pxi recast  [config | lock | unlock | reset | test | debug | debug icons |
*           theme <name> | palette drachen|wyrm | perf | perf report | safe | debug rect | help]
*
* Notes for maintainers (rules learned from earlier addons):
*  - Custom drawing uses WINDOW-LOCAL coordinates; the origin is captured right after Begin as
*    GetCursorScreenPos() - GetCursorPos(). GetWindowPos/GetWindowSize, io.DisplaySize and the
*    framebuffer scale are never used (v1.1.2: not even to remember the dragged position).
*  - Clip rects are always intersected (never PushClipRect(..., false)) and clamped to the window:
*    Ashita's D3D8 renderer turns a clip rect into a viewport, and one the back buffer can't hold
*    stretches that draw command over the whole screen. Primitives outside the window are skipped.
*  - Optional ImGui APIs are guarded (no SetWindowFontScale; fonts use PushFont(font, size)).
*  - Every widget has a unique ## id; Begin/End, PushID/PopID, PushFont/PopFont and style pushes
*    are balanced on every path.
*  - Nothing is allocated per frame on the main window path once strings/rows are cached.
--]]

-- PartyramaXI: this is RecastXI 1.4.1 run as the "Recasts" module (pxirecast.lua + pxirx*.lua). It is driven by
-- partyramaxi.lua (M.load / M.unload / M.present / M.command) instead of its own events, keeps its own settings
-- file (alias 'recast' next to PartyramaXI's settings), reads its icons and fonts from addons\partyramaxi\icons\ and fonts\,
-- and can sit attached above the party list (M.attach_box, set each frame by PartyramaXI). Its settings tabs are
-- drawn inside the PartyramaXI settings window (M.config_body). The standalone RecastXI addon is separate.

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local data     = require('pxirxdata');
local prof     = require('pxirxprofile');
local PF       = require('pxirxperf');
local list     = require('pxirxlist');
local D        = require('pxirxdraw');
local themes   = require('pxirxthemes');
local icons    = require('pxirxicons');
local fonts    = require('pxirxfonts');
local mpc      = require('pxirxmp');
local FX       = require('pxirxfx');

local floor, ceil, min, max, sin, pi = math.floor, math.ceil, math.min, math.max, math.sin, math.pi;
local fmt = string.format;
local M = {};                                       -- module table (returned at the end)
-- PartyramaXI additions in one table (RecastXI's top level is near LuaJIT's 200-local limit):
-- alias = settings file config\addons\partyramaxi\<character>\recast.lua, path = addons\partyramaxi\recast (set at load)
local X = { alias = 'recast', path = '', draw = require('pxidraw') };

--[[ ------------------------------------------------------------------ settings ]]
local default_settings = T{
    x = 200, y = 200, width = 320, locked = false,
    theme = 'Dragoon Forever', dragoon_palette = 'Drachen',
    font = 'Theme default', font_size = 15, opacity = 0.92, bar_height = 5,
    show_bars = true, header_texture = true, glow = true, glow_strength = 0.7, texture_strength = 0.6,
    crest_source = 'theme', crest_file = 'crests\\default.png', crest_per_job = true, crest_size = 34, crest_mask = 'circle',
    icons = true, icon_size = 22, icon_pack = 'default',
    idle_mode = 'collapse', animate = true, anim_speed = 1.0, row_motion = true,
    ready_flash = true, flash_secs = 2.0, flash_style = 'fill', flash_strength = 0.8,
    compact = false, pin_tint = true, gold_tenths = true,
    fs_scale = 1.0, fs_job = 0, fs_group = 0, fs_name = 0, fs_time = 0, fs_badge = 0, fs_idle = 0, fs_perf = 0,
    keep_pinned = false, hide_idle_pinned = false, drop_pack = '', drop_pack2 = '', ready_custom = false, ready_rgb = T{ 255, 220, 120 },
    max_spells = 12, max_abilities = 10, max_total = 0, sp_display = 'header',
    collapsible = true, sp_hover = true, sp_show_time = true, sp2_mode = 'auto', per_sub = false, safe_mode = false, safe_start_done = true,
    enabled = true,                                     -- PartyramaXI: the Recasts tab's Enabled button
    attach = true, attach_gap = 20, frame_src = 'own',  -- attached above the party list (gap px); frame: own theme or the party list's background and border
    profiles = T{}, collapsed = T{ spells = false, abilities = false },
    units_ability = 60, units_spell = 60,
    hide_cutscene = true,
    hide_no_combat = false,
    hide_header = false,                                -- PartyramaXI: draw only the rows (no header bar)
    hide_job_text = false,                              -- PartyramaXI: the header without its job / level line
    quick_menu = true,                                  -- header Pinned Abilities button (on hover), right-click menus
    mp_check = true, nomp_rgb = T{ 110, 165, 255 },     -- 'Not enough MP' in spell rows and its color
    bastok_style = 'works', windurst_style = 'tower', dragoon_style = 'keeled',     -- header texture styles (see rxthemes.STYLE_LIST)
    -- polish effects (see rxfx.lua); safe drawing turns them all off
    fx_level = 'full', fx_ping_style = 'border', fx_strength = 0.7, fx_shine_period = 5.0,
    fx_spark_size = 0.55, fx_spark_strength = 0.35, fx_gloss = true, fx_shine = true, fx_spark = true, fx_heat = true, fx_sweep = true, fx_ping = true,
};
-- PartyramaXI: the shipped defaults (the author's RecastXI settings, pxibase.lua) over the ones above
do
    local ok, base = pcall(require, 'pxibase');
    if (rawget(_G, 'HPP_NO_BASE')) then ok = false; end
    if (ok and type(base) == 'table' and base.apply) then base.apply(default_settings, base.recast, T); end
end
-- numeric ranges { min, max, integer }
local RANGES = {
    x = { -10000, 20000, true }, y = { -10000, 20000, true }, width = { 200, 640, true },
    font_size = { 10, 36, true }, opacity = { 0.2, 1.0 }, bar_height = { 2, 16, true },
    crest_size = { 20, 72, true }, icon_size = { 16, 60, true }, anim_speed = { 0.25, 4.0 },
    glow_strength = { 0.05, 1.0 }, texture_strength = { 0.05, 1.0 },
    flash_secs = { 0.5, 10.0 }, units_ability = { 1, 60, true }, units_spell = { 1, 60, true },
    flash_strength = { 0.1, 1.0 }, fs_scale = { 0.5, 2.0 }, fx_strength = { 0.1, 1.0 }, fx_spark_size = { 0.1, 1.0 }, fx_spark_strength = { 0.1, 1.0 }, fx_shine_period = { 2.0, 12.0 },
    fs_job = { 0, 36, true }, fs_group = { 0, 36, true }, fs_name = { 0, 36, true },
    fs_time = { 0, 36, true }, fs_badge = { 0, 36, true }, fs_idle = { 0, 36, true }, fs_perf = { 0, 36, true },
    attach_gap = { 20, 600, true },
    max_spells = { 0, 50, true }, max_abilities = { 0, 50, true }, max_total = { 0, 100, true },
};
-- per-element font sizes: 0 = automatic (from Font size), otherwise 8..36 px
local FS_KEYS = { fs_job = true, fs_group = true, fs_name = true, fs_time = true, fs_badge = true, fs_idle = true, fs_perf = true };
local FS_MIN, FS_MAX = 8, 36;
-- settings that existed in earlier versions (dropped with a chat note)
local OBSOLETE = { fs_title = 'v1.3.0: the header has no title text any more' };
-- choices: lower-case input -> stored value
local ENUMS = {
    dragoon_palette = { drachen = 'Drachen', wyrm = 'Wyrm' },
    crest_source = { theme = 'theme', job = 'job', custom = 'custom', none = 'none' },
    crest_mask = { circle = 'circle', square = 'square', none = 'none' },
    idle_mode = { collapse = 'collapse', hide = 'hide', show = 'show' },
    sp2_mode = { auto = 'auto', always = 'always', never = 'never' },
    flash_style = { fill = 'fill', outline = 'outline', both = 'both' },
    sp_display = { header = 'header', list = 'list' },
    bastok_style = { works = 'works', mines = 'mines', brushed = 'brushed', rust = 'rust', rivets = 'rivets', white = 'white' },
    windurst_style = { tower = 'tower', sea = 'sea', cloth = 'cloth' },
    dragoon_style = { keeled = 'keeled', scales = 'scales' },
    fx_level = { off = 'off', subtle = 'subtle', full = 'full' },
    fx_ping_style = { border = 'border', swipe = 'swipe', both = 'both' },
    frame_src = { own = 'own', list = 'list' },
};
local UNITS_OK = { [1] = true, [60] = true };

local function show(v) if (type(v) == 'string') then return "'" .. v .. "'"; end return tostring(v); end
local function copy_default(d)
    if (type(d) ~= 'table') then return d; end
    local r = T{}; for k, v in pairs(d) do r[k] = copy_default(v); end return r;
end

--[[
* Validates a settings table in place. Returns a list of human-readable fixes.
--]]
local function validate_settings(s)
    local bad = {};
    if (type(s) ~= 'table') then return bad; end
    local keys = {};
    for k in pairs(s) do keys[#keys + 1] = k; end
    table.sort(keys, function (a, b) return tostring(a) < tostring(b); end);
    for _, k in ipairs(keys) do
        if (default_settings[k] == nil) then
            s[k] = nil;
            bad[#bad + 1] = tostring(k) .. (OBSOLETE[k] and (': obsolete setting removed (' .. OBSOLETE[k] .. ')') or ': unknown key removed');
        end
    end
    keys = {};
    for k in pairs(default_settings) do keys[#keys + 1] = k; end
    table.sort(keys);
    for _, k in ipairs(keys) do
        local d, v = default_settings[k], s[k];
        local td = type(d);
        if (v == nil) then
            s[k] = copy_default(d); bad[#bad + 1] = k .. ': missing, set to ' .. show(d);
        elseif (td == 'number') then
            local n = (type(v) == 'string') and tonumber(v) or v;
            if (type(n) ~= 'number' or n ~= n or n == math.huge or n == -math.huge) then
                s[k] = d; bad[#bad + 1] = k .. ': ' .. show(v) .. ' is not a number, reset to ' .. show(d);
            else
                local r, m = RANGES[k], n;
                if (r ~= nil) then
                    if (r[3]) then m = floor(m + 0.5); end
                    if (m < r[1]) then m = r[1]; elseif (m > r[2]) then m = r[2]; end
                end
                if ((k == 'units_ability' or k == 'units_spell') and not UNITS_OK[m]) then m = d; end
                if (FS_KEYS[k] and m > 0 and m < FS_MIN) then m = FS_MIN; end
                s[k] = m;
                if (type(v) ~= 'number') then bad[#bad + 1] = k .. ': text ' .. show(v) .. ' read as ' .. show(m);
                elseif (m ~= n) then bad[#bad + 1] = k .. ': ' .. show(n) .. ' not allowed, set to ' .. show(m); end
            end
        elseif (td == 'boolean') then
            if (type(v) ~= 'boolean') then
                local l = (type(v) == 'string') and v:lower() or nil;
                if (l == 'true' or v == 1) then s[k] = true; bad[#bad + 1] = k .. ': ' .. show(v) .. ' read as true';
                elseif (l == 'false' or v == 0) then s[k] = false; bad[#bad + 1] = k .. ': ' .. show(v) .. ' read as false';
                else s[k] = d; bad[#bad + 1] = k .. ': ' .. show(v) .. ' is not true/false, reset to ' .. show(d); end
            end
        elseif (td == 'string') then
            if (type(v) ~= 'string') then
                s[k] = d; bad[#bad + 1] = k .. ': ' .. show(v) .. ' is not text, reset to ' .. show(d);
            elseif (ENUMS[k] ~= nil) then
                local c = ENUMS[k][v:lower()];
                if (c == nil) then s[k] = d; bad[#bad + 1] = k .. ': ' .. show(v) .. ' is not a valid choice, reset to ' .. show(d);
                elseif (c ~= v) then s[k] = c; end
            elseif (k == 'theme') then
                local t = themes.find(v);
                if (t == nil) then s[k] = d; bad[#bad + 1] = k .. ': unknown theme ' .. show(v) .. ', reset to ' .. show(d);
                elseif (t.name ~= v) then s[k] = t.name; end
            elseif (k == 'font' and v == '') then
                s[k] = d; bad[#bad + 1] = 'font: empty, reset to ' .. show(d);
            end
        elseif (k == 'profiles') then
            if (type(v) ~= 'table') then s[k] = T{}; bad[#bad + 1] = 'profiles: not a table, reset (filters and pins cleared)';
            else
                local n = prof.validate(v);
                if (n > 0) then bad[#bad + 1] = 'profiles: ' .. n .. ' bad filter/pin entr' .. (n == 1 and 'y' or 'ies') .. ' removed'; end
            end
        elseif (k == 'ready_rgb' or k == 'nomp_rgb') then
            local okc = type(v) == 'table';
            if (okc) then for i = 1, 3 do local c = v[i]; if (type(c) ~= 'number' or c ~= c) then okc = false; end end end
            if (not okc) then s[k] = copy_default(d); bad[#bad + 1] = k .. ': not three numbers, reset to the default';
            else
                for i = 1, 3 do local c = floor(v[i] + 0.5); if (c < 0) then c = 0; elseif (c > 255) then c = 255; end v[i] = c; end
                for kk in pairs(v) do if (kk ~= 1 and kk ~= 2 and kk ~= 3) then v[kk] = nil; end end
            end
        elseif (k == 'collapsed') then
            if (type(v) ~= 'table') then s[k] = copy_default(d); bad[#bad + 1] = 'collapsed: not a table, reset';
            else
                for kk in pairs(v) do if (kk ~= 'spells' and kk ~= 'abilities') then v[kk] = nil; end end
                for _, g in ipairs({ 'spells', 'abilities' }) do
                    if (type(v[g]) ~= 'boolean') then v[g] = false; bad[#bad + 1] = 'collapsed.' .. g .. ': not true/false, reset'; end
                end
            end
        end
    end
    return bad;
end

--[[ ------------------------------------------------------------------ runtime ]]
local rt = {
    s = nil, frame = 0, now = 0, next_scan = 0, place = true, dirty_at = nil,
    cfg = { false }, test = false, th = nil, th_name = nil, th_pal = nil,
    fonts_key = nil, f_title = nil, f_body = nil, f_num = nil, default_font = nil, font_list = nil,
    vis = list.tween(1), pad = list.tween(0), idle_tw = list.tween(0),
    opt = { animate = true, speed = 1, row_motion = true, flash = true, flash_secs = 2 },
    prof = nil, prof_key = nil, prof_sig = -1,
    body_bottom = 0, known = nil, known_sig = -1, by_key = {}, search = { '' }, crest_buf = { '' },
    crest_list = nil, icon_counts = nil, packs = nil,
    subtitle = '', sub_sig = -1, problems = {},
    clock = nil, clock_name = '?', origin_x = 0, origin_y = 0, win_w = 0, win_h = 0, header_only = false,
    hover_sp = 0, tip = { '', '' }, tip_sec = { -1, -1 }, badge_rect = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } },
    busy = 0, idle = true, idle_settled = true, hidden = false, cutscene = false, nocombat = false,
    pinned_rows = 0, caps = { spells = 0, abilities = 0, total = 0 },
    pins_sp = { n = 0 }, pins_ab = { n = 0 }, names = {},
};
rt._validate_settings = validate_settings;
local MARGIN = 12;  -- room for the outer glow (themes.GLOW_SIZE) inside the (background-less) window

local function msg(s) print(chat.header(addon.name):append(chat.message('RecastXI: ' .. s))); end
local function err(s) print(chat.header(addon.name):append(chat.error('RecastXI: ' .. s))); end
local function mark_dirty() rt.dirty_at = rt.now; end
-- /pxi recast perf (v1.1.1): one upvalue check per section when off
local perf_on = false;
local PF_cur = PF.cur;

local function check_settings()
    local bad = validate_settings(rt.s);
    rt.problems = bad;
    if (#bad > 0) then
        err('Fixed invalid settings (hand edit?): ' .. table.concat(bad, '; ') .. '.');
        settings.save(X.alias);
    end
end

local function pack_base(name)
    if (type(name) ~= 'string') then return nil; end
    name = name:gsub('[\\/]+$', '');
    local base = name:match('([^\\/]+)$');
    if (base == nil or base == '' or base == '.' or base == '..') then return nil; end
    return base;
end

-- Every subfolder of icons\drop is a selectable pack (blackFFXIIcons, whiteFFXIIcons, ...).
-- list_drop_packs() is merged in, but a hash-style return or a layout filter must not hide folders.
local function scan_drop_folders()
    local root = icons.drop_root;
    local out, seen = {}, {};
    local function add(name)
        local base = pack_base(name);
        if (base == nil) then return; end
        local k = base:lower();
        if (seen[k]) then return; end
        seen[k] = true;
        out[#out + 1] = base;
    end
    if (type(root) == 'string' and root ~= '' and ashita ~= nil and ashita.fs ~= nil and ashita.fs.get_dir ~= nil) then
        root = root:gsub('[\\/]+$', '');
        -- one argument: folders only (Ashita). A folder of PNGs has no child folders, so get_dir
        -- on it returns an empty table; get_dir on a file does not. That is how png packs are kept.
        local ok, dirs = pcall(ashita.fs.get_dir, root);
        if (ok and type(dirs) == 'table') then
            for _, name in ipairs(dirs) do
                local base = pack_base(name);
                if (base ~= nil) then
                    local child = root .. '\\' .. base;
                    local okd, listing = pcall(ashita.fs.get_dir, child);
                    if (okd and type(listing) == 'table') then add(base); end
                end
            end
            if (#out == 0) then
                for _, name in pairs(dirs) do
                    if (type(name) == 'string') then add(name); end
                end
            end
        end
    end
    if (icons.list_drop_packs ~= nil) then
        local ok, listed = pcall(icons.list_drop_packs);
        if (ok and type(listed) == 'table') then
            local n = 0;
            for _, name in ipairs(listed) do add(name); n = n + 1; end
            if (n == 0) then
                for k, v in pairs(listed) do
                    if (type(v) == 'string') then add(v);
                    elseif (type(k) == 'string') then add(k); end
                end
            end
        end
    end
    table.sort(out, function (a, b) return a:lower() < b:lower(); end);
    return out;
end

local function apply_settings()
    local s = rt.s;
    data.units.ability, data.units.spell = s.units_ability, s.units_spell;
    data.sp2_mode = s.sp2_mode;
    data.sp_rows = s.sp_display == 'list';
    data.update_sp_shown();
    icons.set_base(X.path, s.icon_pack);
    -- v1.3.1: a missing pack still falls back to loose files, but a real subfolder of
    -- icons\drop is kept even if find_drop_pack does not recognise its layout.
    local dp = icons.find_drop_pack(s.drop_pack);
    if (dp == nil and type(s.drop_pack) == 'string' and s.drop_pack ~= '') then
        local want = s.drop_pack:lower();
        for _, name in ipairs(scan_drop_folders()) do
            if (name:lower() == want) then dp = name; break; end
        end
    end
    -- PartyramaXI 1.0.0: a saved pack that is not installed (icon packs do not ship) quietly uses what a new install
    -- has: the icons that come with the addon. The choice is kept, so it comes back once the pack is copied in and
    -- Rescan is pressed (the Icons tab marks it "not installed").
    rt.dp_missing, rt.dp2_missing = nil, nil;
    if (dp == nil) then rt.dp_missing = s.drop_pack; dp = ''; end
    icons.set_drop_pack(dp);
    local dp2 = icons.find_drop_pack(s.drop_pack2);
    if (dp2 == nil) then rt.dp2_missing = s.drop_pack2; dp2 = ''; end
    icons.set_drop_pack2(dp2);
    rt.th_name, rt.fonts_key, rt.prof_sig, rt.known_sig = nil, nil, -1, -1;
    rt.crest_buf[1] = s.crest_file;
    rt.place = true;
end

-- Wall clock. imgui.GetTime is a plain number (no allocation); os.clock is the fallback.
local function make_clock()
    if (type(imgui.GetTime) == 'function') then
        local ok, v = pcall(imgui.GetTime);
        if (ok and type(v) == 'number') then return imgui.GetTime, 'imgui.GetTime'; end
    end
    return os.clock, 'os.clock';
end

--[[ ------------------------------------------------------------------ caches ]]
local TENTHS = {};
for i = 0, 99 do TENTHS[i] = fmt('%.1f', i / 10); end
local TIMES = {};
local function time_str(t, tenths)
    if (tenths and t < 10) then
        local i = floor(t * 10); if (i < 0) then i = 0; elseif (i > 99) then i = 99; end
        return TENTHS[i], true;
    end
    local n = ceil(t - 0.001);
    local str = TIMES[n];
    if (str == nil) then
        if (n >= 3600) then str = fmt('%d:%02d:%02d', floor(n / 3600), floor(n / 60) % 60, n % 60);
        else str = fmt('%d:%02d', floor(n / 60), n % 60); end
        TIMES[n] = str;
    end
    return str, false;
end
rt._time_str = time_str;
local COUNTS = {};
local function count_str(n) local c = COUNTS[n]; if (c == nil) then c = tostring(n); COUNTS[n] = c; end return c; end
local INITIAL = {};
local function initial_of(name)
    if (name == nil) then return '?'; end
    local c = INITIAL[name];
    if (c == nil) then c = (name or '?'):sub(1, 1):upper(); INITIAL[name] = c; end
    return c;
end

-- Preallocated ImVec2 tables for ImGui calls.
local V_SIZE, V_POS, V_DUMMY, V_BTN, V_CUR, V_HA, V_HB = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 };
local V_ZERO = { 0, 0 };

local function xy(a, b)
    local ta = type(a);
    if (ta == 'table' or ta == 'userdata') then return a.x or a[1] or 0, a.y or a[2] or 0; end
    return a or 0, b or 0;
end

--[[ ------------------------------------------------------------------ fonts ]]
local font_depth = 0;
local function push_font(f, size)
    local ff = f or rt.default_font;
    if (ff == nil or imgui.PushFont == nil) then return; end
    imgui.PushFont(ff, size);
    font_depth = font_depth + 1;
end
local function pop_font()
    if (font_depth > 0) then imgui.PopFont(); font_depth = font_depth - 1; end
end
-- Loads the fonts for the current theme/font choice. Called at frame start only.
--[[
* Text width cache (v1.2.0): font -> size -> string -> width. Measured once with the font pushed
* (CalcTextSize), then reused every frame; cleared when the fonts are reloaded. Keys are cached
* strings (time strings, names, labels), so the cache stays small.
--]]
local WCACHE = {};
local FONT_NIL = {};
rt.measures = 0;
local function text_w(font, size, str)
    local bf = WCACHE[font or FONT_NIL];
    if (bf == nil) then bf = {}; WCACHE[font or FONT_NIL] = bf; end
    local t = bf[size];
    if (t == nil) then t = {}; bf[size] = t; end
    local w = t[str];
    if (w == nil) then
        push_font(font, size);
        w = xy(imgui.CalcTextSize(str));
        pop_font();
        t[str] = w;
        rt.measures = rt.measures + 1;
    end
    return w;
end
rt.text_w = text_w;
-- Shortens str with '...' to fit avail px (nil when not even a stub fits). Called only when a name's
-- fit changes; the result is cached on the row, so overlong names cost no clip rect per frame.
local function ellipsize(font, size, str, avail)
    local ew = text_w(font, size, '...');
    if (avail <= ew) then return nil; end
    local n = #str;
    local k = floor(n * (avail - ew) / max(1, text_w(font, size, str)));
    if (k > n - 1) then k = n - 1; end
    local out = str:sub(1, k);
    while (k > 0 and text_w(font, size, out) + ew > avail) do k = k - 1; out = str:sub(1, k); end
    out = (out:gsub('%s+$', ''));
    if (out == '') then return nil; end
    return out .. '...';
end
local function clear_widths() WCACHE = {}; rt.wgen = (rt.wgen or 0) + 1; end

local function update_fonts()
    local s = rt.s;
    if (rt.fonts_key == s.font and rt.fonts_theme == s.theme) then return; end
    rt.fonts_key, rt.fonts_theme = s.font, s.theme;
    clear_widths();
    rt.f_title, rt.f_body, rt.f_num = nil, nil, nil;
    if (rt.default_font == nil and imgui.GetFont ~= nil) then
        local ok, f = pcall(imgui.GetFont); if (ok) then rt.default_font = f; end
    end
    if (s.font == fonts.DEFAULT) then return; end
    local dir = (X.path or ''):gsub('[\\/]+$', '') .. '\\fonts\\';
    if (s.font == fonts.THEME) then
        local tf = (themes.find(s.theme) or themes.find(themes.DEFAULT)).fonts;
        rt.f_title = fonts.load(dir .. tf.title, 16);
        rt.f_body  = fonts.load(dir .. tf.body, 16);
        rt.f_num   = fonts.load(dir .. tf.num, 16);
        return;
    end
    rt.font_list = rt.font_list or fonts.scan(X.path);
    local f = fonts.find(rt.font_list, s.font);
    if (f == nil or f.path == nil) then
        err('Font ' .. show(s.font) .. ' not found; using the theme fonts.');
        s.font = fonts.THEME; rt.fonts_key = nil; mark_dirty();
        return;
    end
    rt.f_body = fonts.load(f.path, 16);
    rt.f_title = f.bold_path and fonts.load(f.bold_path, 16) or rt.f_body;
    rt.f_num = rt.f_title;
end

--[[ ------------------------------------------------------------------ profile / job ]]
local function current_profile(create)
    local st = data.state;
    local sig = st.job_sig * 2 + (rt.s.per_sub and 1 or 0);
    if (create or sig ~= rt.prof_sig or rt.prof_ver ~= prof.version or rt.prof_tbl ~= rt.s.profiles) then
        rt.prof_sig, rt.prof_ver, rt.prof_tbl = sig, prof.version, rt.s.profiles;
        rt.prof_key = prof.key(rt.s, data.job_abbr(st.main), data.job_abbr(st.sub));
        rt.prof = create and prof.get(rt.s, rt.prof_key, true) or prof.peek(rt.s, rt.prof_key);
    elseif (rt.prof == nil) then
        rt.prof = prof.peek(rt.s, rt.prof_key);
    end
    return rt.prof;
end
local function edit_profile()
    local p = prof.get(rt.s, rt.prof_key or data.job_abbr(data.state.main), true);
    rt.prof = p;
    return p;
end
local function subtitle()
    local st = data.state;
    if (rt.sub_sig ~= st.job_sig or rt.sub_test ~= st.test) then
        rt.sub_sig, rt.sub_test = st.job_sig, st.test;
        if (st.main == 0 and st.test) then rt.subtitle = 'Test mode';
        elseif (st.sub ~= 0) then rt.subtitle = fmt('%s%d / %s%d', data.job_abbr(st.main), st.mainlv, data.job_abbr(st.sub), st.sublv);
        else rt.subtitle = fmt('%s%d', data.job_abbr(st.main), st.mainlv); end
        if (st.test and st.main ~= 0) then rt.subtitle = rt.subtitle .. '  (test)'; end
    end
    return rt.subtitle;
end

--[[ ------------------------------------------------------------------ cutscene detection ]]
--[[
* Same approach other Ashita addons use: the client keeps an "event system active" flag that is set
* during cutscenes and NPC events. The signature is resolved once at load; each frame costs two
* memory reads. If the signature is not found (different client build), the local player's entity
* status is used instead (status 4 = event). /pxi recast cutscene shows which source is in use.
--]]
local EVENT_SIG = 'A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3';
local ev = { ptr = 0, party = nil, entity = nil };

local function find_event_flag()
    ev.ptr = 0;
    if (ashita == nil or ashita.memory == nil or ashita.memory.find == nil) then return; end
    local ok, p = pcall(ashita.memory.find, 'FFXiMain.dll', 0, EVENT_SIG, 0, 0);
    if (ok and type(p) == 'number' and p ~= 0) then ev.ptr = p; end
end

local function in_cutscene()
    if (ev.ptr ~= 0) then
        local base = ashita.memory.read_uint32(ev.ptr + 1);
        return base ~= 0 and ashita.memory.read_uint8(base) == 1;
    end
    -- fallback: local player entity status 4 (Event)
    if (ev.party == nil or ev.entity == nil) then
        local mm = AshitaCore:GetMemoryManager();
        ev.party, ev.entity = mm:GetParty(), mm:GetEntity();
        if (ev.party == nil or ev.entity == nil) then return false; end
    end
    local idx = ev.party:GetMemberTargetIndex(0);
    if (idx == nil or idx == 0) then return false; end
    return ev.entity:GetStatus(idx) == 4;
end


--[[ ------------------------------------------------------------------ combat detection ]]
--[[
* Optional "hide when not in battle": the tracker counts as "in battle" while any party member is
* engaged (status 1), or any living monster within 50 yalms is claimed by a party member, and for
* COMBAT_HOLD seconds afterwards so it does not flicker between kills. Scanned at 2 Hz, only while
* the option is on.
--]]
local COMBAT_HOLD, COMBAT_RANGE2 = 6, 50 * 50;
local cb_state = { at = -10, last_true = -100, res = false };

local function scan_combat()
    local mm = AshitaCore:GetMemoryManager();
    local party, ent = mm:GetParty(), mm:GetEntity();
    if (party == nil or ent == nil) then return false; end
    local ids, n = {}, 0;
    for i = 0, 5 do
        if (party:GetMemberIsActive(i) == 1) then
            local idx = party:GetMemberTargetIndex(i);
            if (idx ~= nil and idx ~= 0 and ent:GetStatus(idx) == 1) then return true; end
            local sid = party:GetMemberServerId(i);
            if (sid ~= nil and sid ~= 0) then n = n + 1; ids[sid] = true; ids[bit.band(sid, 0xFFFF)] = true; end
        end
    end
    if (n == 0) then return false; end
    for i = 1, 0x3FF do
        local claim = ent:GetClaimStatus(i);
        if (claim ~= nil and claim ~= 0 and (ids[claim] or ids[bit.band(claim, 0xFFFF)])
            and ent:GetHPPercent(i) > 0 and bit.band(ent:GetSpawnFlags(i), 0x10) ~= 0) then
            local d = ent:GetDistance(i);
            if (d ~= nil and d < COMBAT_RANGE2) then return true; end
        end
    end
    return false;
end

local function in_combat(now)
    if (now - cb_state.at >= 0.5) then
        cb_state.at = now;
        local ok, r = pcall(scan_combat);
        if (ok and r) then cb_state.last_true = now; end
    end
    return (now - cb_state.last_true) < COMBAT_HOLD;
end

--[[ ------------------------------------------------------------------ main window ]]
local function flag(name, fallback) local v = rawget(_G, name); if (type(v) ~= 'number') then v = fallback; end return v; end
local WF = nil;
local G = {};   -- lazily resolved ImGui constants (see render_main)
local function window_flags(locked)
    if (WF == nil) then
        WF = bit.bor(flag('ImGuiWindowFlags_NoTitleBar', 1), flag('ImGuiWindowFlags_NoResize', 2),
                     flag('ImGuiWindowFlags_NoScrollbar', 8), flag('ImGuiWindowFlags_NoCollapse', 32),
                     flag('ImGuiWindowFlags_NoBackground', 128), flag('ImGuiWindowFlags_NoSavedSettings', 256),
                     flag('ImGuiWindowFlags_NoFocusOnAppearing', 4096), flag('ImGuiWindowFlags_NoNav', 0));
        rt.WF_LOCK = bit.bor(WF, flag('ImGuiWindowFlags_NoMove', 4));
    end
    return locked and rt.WF_LOCK or WF;
end

--[[ Layout metrics (recomputed each frame from settings; numbers only).
* v1.1.0: everything scales with font size (up to 36), icon size (60), bar height (16) and crest
* size (72): rows center their text+bar block, the header grows to fit the crest, the title block
* and the stacked SP badges, and the window widens (never narrower than the user's width) so the
* title, badges and time column never clip or overlap.
--]]
local L = {};
local TIME_PROBE = '0:00:00';
local NA_TEXT, READY_TEXT, IDLE_TEXT, MP_TEXT = 'Not available', 'Ready', 'All recasts ready', 'Not enough MP';
-- effective font size of one element: own slider (or the automatic size) x master scale, 8..36
local function fsz(v, auto, scale)
    local x = floor(((v > 0) and v or auto) * scale + 0.5);
    if (x < FS_MIN) then x = FS_MIN; elseif (x > FS_MAX) then x = FS_MAX; end
    return x;
end
local function sp_label(i) local sp = data.state.sp[i]; return (sp.name ~= '' and sp.name) or ((i == 1) and 'SP1' or 'SP2'); end
local function layout()
    local s = rt.s;
    local st = data.state;
    local base, sc = s.font_size, s.fs_scale;
    local fs = fsz(0, base, sc);
    L.fs = fs;
    L.pad = max(10, floor(fs * 0.6));
    local cs = s.crest_size;
    if (s.crest_source == 'none') then cs = 0;
    elseif (s.compact) then cs = floor(cs * 0.75 + 0.5); end
    L.cs = cs;
    -- v1.2.0: per-element font sizes (0 = automatic) with a master scale, all clamped to 8..36
    -- v1.3.0: no title text; the job line is the header text (title font)
    L.ssize = fsz(s.fs_job, base * (s.compact and 0.9 or 1.0), sc);
    L.gfs = fsz(s.fs_group, base * 0.78, sc);
    L.nfs = fsz(s.fs_name, base, sc);
    L.tfs = fsz(s.fs_time, base, sc);
    L.ifs = fsz(s.fs_idle, base, sc);
    L.pfs = fsz(s.fs_perf, 13, sc);
    L.text_h = max(L.nfs, L.tfs);
    L.nafs = max(FS_MIN, floor(min(L.nfs, L.tfs) * 0.85 + 0.5));
    -- SP badges: stacked embossed rectangles at the right of the header
    L.bf = fsz(s.fs_badge, max(9, base * 0.72), sc);
    L.bh_b = L.bf + 6;
    L.nb = (st.sp[1].shown and 1 or 0) + (st.sp[2].shown and 1 or 0);
    local bw = 0;
    for i = 1, 2 do
        if (st.sp[i].shown) then
            local w = text_w(rt.f_body, L.bf, sp_label(i));
            if (s.sp_show_time) then w = w + 6 + text_w(rt.f_num, L.bf, TIME_PROBE); end
            if (w > bw) then bw = w; end
        end
    end
    L.bw = (L.nb > 0) and (bw + 14) or 0;
    local stack = (L.nb > 0) and (L.nb * L.bh_b + (L.nb - 1) * 3) or 0;
    L.hh = max(cs + (s.compact and 8 or 12), L.ssize + (s.compact and 10 or 16), stack + 10);
    -- v1.3.0: the slider always wins (compact used to clamp icons to font size + 3 px, so the
    -- slider seemed dead above ~18 px); every row has the same pin gutter and icon slot
    L.isz = s.icons and s.icon_size or 0;
    L.gut = 10;                                         -- pin marker gutter (always reserved)
    L.slot_x = L.gut;                                   -- icon slot, relative to the row's left edge
    L.name_x = L.gut + ((L.isz > 0) and (L.isz + 7) or 0);
    if (s.ready_custom) then local c = s.ready_rgb; L.ready = D.rgba(c[1], c[2], c[3], 255); else L.ready = nil; end
    do local c = s.nomp_rgb; L.nomp = D.rgba(c[1], c[2], c[3], 255); end
    L.bh = s.show_bars and s.bar_height or 0;
    local th_ = L.text_h;
    if (s.compact) then
        L.row_h = max(th_ + 7, L.isz + 4);
        L.block = th_;
    else
        L.block = th_ + (s.show_bars and (6 + L.bh) or 0);
        L.row_h = max(L.isz + 8, L.block + 10);
    end
    L.gh = floor(L.gfs + 10);
    L.more_h = floor(L.gfs + 8);
    L.idle_h = max(L.row_h, L.ifs + 10);
    L.gap = 4;
    -- row time strings are re-measured only when the font or the time size changes
    local tk = ((rt.wgen or 0) * 64 + L.tfs) * 64 + L.nafs;
    if (tk ~= L.tkey) then L.tkey = tk; L.tgen = (L.tgen or 0) + 1; end
    -- minimum width: header (crest + title + badges) and a row (icon + some name + time column)
    local sub_w = s.hide_job_text and 0 or text_w(rt.f_title, L.ssize, subtitle());
    local crest_w = (cs > 0) and (cs + 10) or 0;
    local head_min = L.pad + crest_w + sub_w + 12 + L.bw + L.pad;
    local time_w = max(text_w(rt.f_num, L.tfs, TIME_PROBE), text_w(rt.f_body, L.nafs, NA_TEXT), text_w(rt.f_body, L.nafs, MP_TEXT));
    local row_min = 2 * L.pad + L.name_x + L.nfs * 4 + 6 + time_w;
    L.min_w = floor(max(head_min, row_min) + 0.5);
    L.w = max(s.width, L.min_w);
end

local function draw_crest(th, cx, cy)
    local s, cs = rt.s, L.cs;
    if (s.crest_source == 'none' or cs <= 0) then return; end
    local r = cs / 2;
    if (s.crest_source == 'custom') then
        local path = icons.crest_path_cached(s, data.job_abbr(data.state.main));
        local tex = path and icons.texture(path, rt.frame) or nil;
        if (tex ~= nil) then
            local round = (s.crest_mask == 'circle') and r or ((s.crest_mask == 'square') and 4 or 0);
            if (s.crest_mask ~= 'none') then D.circlef(cx, cy, r + 2, th.u.glow2, 24); end
            D.image(tex, cx - r, cy - r, cx + r, cy + r, round);
            if (s.crest_mask == 'circle') then D.circle(cx, cy, r, th.u.border, 24, 1.5);
            elseif (s.crest_mask == 'square') then D.rect(cx - r, cy - r, cx + r, cy + r, th.u.border, 4, 1.5); end
            return;
        end
    elseif (s.crest_source == 'job') then
        local u = th.u;
        D.circlef(cx, cy, r + 2, u.glow2, 24);
        D.circlef(cx, cy, r, u.hd2, 24);
        D.circle(cx, cy, r, u.border, 24, 2);
        D.circle(cx, cy, r - 3, u.border_soft, 24, 1);
        local abbr = data.job_abbr(data.state.main);
        local jf = max(9, floor(cs * 0.36));
        local tw = text_w(rt.f_title, jf, abbr);
        push_font(rt.f_title, jf);
        D.text(cx - tw / 2, cy - jf / 2, u.text, abbr);
        pop_font();
        return;
    end
    themes.draw_crest(th, cx, cy, r * 0.92);
end

--[[
* SP1 / SP2 badges (v1.1.0): rectangles with the ability name, no symbols.
*   ready       accent fill, bright text, soft glow
*   cooldown    grey, muted text, optional small muted time
*   unavailable grey, muted text, no time (e.g. 'Always show SP2' below level 96) - never 'ready'
--]]
local function sp_badges(th, w, hh)
    local u, s = th.u, rt.s;
    rt.hover_sp = 0;
    if (L.nb == 0) then return w - L.pad; end
    local bx1 = w - L.pad;
    local bx0 = bx1 - L.bw;
    local stack = L.nb * L.bh_b + (L.nb - 1) * 3;
    local y = floor((hh - stack) / 2);
    for i = 1, 2 do
        local sp = data.state.sp[i];
        if (sp.shown) then
            local state = data.sp_state(i, rt.now);
            local y1 = y + L.bh_b;
            local label = sp_label(i);
            local ty = y + floor((L.bh_b - L.bf) / 2);
            local cooldown_time = (state == 'cooldown' and s.sp_show_time);
            local tw = text_w(rt.f_body, L.bf, label);
            if (state == 'ready') then
                if (s.safe_mode) then
                    -- /pxi recast safe: flat badge, no glow/bevel/sheen/glint
                    D.rectf(bx0, y, bx1, y1, u.badge_on_fill, 2);
                    D.rect(bx0, y, bx1, y1, u.acc_sp, 2, 1);
                else
                    -- embossed (v1.1.1 look, restored in v1.3.0): soft glow, gradient fill, specular
                    -- sheen, rim, top highlight, bottom shadow, slow glint
                    D.rect(bx0 - 2, y - 2, bx1 + 2, y1 + 2, u.badge_on_glow2, 4, 2);
                    D.rect(bx0 - 1, y - 1, bx1 + 1, y1 + 1, u.badge_on_glow1, 3, 1.5);
                    D.vgrad(bx0, y, bx1, y1, u.badge_on_top, u.badge_on_fill);
                    local mid = y + floor((y1 - y) * 0.48);
                    D.vgrad(bx0 + 1, y + 1, bx1 - 1, mid, u.bv_sheen_top, u.bv_sheen_bot);
                    if (s.animate) then
                        local ph = ((rt.now + i * 0.7) % 6) / 1.4;
                        if (ph < 1) then
                            local bh = y1 - y;
                            local gx = bx0 - bh + (bx1 - bx0 + bh) * ph;
                            D.seg(gx, y1, gx + bh, y, u.bv_shimmer_soft, 8, bx0 + 1, y + 1, bx1 - 1, y1 - 1);
                            D.seg(gx, y1, gx + bh, y, u.bv_shimmer, 3, bx0 + 1, y + 1, bx1 - 1, y1 - 1);
                        end
                    end
                    D.rect(bx0, y, bx1, y1, u.bv_out_on, 2, 1);
                    D.rect(bx0 + 1, y + 1, bx1 - 1, y1 - 1, u.bv_rim_on, 1.5, 1);
                    D.line(bx0 + 2, y + 1.5, bx1 - 2, y + 1.5, u.bv_hi_on, 1);
                    D.line(bx0 + 2, y1 - 1.5, bx1 - 2, y1 - 1.5, u.bv_lo_on, 1);
                end
                local tx = (bx0 + bx1 - tw) / 2;
                push_font(rt.f_body, L.bf);
                D.text(tx + 1, ty + 1, u.badge_on_shadow, label);      -- contrast shadow (opposite tone)
                D.text(tx, ty, u.badge_on_text, label);
                pop_font();
            else
                -- debossed / pressed: darker at the top, inner shadow on top, faint lip below
                if (s.safe_mode) then
                    D.rectf(bx0, y, bx1, y1, u.badge_off_fill, 2);
                    D.rect(bx0, y, bx1, y1, u.badge_off_border, 2, 1);
                else
                    D.vgrad(bx0, y, bx1, y1, u.bv_off_top, u.bv_off_bot);
                    D.rect(bx0, y, bx1, y1, u.badge_off_border, 2, 1);
                    D.rect(bx0 + 1, y + 1, bx1 - 1, y1 - 1, u.bv_rim_off, 1.5, 1);
                    D.line(bx0 + 2, y + 1.5, bx1 - 2, y + 1.5, u.bv_off_inner, 1);
                    D.line(bx0 + 2, y1 - 0.5, bx1 - 2, y1 - 0.5, u.bv_off_lip, 1);
                end
                local tx = cooldown_time and (bx0 + 7) or ((bx0 + bx1 - tw) / 2);
                push_font(rt.f_body, L.bf);
                D.text(tx, ty + 1, u.badge_off_outline, label);         -- dark outline below keeps it legible
                D.text(tx, ty, u.badge_off_text, label);
                pop_font();
                if (cooldown_time) then
                    local tstr = time_str(data.sp_remaining(i, rt.now), false);
                    local ww = text_w(rt.f_num, L.bf, tstr);
                    push_font(rt.f_num, L.bf);
                    D.text(bx1 - 7 - ww, ty + 1, u.badge_off_outline, tstr);
                    D.text(bx1 - 7 - ww, ty, u.badge_off_time, tstr);
                    pop_font();
                end
            end
            local br = rt.badge_rect[i];
            br[1], br[2], br[3], br[4], br.state = bx0, y, bx1, y1, state;
            if (s.sp_hover and imgui.IsMouseHoveringRect ~= nil) then
                V_HA[1], V_HA[2] = rt.origin_x + bx0, rt.origin_y + y;
                V_HB[1], V_HB[2] = rt.origin_x + bx1, rt.origin_y + y1;
                if (imgui.IsMouseHoveringRect(V_HA, V_HB)) then rt.hover_sp = i; end
            end
            y = y1 + 3;
        end
    end
    return bx0;
end

local function sp_tooltip()
    local i = rt.hover_sp;
    if (i == 0 or imgui.SetTooltip == nil) then return; end
    local state = data.sp_state(i, rt.now);
    local rem = data.sp_remaining(i, rt.now);
    local sec = (state == 'cooldown') and ceil(rem) or ((state == 'ready') and -2 or -3);
    if (rt.tip_sec[i] ~= sec) then
        rt.tip_sec[i] = sec;
        local slot = (i == 1) and 'SP1' or 'SP2';
        local name = sp_label(i);
        if (state == 'ready') then rt.tip[i] = fmt('%s (%s): Ready', name, slot);
        elseif (state == 'cooldown') then rt.tip[i] = fmt('%s (%s): %s left', name, slot, (time_str(rem, false)));
        else rt.tip[i] = fmt('%s (%s): not available (needs main job level %d)', name, slot, (i == 1) and 1 or data.SP2_LEVEL); end
    end
    imgui.SetTooltip(rt.tip[i]);
end

local function draw_header(th, w, hh)
    local u, s = th.u, rt.s;
    local tx = L.pad;
    if (L.cs > 0) then
        draw_crest(th, L.pad + L.cs / 2, hh / 2);
        tx = L.pad + L.cs + 10;
    end
    local right = sp_badges(th, w, hh);
    if (s.hide_job_text) then return; end
    local ssize = L.ssize;
    local sub = subtitle();
    local fits = tx + text_w(rt.f_title, ssize, sub) <= right - 6;
    local hc = (not fits) and D.clip_push(tx, 0, right - 6, hh) or false;
    if (fits or hc) then
        push_font(rt.f_title, ssize);
        D.text(tx, floor((hh - ssize) / 2), u.text, sub);
        pop_font();
    end
    if (hc) then D.clip_pop(); end
end

local function draw_pin(x, y, c, cd)
    D.circlef(x, y, 3.2, c, 10);
    D.line(x, y + 2, x, y + 7, c, 1.5);
    D.circlef(x - 0.8, y - 0.8, 1, cd, 6);
end

local function draw_icon(th, r, x, y, sz, acc)
    if (sz <= 0) then return; end
    local tex, nw, nh = icons.icon_for(r.rec, rt.frame);
    if (tex ~= nil) then
        -- v1.3.0: always scaled into the slot (aspect kept, centered), whatever the file's size
        local a0, b0, a1, b1 = icons.fit(x, y, sz, nw, nh);
        if (D.image(tex, a0, b0, a1, b1, 3)) then
            D.rect(a0, b0, a1, b1, th.u.border_soft, 3, 1);
            r.img_x0, r.img_y0, r.img_x1, r.img_y1 = a0, b0, a1, b1;
            return false;
        end
    end
    -- drawn placeholder (no file found / not loaded yet)
    local u = th.u;
    D.rectf(x, y, x + sz, y + sz, u.bg1, 3);
    D.rectf(x + 1, y + 1, x + sz - 1, y + sz - 1, (acc == u.acc_sp) and u.acc_sp_soft or u.acc_ab_soft, 3);
    D.rect(x, y, x + sz, y + sz, u.border_soft, 3, 1);
    -- the initial letter is drawn later with the other placeholder letters (one font push)
    local ini = initial_of(r.rec.name);
    local isz = floor(sz * 0.6);
    r.ini = ini;
    r.ix = x + (sz - text_w(rt.f_title, isz, ini)) / 2;
    r.iy = y + (sz - isz) / 2;
    return true;
end

--[[
* Rows (v1.2.0 rewrite for speed). Three passes per group:
*   1. geometry + backgrounds, flash, pin, icon and bar (no text)
*   2. all time texts under ONE PushFont
*   3. all names under ONE PushFont; a clip rect only when the name does not fit
* Per row the time string is re-formatted only when the displayed digits change and its width
* comes from the width cache (no CalcTextSize per frame). Values live on the pooled row tables.
--]]
local READY_KEY, NA_KEY, MP_KEY = -1000, -1001, -1002;
-- lowmp (spells only): the cast would cost more MP than you have, so the timer / Ready is replaced
local function row_time(r, rem, show_ready, avail, tenths, lowmp)
    local key;
    if (not avail and rem <= 0) then key = NA_KEY;
    elseif (lowmp) then key = MP_KEY;
    elseif (show_ready or rem <= 0) then key = READY_KEY;
    elseif (tenths and rem < 10) then local i = floor(rem * 10); if (i < 0) then i = 0; end key = -2 - i;
    else key = ceil(rem - 0.001); end
    if (key ~= r.tkey) then
        r.tkey = key;
        if (key == NA_KEY) then r.tstr, r.tgold = NA_TEXT, false;
        elseif (key == MP_KEY) then r.tstr, r.tgold = MP_TEXT, false;
        elseif (key == READY_KEY) then r.tstr, r.tgold = READY_TEXT, false;
        else r.tstr, r.tgold = time_str(rem, tenths); end
        r.tgen = nil;
    end
    if (r.tgen ~= L.tgen) then
        r.tgen = L.tgen;
        if (key == NA_KEY or key == MP_KEY) then r.tw = text_w(rt.f_body, L.nafs, r.tstr);
        else r.tw = text_w(rt.f_num, L.tfs, r.tstr); end
    end
end

local function row_pass1(th, g, r, y, w, acc, tint, soft, ranked)
    local s, u = rt.s, th.u;
    local p = r.p.v;
    r.vis = false;
    if (p <= 0.01) then return; end
    local save_alpha = D.alpha;
    local al = save_alpha * p;
    D.alpha = al;
    local dx = (s.row_motion and s.animate) and (1 - p) * 26 or 0;
    local rh = L.row_h;
    local x0 = L.pad + dx;
    local x1 = w - L.pad + dx;
    local rec = r.rec;
    local state = r.state;
    local flashing = state == 'flash';
    local pinned_idle = state == 'pinned';
    -- polish effects: how long this row has been flashing Ready (-1 when it is not)
    FX.update(s, rt.now);
    local ft = -1;
    if (flashing) then
        if (r.fx_prev ~= 'flash') then r.fx_t0 = rt.now; end
        ft = rt.now - (r.fx_t0 or rt.now);
    end
    r.fx_prev = state;
    local avail = true;
    if (pinned_idle) then avail = data.available(rec, rt.now); end
    local style = s.flash_style;
    local fk = 0;
    if (flashing) then fk = (0.55 + 0.45 * sin((rt.now - r.flash_until) * 9)) * s.flash_strength; end
    local fill = flashing and style ~= 'outline';
    if (fill) then
        D.rectf(x0 - 4, y + 1, x1 + 4, y + rh - 1, D.mul(soft, fk * 1.25), 3);
    elseif (ranked and s.pin_tint) then
        D.rectf(x0 - 4, y + 1, x1 + 4, y + rh - 1, tint, 3);
    end
    if (flashing and style ~= 'fill') then
        -- outline pulse, inside the row rect
        D.rect(x0 - 3, y + 2, x1 + 3, y + rh - 2, D.mul(acc, fk), 3, 2);
        if (fk > 0.25) then D.rect(x0 - 1, y + 4, x1 + 1, y + rh - 4, D.mul(soft, fk), 2, 1); end
    end
    if (flashing and FX.sweep) then FX.sweep_row(x0 - 4, y + 1, x1 + 4, y + rh - 1, ft, L.ready or acc); end
    if (not avail) then D.alpha = al * 0.55; end
    -- fixed columns (v1.3.0): pin gutter | icon slot | name ... time; the pin never moves the icon
    if (ranked) then draw_pin(x0 + 3, y + floor(rh / 2) - 3, u.pin, u.pin_dark); end
    local isz = L.isz;
    local ix = x0 + L.slot_x;
    r.slot_x, r.slot_y = ix, y + floor((rh - isz) / 2);
    local pop = (flashing and FX.ping and isz > 0) and FX.pop(ft, isz) or 0;
    r.ph = (isz > 0) and draw_icon(th, r, ix - pop, r.slot_y - pop, isz + 2 * pop, acc) or false;
    if (flashing and FX.ping and isz > 0) then
        local ps = s.fx_ping_style;
        if (ps ~= 'swipe') then FX.ring(ix, r.slot_y, isz, ft, L.ready or acc); end
        if (ps == 'swipe' or ps == 'both') then
            -- r.ph == false: a texture was drawn, so use its aspect-fitted rect; otherwise the slot square
            if (r.ph == false and r.img_x0 ~= nil) then FX.swipe(r.img_x0, r.img_y0, r.img_x1, r.img_y1, ft, L.ready or acc);
            else FX.swipe(ix - pop, r.slot_y - pop, ix + isz + pop, r.slot_y + isz + pop, ft, L.ready or acc); end
        end
    end
    local nx = x0 + L.name_x;
    local rem;
    if (flashing or pinned_idle) then rem = 0;
    elseif (r.rem_t == rt.now) then rem = r.rem_v;
    else rem = data.remaining(rec, rt.now); end
    local lowmp = false;
    if (s.mp_check and avail and rec.kind == 'spell') then
        if (data.state.test) then lowmp = (rec.id == 216); else lowmp = mpc.short(rec.id); end   -- test mode: Gravity shows the warning
    end
    row_time(r, rem, flashing, avail, s.gold_tenths, lowmp);
    local ty = y + floor((rh - L.block) / 2);
    -- bar (skipped for Ready / Not available rows: nothing to show)
    if (s.show_bars and rem > 0) then
        local frac = rem / max(0.001, rec.total > 0 and rec.total or rem);
        local fxb = nil;
        if (FX.bar_on) then
            if (r.fx_ph == nil) then r.fx_ph = math.random() * 10; end
            fxb = FX.B;
            fxb.rem, fxb.frac, fxb.ph, fxb.hot = rem, frac, r.fx_ph, L.ready or acc;
            fxb.heat = FX.heat and FX.heat_step(r, frac, rt.now) or 0;
        end
        if (s.compact) then themes.draw_bar(th, nx, y + rh - 3, x1, frac, acc, 2, fxb);
        else themes.draw_bar(th, nx, ty + L.text_h + 5, x1, frac, acc, L.bh, fxb); end
    end
    r.vis, r.al, r.avail = true, D.alpha, avail;
    r.tx = x1 - r.tw;
    r.ty, r.nx, r.ry = ty, nx, y;
    if (r.tkey == NA_KEY) then r.tcol = u.dim;
    elseif (r.tkey == MP_KEY) then r.tcol = L.nomp;
    elseif (r.tkey == READY_KEY) then r.tcol = L.ready or acc;
    else r.tcol = r.tgold and u.gold or u.text; end
    D.alpha = save_alpha;
end

local function draw_rows(th, g, y, w, acc, tint, soft)
    local s, u = rt.s, th.u;
    local bottom = rt.body_bottom;   -- body clip bottom: anything starting below it is invisible
    local first, last = 0, 0;
    for i = 1, #g.rows do
        local r = g.rows[i];
        r.vis = false;
        if (y < bottom and not (r.over and r.p.v <= 0.01)) then   -- cull (v1.1.2)
            local fk = r.rec.fkey;
            if (r.rk_gen ~= rt.rk_gen or r.rk_fkey ~= fk or r.rk_grp ~= g.name) then
                r.rk_gen, r.rk_fkey, r.rk_grp = rt.rk_gen, fk, g.name;
                r.rk_val = list.rank_of(g.name, fk) ~= nil;
            end
            row_pass1(th, g, r, y, w, acc, tint, soft, r.rk_val);
            if (r.vis) then if (first == 0) then first = i; end last = i; end
        end
        y = y + L.row_h * r.p.v;
    end
    if (first == 0) then return y; end
    local save_alpha = D.alpha;
    -- placeholder icon letters (one font push)
    local any = false;
    for i = first, last do if (g.rows[i].vis and g.rows[i].ph) then any = true; break; end end
    if (any) then
        push_font(rt.f_title, floor(L.isz * 0.6));
        for i = first, last do
            local r = g.rows[i];
            if (r.vis and r.ph) then D.alpha = r.al; D.text(r.ix, r.iy, u.text, r.ini); end
        end
        pop_font();
    end
    -- times (one font push)
    local tfs = L.tfs;
    local dy_t = floor((L.text_h - tfs) / 2);
    push_font(rt.f_num, tfs);
    for i = first, last do
        local r = g.rows[i];
        if (r.vis and r.tkey ~= NA_KEY and r.tkey ~= MP_KEY) then D.alpha = r.al; D.text(r.tx, r.ty + dy_t, r.tcol, r.tstr); end
    end
    pop_font();
    -- 'Not available' / 'Not enough MP' in the name font size (smaller when the time font is large)
    local nfs = L.nfs;
    local dy_n = floor((L.text_h - nfs) / 2);
    push_font(rt.f_body, L.nafs);
    for i = first, last do
        local r = g.rows[i];
        if (r.vis and (r.tkey == NA_KEY or r.tkey == MP_KEY)) then D.alpha = r.al; D.text(r.tx, r.ty + floor((L.text_h - L.nafs) / 2), r.tcol, r.tstr); end
    end
    pop_font();
    -- names (one font push; clip only when the name would run into the time)
    push_font(rt.f_body, nfs);
    local rh = L.row_h;
    for i = first, last do
        local r = g.rows[i];
        if (r.vis) then
            local name = r.rec.name or '?';
            D.alpha = r.al;
            local col = r.avail and u.text or u.dim;
            if (r.nx + text_w(rt.f_body, nfs, name) <= r.tx - 6) then
                D.text(r.nx, r.ty + dy_n, col, name);
            else
                local av = floor(r.tx - 6 - r.nx);
                if (r.cut_name ~= name or r.cut_av ~= av or r.cut_fs ~= nfs or r.cut_gen ~= rt.wgen) then
                    r.cut_name, r.cut_av, r.cut_fs, r.cut_gen = name, av, nfs, rt.wgen;
                    r.cut_str = ellipsize(rt.f_body, nfs, name, av);
                end
                if (r.cut_str ~= nil) then
                    D.text(r.nx, r.ty + dy_n, col, r.cut_str);
                else
                    local nc = D.clip_push(r.nx, r.ry, r.tx - 6, r.ry + rh);
                    if (nc) then D.text(r.nx, r.ty + dy_n, col, name); D.clip_pop(); end
                end
            end
        end
    end
    pop_font();
    D.alpha = save_alpha;
    return y;
end

local GROUP_LABEL = { spells = 'SPELLS', abilities = 'ABILITIES' };
local GROUP_BTN = { spells = '##rx_grp_spells', abilities = '##rx_grp_abilities' };
local MORE = {};
local function more_str(n) local c = MORE[n]; if (c == nil) then c = '+' .. n .. ' more'; MORE[n] = c; end return c; end

local function draw_group(th, g, y, w)
    local s, u = rt.s, th.u;
    local gp = g.gp.v;
    if (gp <= 0.001 and #g.rows == 0) then return y; end
    local save_alpha = D.alpha;
    D.alpha = save_alpha * max(gp, (#g.rows > 0) and 0.3 or 0);
    local acc = (g.name == 'spells') and u.acc_sp or u.acc_ab;
    local tint = (g.name == 'spells') and u.acc_sp_tint or u.acc_ab_tint;
    local soft = (g.name == 'spells') and u.acc_sp_soft or u.acc_ab_soft;
    local gh = L.gh * gp;
    local collapsed = s.collapsible and s.collapsed[g.name];
    local bottom = rt.body_bottom;
    if (gh > 2 and y < bottom) then
        local gfs = L.gfs;
        local cy = y + gh / 2;
        -- collapse arrow
        local ax = L.pad + 4;
        if (s.collapsible) then
            if (collapsed) then D.tri(ax - 3, cy - 4, ax + 3, cy, ax - 3, cy + 4, acc);
            else D.tri(ax - 4, cy - 3, ax + 4, cy - 3, ax, cy + 3, acc); end
            ax = ax + 9;
        else
            ax = L.pad;
        end
        local label = GROUP_LABEL[g.name];
        local tw = text_w(rt.f_title, gfs, label);
        push_font(rt.f_title, gfs);
        D.text(ax, cy - gfs * 0.55, acc, label);
        pop_font();
        -- v1.2.0: no entry count; the rule runs to the right edge
        D.hgrad(ax + tw + 8, cy, w - L.pad, cy + 1, soft, u.clear);
        if (s.collapsible and imgui.InvisibleButton ~= nil and imgui.SetCursorPos ~= nil and gp > 0.5) then
            V_CUR[1], V_CUR[2] = MARGIN + L.pad, MARGIN + y;
            imgui.SetCursorPos(V_CUR);
            V_BTN[1], V_BTN[2] = w - 2 * L.pad, max(1, gh);
            if (imgui.InvisibleButton(GROUP_BTN[g.name], V_BTN)) then
                s.collapsed[g.name] = not s.collapsed[g.name]; mark_dirty();
            end
        end
    end
    y = y + gh;
    D.alpha = save_alpha;
    if (not collapsed) then
        y = draw_rows(th, g, y, w, acc, tint, soft);
        -- '+N more' (rows over the cap)
        local mp = g.mp.v;
        if (mp > 0.01) then
            local mh = L.more_h * mp;
            if (y < bottom and g.more > 0) then
                local str = more_str(g.more);
                local mfs = L.gfs;
                local mw = text_w(rt.f_body, mfs, str);
                D.alpha = save_alpha * mp * 0.85;
                push_font(rt.f_body, mfs);
                D.text(w - L.pad - mw, y + (mh - mfs) / 2, u.dim, str);
                pop_font();
                D.hgrad(L.pad + L.name_x, y + mh / 2, w - L.pad - mw - 8, y + mh / 2 + 1, u.clear, soft);
                D.alpha = save_alpha;
            end
            y = y + mh;
        end
    end
    return y + L.gap * gp;
end

--[[
* Idle state (v1.1.0). Busy = visible rows (not hidden by the job filter) still counting down
* (time > 0). SP1/SP2 never count, 0-time and stale records never count. Rows that only flash
* 'Ready' or are sliding out do not keep the window busy either; the idle look starts as soon as
* they are gone. The mode is read every frame, so a change applies immediately - also while the
* settings window is open (v1.0.0 forced the 'show' look while it was open, so changing the
* option there never showed a difference).
--]]
local update_pins;
local function update_busy()
    local busy, first, flashing, pinned = 0, nil, 0, 0;
    for gi = 1, #list.order do
        local g = list.order[gi];
        for i = 1, #g.rows do
            local r = g.rows[i];
            local rem = 0;
            if (r.state == 'active' and r.rec ~= nil) then
                rem = data.remaining(r.rec, rt.now);
                r.rem_v, r.rem_t = rem, rt.now;      -- reused by row_pass1 this frame
            end
            if (rem > 0) then
                busy = busy + 1;
                if (first == nil) then first = r.rec; end
            elseif (r.state == 'pinned') then
                -- v1.2.0 keep-pinned rows (Ready / Not available): never busy, never 'ready' counts
                if (not r.over) then pinned = pinned + 1; end
            elseif (r.state ~= 'leaving' or (r.p.v > 0.01 and not r.over)) then
                flashing = flashing + 1;
            end
        end
    end
    rt.busy, rt.busy_first, rt.settling, rt.pinned_rows = busy, first, flashing, pinned;
    rt.idle = busy == 0;
    rt.idle_settled = busy == 0 and flashing == 0;
end

--[[
* v1.2.0 keep pinned visible: the records of the pinned keys of the current profile, rebuilt only
* when the pins, the job or test mode change (or every scan in test mode, where sample records
* appear lazily). Stored pins are never changed here; unknown/unavailable keys still get a
* record (shown as Not available), malformed keys are skipped.
--]]
local function fill_pins(out, keys, hidden)
    out.n = 0;
    for i = 1, #keys do
        local key = keys[i];
        if (not hidden[key]) then
            local rec = data.pinned_rec(key);
            if (rec ~= nil) then out.n = out.n + 1; out[out.n] = rec; end
        end
    end
    for i = out.n + 1, #out do out[i] = nil; end
end
update_pins = function (p)
    local st = data.state;
    local sig = st.test and st.scans or st.job_sig;
    if (rt.pins_ver == prof.version and rt.pins_prof == p and rt.pins_sig == sig and rt.pins_test == st.test and rt.pins_spr == data.sp_rows) then return; end
    rt.pins_ver, rt.pins_prof, rt.pins_sig, rt.pins_test, rt.pins_spr = prof.version, p, sig, st.test, data.sp_rows;
    fill_pins(rt.pins_sp, p.pins.spells, p.hidden);
    fill_pins(rt.pins_ab, p.pins.abilities, p.hidden);
end

local function update_model()
    local s = rt.s;
    if (rt.now >= rt.next_scan) then
        local t0 = perf_on and PF.now() or 0;
        data.scan(rt.now);
        -- 10 Hz while anything is counting down or flashing, 4 Hz when idle (a new cast shows up <= 0.25 s late)
        rt.next_scan = rt.now + ((rt.idle_settled and not data.state.test) and 0.25 or 0.1);
        if (perf_on) then PF_cur[PF.SCAN] = PF_cur[PF.SCAN] + (PF.now() - t0); end
    end
    if (s.mp_check and not data.state.test) then mpc.update(rt.now); end
    local p = current_profile(false);
    list.refresh_rank(p, prof.version);
    if (rt.rk_p ~= p or rt.rk_ver ~= prof.version) then rt.rk_p, rt.rk_ver = p, prof.version; rt.rk_gen = (rt.rk_gen or 0) + 1; end
    local o = rt.opt;
    o.animate, o.speed, o.row_motion, o.flash, o.flash_secs = s.animate, s.anim_speed, s.row_motion, s.ready_flash, s.flash_secs;
    local psp, pab = nil, nil;
    if (s.keep_pinned) then update_pins(p); psp, pab = rt.pins_sp, rt.pins_ab; end
    list.update_group(list.groups.spells, data.state.spells, p, o, rt.now, data, psp);
    list.update_group(list.groups.abilities, data.state.abilities, p, o, rt.now, data, pab);
    local c = rt.caps;
    c.spells, c.abilities, c.total = s.max_spells, s.max_abilities, s.max_total;
    list.finish(rt.now, c);
    update_busy();
end

-- Lines for '/pxi recast debug idle' (and the General tab): idle state and what keeps the tracker busy.
local function idle_report()
    local out = {};
    local s, st = rt.s, data.state;
    local p = current_profile(false);
    local busy, hidden, zero = {}, 0, 0;
    for _, l in ipairs({ st.spells, st.abilities }) do
        for i = 1, l.n do
            local r = l[i];
            local rem = data.remaining(r, rt.now);
            if (p.hidden[r.fkey]) then hidden = hidden + 1;
            elseif (rem <= 0) then zero = zero + 1;
            else busy[#busy + 1] = fmt('%s %.1fs [%s]', r.name or '?', rem, r.key); end
        end
    end
    local look = (not rt.idle) and 'normal list' or ((s.idle_mode == 'hide') and 'hidden' or ((s.idle_mode == 'show') and "'All recasts ready' line" or 'collapsed to the header bar'));
    out[1] = fmt('Idle: %s  (mode: %s -> %s)%s', rt.idle and 'yes' or 'no', s.idle_mode, look,
        (rt.idle and not rt.idle_settled) and ', waiting for Ready flash/slide-out' or '');
    if (#busy > 0) then out[2] = 'Busy (' .. #busy .. '): ' .. table.concat(busy, ', ');
    else out[2] = 'Busy: nothing.'; end
    out[3] = fmt('Not counted: %d hidden by the %s filter, %d at 0 s, %s%s%s.', hidden, rt.prof_key or '?', zero,
        data.sp_rows and 'kept pinned rows' or 'SP1/SP2 timers (header badges), kept pinned rows',
        (rt.pinned_rows or 0) > 0 and fmt(' (%d shown)', rt.pinned_rows) or '',
        st.test and ', TEST MODE is on (sample timers)' or '');
    return out;
end
rt.idle_report = idle_report;

-- Pre-rendered header tiles (icons\\fx\\*.png, styles and file names in rxthemes.STYLE_LIST/FX_STYLES).
-- Returns { style = <name>, <file name> = texture id } when ALL tiles of the chosen style exist and
-- are loaded, otherwise nil: the theme then draws its (slower) vector pattern, so nothing breaks
-- without the files. Paths and result tables are cached; nothing is allocated per frame.
local FX_DIR = nil;
local FX_TBL = {};
local FX_PATH = {};
local function header_fx(short, style)
    local names = themes.fx_files(short, style);
    if (names == nil) then return nil; end
    if (FX_DIR == nil) then FX_DIR = ((X.path or ''):gsub('[\\/]+$', '')) .. '\\icons\\fx\\'; end
    local by = FX_TBL[short];
    if (by == nil) then by = {}; FX_TBL[short] = by; end
    local t = by[style];
    if (t == nil) then t = { style = style }; by[style] = t; end
    for i = 1, #names do
        local nm = names[i];
        local p = FX_PATH[nm];
        if (p == nil) then p = FX_DIR .. nm .. '.png'; FX_PATH[nm] = p; end
        if (not icons.exists(p)) then return nil; end
        local id = icons.texture(p, rt.frame);
        if (id == nil) then return nil; end
        t[nm] = id;
    end
    return t;
end

local quick_access;      -- defined below (header button, right-click menus, row menu)
local function render_main()
    local s = rt.s;
    local st = data.state;
    if (st.main == 0 and not st.test) then return; end
    -- Hidden state (cutscene, 'Hide' idle mode, hide-when-idle-even-if-pinned) is decided before any
    -- layout/measure work; once the window has faded out and still wants to be hidden, nothing else runs.
    local mode = s.idle_mode;
    local settled = rt.idle_settled;
    local force_hide = settled and s.hide_idle_pinned;     -- v1.3.0: wins over keep-pinned and the idle mode
    local keep = rt.pinned_rows > 0 and not force_hide;    -- v1.2.0: kept pinned rows hold the body open
    -- PartyramaXI: attached above the party list. M.attach_box is the list's background rect this frame (screen px),
    -- nil while the list is not drawn; then an attached tracker hides with it.
    -- 2.5: an attached tracker no longer hides with the list; it stays where it last sat (see below).
    local A = s.attach and M.attach_box or nil;
    rt.no_list = s.attach and A == nil;
    local want_hidden = rt.cutscene or rt.nocombat or force_hide or (settled and mode == 'hide' and not keep);
    if (want_hidden and rt.hidden) then return; end
    if (rt.th == nil or rt.th_name ~= s.theme or rt.th_pal ~= s.dragoon_palette) then
        rt.th = themes.resolve(s.theme, s.dragoon_palette); rt.th_name, rt.th_pal = s.theme, s.dragoon_palette;
    end
    local th = rt.th;
    local pt = perf_on and PF.now() or 0;
    layout();
    -- attached: exactly the party list's width (kept while it fades out after the list went away)
    if (A ~= nil) then rt.last_w = max(60, floor(A.x1 - A.x0 + 0.5)); end
    if (s.attach and rt.last_w ~= nil) then L.w = rt.last_w; end
    if (perf_on) then local t = PF.now(); PF_cur[PF.LAYOUT] = PF_cur[PF.LAYOUT] + (t - pt); pt = t; end
    local dur = s.animate and (list.BASE_DUR / max(0.1, s.anim_speed)) or 0;
    local content = list.content_height(L.row_h, L.gh, L.gap, s.collapsible and s.collapsed or V_ZERO, L.more_h);
    local show_idle = settled and mode == 'show';
    list.tween_to(rt.idle_tw, show_idle and 1 or 0, rt.now, dur); list.tween_step(rt.idle_tw, rt.now);
    -- body padding: gone when collapsed to the header bar
    list.tween_to(rt.pad, (not settled or mode ~= 'collapse' or keep) and 1 or 0, rt.now, dur); list.tween_step(rt.pad, rt.now);
    local body = content + L.idle_h * rt.idle_tw.v + 8 * rt.pad.v;
    list.tween_to(rt.vis, want_hidden and 0 or 1, rt.now, dur); list.tween_step(rt.vis, rt.now);
    rt.hidden = rt.vis.v <= 0.01;
    if (rt.hidden) then return; end

    local w = L.w;
    local hh = s.hide_header and 0 or L.hh;                 -- PartyramaXI: header can be hidden
    local h = hh + body;
    if (h < 1) then rt.hidden = true; return; end           -- header hidden and body collapsed: nothing to show
    local header_only = body < 1;
    rt.header_only = header_only;
    local m = MARGIN;
    rt.win_w, rt.win_h = w + 2 * m, floor(h + 2 * m + 0.5);
    -- never hand ImGui a zero, negative, NaN or display-sized window (0 = auto-fit in ImGui)
    if (not (rt.win_w >= 16)) then rt.win_w = 16; elseif (rt.win_w > 4096) then rt.win_w = 4096; end
    if (not (rt.win_h >= 16)) then rt.win_h = 16; elseif (rt.win_h > 4096) then rt.win_h = 4096; end

    if (G.cond_always == nil) then   -- resolved once (constants never change)
        G.cond_always = flag('ImGuiCond_Always', 1);
        G.sv_pad = rawget(_G, 'ImGuiStyleVar_WindowPadding') or false;
        G.sv_border = rawget(_G, 'ImGuiStyleVar_WindowBorderSize') or false;
    end
    -- Attached: the frame's bottom sits attach_gap px above the list's top edge. Hiding and showing slide it down
    -- behind / up out of the list's top edge (clipped there), while it fades with the same tween.
    local clip_y = nil;
    if (A ~= nil) then
        local e = rt.vis.v;
        e = e * e * (3 - 2 * e);
        local ftop = A.y0 - s.attach_gap - h;
        if (not s.safe_mode) then ftop = ftop + (1 - e) * (h + s.attach_gap); end
        V_POS[1], V_POS[2] = floor(A.x0 - m + 0.5), floor(ftop - m + 0.5);
        clip_y = A.y0 - V_POS[2] - m;                       -- the list's top edge, in the frame's local coordinates
        -- still all behind the list. PartyramaXI: checked BEFORE SetNextWindowPos. A pending position with no
        -- Begin of ours goes to whichever ImGui window begins next (another addon's, e.g. zztick), moving it there.
        if (clip_y < 1) then return; end
        imgui.SetNextWindowPos(V_POS, G.cond_always);
        if (clip_y >= rt.win_h - m) then clip_y = nil; end  -- fully out: no clip needed
        rt.place = false;
        rt.lone_x, rt.lone_y = V_POS[1], floor(A.y0 - s.attach_gap - h - m + 0.5);   -- where it rests when the list goes away
    elseif (s.attach) then
        -- attached but the party list is off or not showing: stays where it last sat above the list (or at its own
        -- saved position), so the tracker never depends on the list being on
        V_POS[1], V_POS[2] = rt.lone_x or s.x, rt.lone_y or s.y;
        imgui.SetNextWindowPos(V_POS, G.cond_always);
        rt.place = true;
    elseif (rt.place and not s.attach) then
        V_POS[1], V_POS[2] = s.x, s.y;
        imgui.SetNextWindowPos(V_POS, G.cond_always);
        rt.place = false;
    end
    local locked = s.locked or s.attach;
    V_SIZE[1], V_SIZE[2] = rt.win_w, rt.win_h;
    imgui.SetNextWindowSize(V_SIZE, G.cond_always);
    local pushed = 0;
    local sv_pad, sv_border = G.sv_pad, G.sv_border;
    if (type(sv_pad) == 'number') then imgui.PushStyleVar(sv_pad, V_ZERO); pushed = pushed + 1; end
    if (type(sv_border) == 'number') then imgui.PushStyleVar(sv_border, 0); pushed = pushed + 1; end
    rt.in_win, rt.pushed = true, pushed;
    if (imgui.Begin('hpp Recasts##hpp_rx_main', nil, window_flags(locked))) then
        -- window-local origin (never GetWindowPos for drawing)
        local sx, sy = xy(imgui.GetCursorScreenPos());
        local cx, cy = xy(imgui.GetCursorPos());
        rt.win_x, rt.win_y = sx - cx, sy - cy;            -- window top-left, content space
        rt.origin_x, rt.origin_y = rt.win_x + m, rt.win_y + m;
        X.draw.obst(rt.win_x, rt.win_y, rt.win_x + rt.win_w, rt.win_y + rt.win_h);     -- PartyramaXI: the target bar keeps off it
        -- every primitive must stay inside this window's own rect (local -m .. size - m)
        D.no_clip = s.safe_mode;
        D.begin(imgui.GetWindowDrawList(), rt.origin_x, rt.origin_y, s.opacity * rt.vis.v, -m, -m, rt.win_w - m, rt.win_h - m);
        local sc = clip_y ~= nil and D.clip_push(-m, -m, rt.win_w - m, clip_y) or false;
        X.draw.hl_rect('recast', 'window', rt.origin_x, rt.origin_y, rt.origin_x + w, rt.origin_y + h);
        -- The glow lives in the MARGIN band inside the window rect. ImGui's own window clip rect
        -- (padding and border are 0) already covers it, so no clip rect is pushed for the frame.
        -- 1.1.0/1.1.1 pushed a NON-intersecting clip rect here (the full-screen stretch bug).
        if (perf_on) then pt = PF.now(); end
        local safe = s.safe_mode;
        local fx = nil;
        if (s.header_texture and not safe) then fx = header_fx(th.def.short, themes.style_for(th.def.short, s)); end
        rt.fx_on = fx ~= nil;
        -- PartyramaXI: the outer glow is drawn first and never clipped; while collapsing to (or collapsed to)
        -- the header bar the frame, pictures, ornaments and rows are clipped at the frame's bottom border.
        local glow_k = (s.glow and not safe) and s.glow_strength or 0;
        if (type(glow_k) == "number" and glow_k > 0 and s.frame_src ~= 'list') then themes.draw_glow(th, w, h, glow_k); end
        local hc = (header_only or rt.pad.v < 0.999) and D.clip_push(-m, -m, rt.win_w - m, h + 1) or false;
        if (s.frame_src == 'list' and M.list_panel ~= nil) then
            -- the party list's background and border (pxilist), plus a faint line under the header
            M.list_panel(D.dl, rt.origin_x, rt.origin_y, rt.origin_x + w, rt.origin_y + h, s.opacity * rt.vis.v);
            if (not header_only and hh > 0) then D.rectf(6, hh - 1, w - 6, hh, D.fade(th.u.text, 0.18)); end
        else
            themes.draw_frame(th, w, h, hh, header_only, 0,
                (s.header_texture and not safe) and s.texture_strength or 0, fx);
        end
        if (perf_on) then local t = PF.now(); PF_cur[PF.FX] = PF_cur[PF.FX] + (t - pt); pt = t; end
        if (hh > 0) then draw_header(th, w, hh); end
        if (perf_on) then local t = PF.now(); PF_cur[PF.HEADER] = PF_cur[PF.HEADER] + (t - pt); pt = t; end
        if (not header_only and h - 1 > hh) then
            rt.body_bottom = h - 1;
            local bc = D.clip_push(0, hh, w, h - 1);
            local y = hh + 6 * rt.pad.v;
            for i = 1, #list.order do y = draw_group(th, list.order[i], y, w); end
            if (rt.idle_tw.v > 0.01) then
                local sa = D.alpha; D.alpha = sa * rt.idle_tw.v;
                local tw = text_w(rt.f_body, L.ifs, IDLE_TEXT);
                push_font(rt.f_body, L.ifs);
                D.text((w - tw) / 2, y + (L.idle_h - L.ifs) / 2, L.ready or th.u.text, IDLE_TEXT);
                pop_font();
                D.alpha = sa;
            end
            if (bc) then D.clip_pop(); end
        end
        if (hc) then D.clip_pop(); end
        if (perf_on) then local t = PF.now(); PF_cur[PF.ROWS] = PF_cur[PF.ROWS] + (t - pt); pt = t; end
        sp_tooltip();
        if (quick_access ~= nil) then quick_access(th, w, h, hh, header_only); end
        if (perf_on) then PF_cur[PF.HEADER] = PF_cur[PF.HEADER] + (PF.now() - pt); end
        if (imgui.SetCursorPos ~= nil) then imgui.SetCursorPos(V_ZERO); end
        V_DUMMY[1], V_DUMMY[2] = rt.win_w, rt.win_h;
        imgui.Dummy(V_DUMMY);
        -- remember where the user dragged the window (position only)
        -- (v1.1.2: from the cursor-derived window corner, the same space SetNextWindowPos takes;
        -- GetWindowPos is not used at all any more: under dgVoodoo it can report another space)
        if (sc) then D.clip_pop(); end
        if (not locked) then
            local wx, wy = floor(rt.win_x + 0.5), floor(rt.win_y + 0.5);
            local down = imgui.IsMouseDown ~= nil and imgui.IsMouseDown(0);
            if ((wx ~= s.x or wy ~= s.y) and not down) then s.x, s.y = wx, wy; mark_dirty(); end
        end
        D.dl = nil;
    end
    imgui.End();
    rt.in_win = false;
    while (font_depth > 0) do pop_font(); end
    if (pushed > 0) then imgui.PopStyleVar(pushed); end
end


--[[ ------------------------------------------------------------------ quick access (v1.5.0)
* A small 'Pinned Abilities' button on the header (visible while the mouse is over the header), right-click on
* the header opens Settings > Pinned Abilities, and right-click on a row opens a small menu
* (Pin / Unpin, Hide, open Pinned Abilities). Everything is guarded and only does work on a click frame.
--]]
local open_filters;
do
local V_GA, V_GB = { 0, 0 }, { 0, 0 };
local ROW_MENU = 'RxRowMenu##rx_rowmenu';
local QA_LABEL = 'Pinned Abilities';
local function hovering(x0, y0, x1, y1)
    if (imgui.IsMouseHoveringRect == nil) then return false; end
    V_GA[1], V_GA[2] = rt.origin_x + x0, rt.origin_y + y0;
    V_GB[1], V_GB[2] = rt.origin_x + x1, rt.origin_y + y1;
    return imgui.IsMouseHoveringRect(V_GA, V_GB) == true;
end
local qa_click = function (th, w, h, hh, header_only)
    local s = rt.s;
    if (not s.quick_menu or imgui.IsMouseHoveringRect == nil) then return; end
    local over_win = true;
    if (imgui.IsWindowHovered ~= nil) then over_win = imgui.IsWindowHovered() == true; end
    local u = th.u;
    -- the button: only drawn (and only clickable) while the mouse is over the header
    if (over_win and hovering(0, 0, w, hh)) then
        local fs = max(FS_MIN, min(FS_MAX, floor(L.gfs) + 3));
        local tw = text_w(rt.f_body, fs, QA_LABEL);
        local bx0, by0 = 3, 3;
        local bx1, by1 = bx0 + tw + 10, by0 + fs + 4;
        local over_btn = hovering(bx0, by0, bx1, by1);
        local sa = D.alpha;
        D.alpha = sa * (over_btn and 1.0 or 0.8);
        D.rectf(bx0, by0, bx1, by1, u.black60, 3);
        if (over_btn) then D.rectf(bx0, by0, bx1, by1, u.white10, 3); end
        D.rect(bx0, by0, bx1, by1, u.border or u.text, 3, 1);
        push_font(rt.f_body, fs);
        D.text(bx0 + 5, by0 + 2, u.text, QA_LABEL);
        pop_font();
        D.alpha = sa;
        if (imgui.InvisibleButton ~= nil and imgui.SetCursorPos ~= nil) then
            V_CUR[1], V_CUR[2] = MARGIN + bx0, MARGIN + by0;
            imgui.SetCursorPos(V_CUR);
            V_BTN[1], V_BTN[2] = bx1 - bx0, by1 - by0;
            if (imgui.InvisibleButton('##rx_qa_btn', V_BTN)) then open_filters(); end
            if (imgui.IsItemHovered ~= nil and imgui.SetTooltip ~= nil and imgui.IsItemHovered()) then
                imgui.SetTooltip('Open settings on Pinned Abilities. Right-click a row to pin or hide it.');
            end
        end
    end
    -- right-click: header = settings, row = pin menu
    if (over_win and imgui.IsMouseClicked ~= nil and imgui.IsMouseClicked(1)) then
        if (hovering(0, 0, w, hh)) then
            open_filters();
        elseif (not header_only and imgui.OpenPopup ~= nil and hovering(0, hh, w, h)) then
            for gi = 1, #list.order do
                local g = list.order[gi];
                if (not s.collapsed[g.name]) then
                    for i = 1, #g.rows do
                        local r = g.rows[i];
                        if (r.vis and not r.over and r.rec ~= nil and r.ry ~= nil and not r.rec.test and type(r.rec.fkey) == 'string'
                            and hovering(0, r.ry, w, r.ry + L.row_h)) then
                            rt.menu_key, rt.menu_name = r.rec.fkey, r.rec.name or r.rec.fkey;
                            imgui.OpenPopup(ROW_MENU);
                            return;
                        end
                    end
                end
            end
        end
    end
end
-- the popup itself (must be called inside the main window, same ID stack as OpenPopup)
local MC = { { 0, 0, 0, 1 }, { 0, 0, 0, 1 }, { 0, 0, 0, 1 }, { 0, 0, 0, 1 }, { 0, 0, 0, 1 }, { 0, 0, 0, 1 } };   -- reused color vectors
local MV_PAD, MV_SPC, MV_MINW, MV_MAXW = { 12, 9 }, { 8, 7 }, { 190, 0 }, { 600, 4000 };
local function mcol(i, c, a, k)
    local v = MC[i];
    k = k or 1;
    v[1], v[2], v[3], v[4] = (c[1] / 255) * k, (c[2] / 255) * k, (c[3] / 255) * k, a;
    return v;
end
local qa_menu = function (th)
    if (imgui.BeginPopup == nil or imgui.EndPopup == nil) then return; end
    if (imgui.IsPopupOpen ~= nil and not imgui.IsPopupOpen(ROW_MENU)) then return; end
    local src = th.src or {};
    local bg, bd, tx = src.bg1 or { 20, 20, 26 }, src.border or { 214, 175, 90 }, src.text or { 235, 235, 235 };
    local acc, hv = src.acc_sp or bd, src.hd1 or src.bar2 or bd;
    local fs = max(FS_MIN, min(FS_MAX, floor(L.nfs) + 2));
    -- theme-colored popup: background, gold border, soft rounded corners, roomy spacing (all guarded and balanced)
    local pc, pv = 0, 0;
    local function pcol(name, v) local id = imgui[name]; if (type(id) == 'number') then imgui.PushStyleColor(id, v); pc = pc + 1; end end
    local function pvar(name, v) local id = imgui[name]; if (type(id) == 'number') then imgui.PushStyleVar(id, v); pv = pv + 1; end end
    if (imgui.PushStyleColor ~= nil and imgui.PopStyleColor ~= nil) then
        pcol('ImGuiCol_PopupBg', mcol(1, bg, 0.97, 0.8));
        pcol('ImGuiCol_Border', mcol(2, bd, 0.9));
        pcol('ImGuiCol_Text', mcol(3, tx, 1.0));
        pcol('ImGuiCol_Header', mcol(4, hv, 0.0));
        pcol('ImGuiCol_HeaderHovered', mcol(4, hv, 0.75));
        pcol('ImGuiCol_HeaderActive', mcol(5, acc, 0.55));
        pcol('ImGuiCol_Separator', mcol(6, bd, 0.55));
    end
    if (imgui.PushStyleVar ~= nil and imgui.PopStyleVar ~= nil) then
        pvar('ImGuiStyleVar_WindowPadding', MV_PAD);
        pvar('ImGuiStyleVar_ItemSpacing', MV_SPC);
        pvar('ImGuiStyleVar_WindowRounding', 7);
        pvar('ImGuiStyleVar_PopupRounding', 7);
        pvar('ImGuiStyleVar_PopupBorderSize', 1);
        pvar('ImGuiStyleVar_FrameRounding', 4);
    end
    push_font(rt.f_body, fs);
    -- 2.7.2: constraints only when the menu is open, so they can never be left pending for another window
    local menu_open = imgui.IsPopupOpen == nil or imgui.IsPopupOpen(ROW_MENU) == true;
    if (menu_open and imgui.SetNextWindowSizeConstraints ~= nil) then pcall(imgui.SetNextWindowSizeConstraints, MV_MINW, MV_MAXW); end
    if (imgui.BeginPopup(ROW_MENU)) then
        local key, name = rt.menu_key, rt.menu_name or '?';
        if (key ~= nil) then
            local p = edit_profile();
            -- title: the spell / ability name in the theme's title font and accent color
            push_font(rt.f_title, fs + 1);
            if (imgui.PushStyleColor ~= nil and imgui.ImGuiCol_Text ~= nil) then
                imgui.PushStyleColor(imgui.ImGuiCol_Text, mcol(3, acc, 1.0)); imgui.Text(name); imgui.PopStyleColor(1);
            else imgui.Text(name); end
            pop_font();
            imgui.Separator();
            local pinned = prof.pin_index(p, key) ~= nil;
            if (imgui.Selectable(pinned and 'Unpin##rm_pin' or 'Pin (show first)##rm_pin')) then
                prof.toggle_pin(p, key); mark_dirty(); msg((pinned and 'Unpinned ' or 'Pinned ') .. name .. '.');
            end
            if (imgui.Selectable('Hide this row##rm_hide')) then
                prof.set_hidden(p, key, true); mark_dirty(); msg('Hidden ' .. name .. '. Bring it back in Settings > Pinned Abilities.');
            end
            imgui.Separator();
            if (imgui.Selectable('Open Pinned Abilities##rm_open')) then open_filters(); end
        end
        imgui.EndPopup();
    end
    pop_font();
    if (pv > 0) then imgui.PopStyleVar(pv); end
    if (pc > 0) then imgui.PopStyleColor(pc); end
end
quick_access = function (th, w, h, hh, header_only)
    qa_click(th, w, h, hh, header_only);
    qa_menu(th);
end
end   -- do (quick access locals)

--[[ ------------------------------------------------------------------ config window ]]
-- PartyramaXI: the settings below draw through ui: the plain imgui, or pxiui's table (key settings marked,
-- searchable). The tracker itself always uses imgui.
local ui = imgui;
function M.set_ui(t) ui = t or imgui; end
local REF_B, REF_I, REF_F = { false }, { 0 }, { 0 };
local function cb(label, key)
    REF_B[1] = rt.s[key];
    if (ui.Checkbox(label, REF_B)) then rt.s[key] = REF_B[1]; mark_dirty(); return true; end
    return false;
end
local function slider_i(label, key, lo, hi)
    REF_I[1] = rt.s[key];
    if (ui.SliderInt(label, REF_I, lo, hi)) then rt.s[key] = max(lo, min(hi, floor(REF_I[1] + 0.5))); mark_dirty(); return true; end
    return false;
end
local function slider_f(label, key, lo, hi, f)
    REF_F[1] = rt.s[key];
    if (ui.SliderFloat(label, REF_F, lo, hi, f or '%.2f')) then rt.s[key] = max(lo, min(hi, REF_F[1])); mark_dirty(); return true; end
    return false;
end
local function radio(label, key, value)
    if (ui.RadioButton(label, rt.s[key] == value)) then rt.s[key] = value; mark_dirty(); return true; end
    return false;
end
local function same() ui.SameLine(); end
local function help(text)
    if (ui.TextDisabled ~= nil) then ui.TextDisabled(text); else ui.Text(text); end
end
-- hover help for the last widget (guarded: older builds lack IsItemHovered/SetTooltip)
local ready_color_edit, nomp_edit;
local function tip(text)
    if (ui.IsItemHovered ~= nil and ui.SetTooltip ~= nil and ui.IsItemHovered()) then ui.SetTooltip(text); end
end
-- greyed-out block (BeginDisabled is ImGui 1.84+; returns whether it was pushed)
local function begin_disabled(off)
    if (off and ui.BeginDisabled ~= nil and ui.EndDisabled ~= nil) then ui.BeginDisabled(true); return true; end
    return false;
end
local function end_disabled(pushed) if (pushed) then ui.EndDisabled(); end end
local function section(label, open)
    return ui.CollapsingHeader(label, open and flag('ImGuiTreeNodeFlags_DefaultOpen', 32) or 0);
end
-- font size slider: 0 = automatic, else 8..36 px
local function fs_slider(label, key, help_text)
    REF_I[1] = rt.s[key];
    if (ui.SliderInt(label, REF_I, 0, FS_MAX)) then
        local v = floor(REF_I[1] + 0.5);
        if (v > 0 and v < FS_MIN) then v = FS_MIN; end
        rt.s[key] = max(0, min(FS_MAX, v)); mark_dirty();
    end
    tip(help_text .. ' 0 = automatic (follows Font size). Final size is x Master scale, 8-36 px.');
end
-- display name for a stored filter key that is not in the known lists (unavailable now)
local function key_name(key)
    local n = rt.names[key];
    if (n == nil) then
        local rec = data.pinned_rec(key);
        n = (rec and rec.name) or key;
        rt.names[key] = n;
    end
    return n;
end

local function rebuild_known()
    local sp = data.known_spells();
    local ab, header = data.known_abilities();
    if (data.state.test) then
        local seen = {};
        for _, e in ipairs(sp) do seen[e.key] = true; end
        for _, e in ipairs(ab) do seen[e.key] = true; end
        for _, smp in ipairs(data.SAMPLE) do
            local key = (smp[1] == 'spell') and data.key_spell(smp[2]) or data.key_ability(smp[2]);
            if (not seen[key]) then
                local e = { key = key, id = smp[2], name = smp[3], kind = smp[1] };
                if (smp[1] == 'spell') then sp[#sp + 1] = e; else ab[#ab + 1] = e; end
            end
        end
        table.sort(sp, function (a, b) return a.name < b.name; end);
        table.sort(ab, function (a, b) return a.name < b.name; end);
        header = { { name = data.state.sp[1].name ~= '' and data.state.sp[1].name or 'SP1', slot = 1 },
                   { name = data.state.sp[2].name ~= '' and data.state.sp[2].name or 'SP2', slot = 2 } };
    end
    local by = {};
    for _, l in ipairs({ sp, ab }) do
        for _, e in ipairs(l) do
            e.lname = e.name:lower();
            e.label = e.sub and (e.name .. '  (sub)') or e.name;
            by[e.key] = e;
        end
    end
    rt.known = { spells = sp, abilities = ab, header = header };
    rt.by_key = by;
    rt.known_sig = data.state.job_sig * 2 + (data.state.test and 1 or 0);
end

local function filtered_keys(group)
    local q = rt.search[1]:lower();
    local out = {};
    for _, e in ipairs(rt.known[group]) do
        if (q == '' or e.lname:find(q, 1, true)) then out[#out + 1] = e.key; end
    end
    return out;
end

local PIN_SCOPE = { spells = 'pins_spells', abilities = 'pins_abilities' };
local LIST_SCOPE = { spells = 'list_spells', abilities = 'list_abilities' };
local GROUP_TITLE = { spells = 'Spells', abilities = 'Abilities' };
local DIR_UP, DIR_DOWN = 2, 3;

-- Ashita binds PushID(const char*) and PushID(int). A pin key that is a big number,
-- cdata, table, or a string sol will not take (the reported line 1227 crash) matches
-- neither overload. Always push a short plain string.
local function push_id(tag)
    if (type(tag) ~= 'string') then tag = tostring(tag); end
    ui.PushID(tag);
end

local ID_CACHE = { pin = {}, row = {}, na = {} };
local function id_of(prefix, n)
    local t = ID_CACHE[prefix];
    local v = t[n];
    if (v == nil) then v = prefix .. n; t[n] = v; end
    return v;
end

local function pinned_section(p, group)
    local pins = p.pins[group];
    if (type(pins) ~= 'table' or #pins == 0) then
        help('Pinned ' .. GROUP_TITLE[group] .. ': none yet. Press Pin beside one in the ' .. GROUP_TITLE[group] .. ' list below.');
        return;
    end
    ui.Text('Pinned ' .. GROUP_TITLE[group] .. ' (shown first, in this order):');
    push_id(PIN_SCOPE[group]);
    local changed = false;
    for i = 1, #pins do
        local key = pins[i];
        local e = rt.by_key[key];
        push_id(id_of('pin', i));
        if (not changed) then
            if (ui.ArrowButton ~= nil) then
                if (ui.ArrowButton('##up', flag('ImGuiDir_Up', DIR_UP))) then changed = prof.move(p, key, -1); end
                same();
                if (ui.ArrowButton('##down', flag('ImGuiDir_Down', DIR_DOWN))) then changed = prof.move(p, key, 1) or changed; end
            else
                if (ui.Button('Up##up')) then changed = prof.move(p, key, -1); end
                same();
                if (ui.Button('Dn##down')) then changed = prof.move(p, key, 1) or changed; end
            end
            same();
            if (ui.Button('Top##top')) then changed = prof.move(p, key, 'top') or changed; end
            same();
            if (ui.Button('Unpin##unpin')) then prof.toggle_pin(p, key); changed = true; end
            same();
            if (e ~= nil) then ui.Text(count_str(i) .. '. ' .. e.name);
            else help(count_str(i) .. '. ' .. key_name(key) .. '  (Not available)'); tip('Not usable right now (not learned, level too low, level sync, or wrong/disabled sub job). The pin is kept.'); end
        end
        ui.PopID();
        if (changed) then mark_dirty(); end
    end
    ui.PopID();
    ui.Separator();
end

local function entry_list(p, group)
    local l = rt.known[group];
    local q = rt.search[1]:lower();
    ui.PushID(LIST_SCOPE[group]);
    local n = 0;
    for _, e in ipairs(l) do
        if (q == '' or e.lname:find(q, 1, true)) then
            n = n + 1;
            push_id(id_of('row', n));
            REF_B[1] = not p.hidden[e.key];
            if (ui.Checkbox('##show', REF_B)) then prof.set_hidden(p, e.key, not REF_B[1]); mark_dirty(); end
            same();
            local pinned = prof.pin_index(p, e.key) ~= nil;
            if (ui.Button(pinned and 'Unpin##pin' or 'Pin##pin')) then prof.toggle_pin(p, e.key); mark_dirty(); end
            same();
            ui.Text(e.label);
            ui.PopID();
        end
    end
    if (n == 0) then help((q == '') and '  (none known for this job)' or '  (no match)'); end
    -- v1.2.0: pinned or hidden entries that are not available right now: greyed, kept, editable
    local prefix = (group == 'spells') and 's' or 'a';
    local na = rt.na_list; if (na == nil) then na = {}; rt.na_list = na; end
    for i = #na, 1, -1 do na[i] = nil; end
    for _, key in ipairs(p.pins[group]) do if (rt.by_key[key] == nil) then na[#na + 1] = key; end end
    for key, v in pairs(p.hidden) do
        if (v and type(key) == 'string' and key:sub(1, 1) == prefix and rt.by_key[key] == nil and prof.pin_index(p, key) == nil) then na[#na + 1] = key; end
    end
    if (#na > 0) then
        help('Not available now (kept for when they are):');
        for i, key in ipairs(na) do
            local nm = key_name(key);
            if (q == '' or nm:lower():find(q, 1, true)) then
                push_id(id_of('na', i));
                REF_B[1] = not p.hidden[key];
                if (ui.Checkbox('##na_show', REF_B)) then prof.set_hidden(p, key, not REF_B[1]); mark_dirty(); end
                same();
                local pinned = prof.pin_index(p, key) ~= nil;
                if (ui.Button(pinned and 'Unpin##na_pin' or 'Pin##na_pin')) then prof.toggle_pin(p, key); mark_dirty(); end
                same();
                help(nm .. '  (Not available)');
                tip('Not usable right now: not learned, level too low (level sync / level-down), or needs another or a disabled sub job.');
                ui.PopID();
            end
        end
    end
    ui.PopID();
end

local function tab_filters()
    local st = data.state;
    current_profile(false);
    if (rt.known == nil or rt.known_sig ~= st.job_sig * 2 + (st.test and 1 or 0)) then rebuild_known(); end
    -- PartyramaXI 1.0.0: how pinning works, step by step
    help('Choose which recasts show and which come first. Everything here is saved for the job below.');
    help('1. Find a spell or ability in the Spells / Abilities lists (type in Search to narrow them).');
    help('2. The tick box beside it shows or hides its row in the recast window.');
    help('3. Pin moves it into the pinned list at the top: pinned rows always come first, in that order.');
    help('4. In the pinned list, the arrows move a row up or down, Top makes it first and Unpin takes it out.');
    help('Shortcut: right-click a row in the recast window to Pin / Unpin or Hide it (when right-click menus are on).');
    ui.Separator();
    ui.Text('Profile: ' .. (rt.prof_key or '?') .. (rt.s.per_sub and '  (main + sub job)' or '  (main job)'));
    if (cb('Separate profile per sub job##per_sub', 'per_sub')) then rt.prof_sig = -1; current_profile(false); end
    tip('Off: one list per main job. On: a list per main and sub job pair (WHM/RDM and WHM/SCH are set up apart).');
    if (ui.InputText('Search##search', rt.search, 64)) then end
    tip('Type part of a name to narrow both lists below. Show all / Hide all only change the rows that match.');
    if (ui.Button('Show all##show_all')) then
        local p = edit_profile();
        prof.show_all(p, filtered_keys('spells')); prof.show_all(p, filtered_keys('abilities')); mark_dirty();
    end
    same();
    if (ui.Button('Hide all##hide_all')) then
        local p = edit_profile();
        prof.hide_all(p, filtered_keys('spells')); prof.hide_all(p, filtered_keys('abilities')); mark_dirty();
    end
    same();
    if (ui.Button('Unpin all##unpin_all')) then
        local p = edit_profile(); prof.unpin_all(p, 'spells'); prof.unpin_all(p, 'abilities'); mark_dirty();
    end
    tip('Empties both pinned lists for this job. The rows stay, in their normal order.');
    same();
    if (ui.Button('Refresh list##refresh_known')) then rebuild_known(); end
    tip('Reads your spells and abilities again (after learning a spell, changing sub job or level sync).');
    help('Show all / Hide all apply to the entries matching the search.');
    ui.Separator();
    local h = rt.known.header;
    if (#h > 0) then
        local names = {};
        for i = 1, #h do names[i] = h[i].name; end
        help('Header badges: ' .. table.concat(names, ', ') .. ' (always shown, hover for time; General > SP1 / SP2 can list them as ability rows)');
    end
    -- the profile is created on first edit; reading uses a shared empty profile
    local p = edit_profile();
    pinned_section(p, 'spells');
    pinned_section(p, 'abilities');
    if (ui.CollapsingHeader('Spells##hdr_spells', flag('ImGuiTreeNodeFlags_DefaultOpen', 32))) then entry_list(p, 'spells'); end
    if (ui.CollapsingHeader('Abilities##hdr_abilities', flag('ImGuiTreeNodeFlags_DefaultOpen', 32))) then entry_list(p, 'abilities'); end
end

local THEME_LABELS = {};
for i, t in ipairs(themes.LIST) do THEME_LABELS[i] = t.name .. '##theme_' .. i; end

local function open_folder(path)
    if (ashita ~= nil and ashita.fs ~= nil and ashita.fs.create_dir ~= nil and not ashita.fs.exists(path)) then pcall(ashita.fs.create_dir, path); end
    local ok = false;
    if (ashita ~= nil and ashita.misc ~= nil and ashita.misc.open_url ~= nil) then ok = pcall(ashita.misc.open_url, path); end
    msg((ok and 'Opened ' or 'Folder: ') .. path);
end

-- v1.3.0 'Ready' text color (rows + idle line). ColorEdit3 when available, else R/G/B sliders.
local REF_COL = { 1, 1, 1 };
-- fixed reset values: default_settings sub-tables can be shared with the live (edited) settings, so never reset from them
local NOMP_DEF, READY_DEF = { 110, 165, 255 }, { 255, 220, 120 };
local function set_rgb(s, k, d) local c = s[k]; if (type(c) ~= 'table') then c = T{}; s[k] = c; end c[1], c[2], c[3] = d[1], d[2], d[3]; end
ready_color_edit = function ()
    local s = rt.s;
    cb('Custom Ready color##ready_custom', 'ready_custom');
    tip('Color of the word Ready in the rows and of the "All recasts ready" line. Off = the theme accent. (SP badges show ability names and keep their contrast-checked colors.)');
    local dr = begin_disabled(not s.ready_custom);
    local c = s.ready_rgb;
    if (ui.ColorEdit3 ~= nil) then
        REF_COL[1], REF_COL[2], REF_COL[3] = c[1] / 255, c[2] / 255, c[3] / 255;
        if (ui.ColorEdit3('Ready color##ready_rgb', REF_COL)) then
            for i = 1, 3 do local v = floor((tonumber(REF_COL[i]) or 0) * 255 + 0.5); c[i] = max(0, min(255, v)); end
            mark_dirty();
        end
    else
        for i, nm in ipairs({ 'Red##ready_r', 'Green##ready_g', 'Blue##ready_b' }) do
            REF_I[1] = c[i];
            if (ui.SliderInt(nm, REF_I, 0, 255)) then c[i] = max(0, min(255, floor(REF_I[1] + 0.5))); mark_dirty(); end
        end
    end
    same();
    if (ui.Button('Reset to theme##ready_reset')) then s.ready_custom = false; set_rgb(s, 'ready_rgb', READY_DEF); mark_dirty(); end
    end_disabled(dr);
end
-- v1.4.0 'Not enough MP' warning: switch and color.
nomp_edit = function ()
    local s = rt.s;
    cb('Show Not enough MP on spells##mp_check', 'mp_check');
    tip('Replaces the timer / Ready of a spell row with "Not enough MP" while your MP is below what the spell costs right now. Counts Manafont, Manawell, Light / Dark Arts, Penury and Parsimony. /pxi recast mp shows the numbers.');
    local dm = begin_disabled(not s.mp_check);
    local c = s.nomp_rgb;
    if (ui.ColorEdit3 ~= nil) then
        REF_COL[1], REF_COL[2], REF_COL[3] = c[1] / 255, c[2] / 255, c[3] / 255;
        if (ui.ColorEdit3('Not enough MP color##nomp_rgb', REF_COL)) then
            for i = 1, 3 do local v = floor((tonumber(REF_COL[i]) or 0) * 255 + 0.5); c[i] = max(0, min(255, v)); end
            mark_dirty();
        end
    else
        for i, nm in ipairs({ 'Red##nomp_r', 'Green##nomp_g', 'Blue##nomp_b' }) do
            REF_I[1] = c[i];
            if (ui.SliderInt(nm, REF_I, 0, 255)) then c[i] = max(0, min(255, floor(REF_I[1] + 0.5))); mark_dirty(); end
        end
    end
    same();
    if (ui.Button('Reset##nomp_reset')) then set_rgb(s, 'nomp_rgb', NOMP_DEF); mark_dirty(); end
    end_disabled(dm);
end
-- header texture styles (themes with more than one): labels for the combo, cached with their ## ids
local STYLE_LABELS = {
    bastok = { works = 'Metalworks', mines = 'Rock mine', brushed = 'Brushed steel', rust = 'Rusted steel', rivets = 'Rivets & seams (brass)', white = 'Rivets & seams (white)' },
    windurst = { tower = 'Moon tower above the canopy', sea = 'Sea from the cliff', cloth = 'Woven cloth' },
    dragoon = { keeled = 'Keeled scales', scales = 'Round scales' },
};
local STYLE_SEL = {};
local function style_sel(short, nm)
    local t = STYLE_SEL[short];
    if (t == nil) then t = {}; STYLE_SEL[short] = t; end
    local v = t[nm];
    if (v == nil) then v = ((STYLE_LABELS[short] or {})[nm] or nm) .. '##tex_style_' .. nm; t[nm] = v; end
    return v;
end
local FLASH_STYLES = { { 'None##flash_none', nil }, { 'Fill##flash_fill', 'fill' }, { 'Outline##flash_outline', 'outline' }, { 'Both##flash_both', 'both' } };
local function use_drop_pack(name)
    local s = rt.s;
    s.drop_pack = name or '';
    icons.set_drop_pack(s.drop_pack);       -- old textures are released next frame
    rt.icon_counts = nil; rt.dp_missing = nil; mark_dirty();
end
local function drop_pack_label(name)
    if (name == nil or name == '') then return icons.LOOSE; end
    if (rt.dp_missing ~= nil and rt.dp_missing == name) then return name .. ' (not installed)'; end
    return name;
end
local function icons_body()
    local s = rt.s;
    cb('Show icons##rx_show_icons', 'icons');
    slider_i('Icon size##icon_size', 'icon_size', 16, 60);
    tip('Every icon is scaled into a square slot of this size (aspect ratio kept, centered), whatever size the PNG is.');
    -- v1.3.1: every subfolder of icons\drop is a pack, refreshed each time the combo opens
    rt.drop_packs = rt.drop_packs or scan_drop_folders();
    local dp_open = ui.BeginCombo('Icon pack##drop_pack', drop_pack_label(s.drop_pack));
    if (dp_open and not rt.dp_was_open) then rt.drop_packs = scan_drop_folders(); end   -- fresh list each time it opens
    rt.dp_was_open = dp_open;
    if (dp_open) then
        if (ui.Selectable((icons.LOOSE or 'Loose files') .. '##drop_pack_loose', s.drop_pack == '')) then use_drop_pack(''); end
        for i, pk in ipairs(rt.drop_packs) do
            -- unique ## id per row; a shared id makes every row select the first pack
            local cur = (type(s.drop_pack) == 'string') and s.drop_pack:lower() or '';
            if (ui.Selectable(pk .. '##rx_dp_' .. i, cur == pk:lower())) then use_drop_pack(pk); end
        end
        ui.EndCombo();
    end
    tip('The packs are the folders in addons\\partyramaxi\\icons\\packs (shared with the target bar and party list). HXUI packs (0.png-639.png, status ids) are matched to each spell or ability by the status it gives; XIUI packs use spells\\ and abilities\\ inside the pack. Without an icon in the pack: the fallback pack, then icons\\status, then the element or category icon.');
    local fb_open = ui.BeginCombo('Fallback pack##drop_pack2', (s.drop_pack2 == nil or s.drop_pack2 == '') and 'None'
        or (s.drop_pack2 .. ((rt.dp2_missing == s.drop_pack2) and ' (not installed)' or '')));
    if (fb_open) then
        if (ui.Selectable('None##drop_pack2_none', s.drop_pack2 == '')) then s.drop_pack2 = ''; icons.set_drop_pack2(''); rt.icon_counts = nil; mark_dirty(); end
        for i, pk in ipairs(rt.drop_packs) do
            local cur = (type(s.drop_pack2) == 'string') and s.drop_pack2:lower() or '';
            if (ui.Selectable(pk .. '##rx_dp2_' .. i, cur == pk:lower())) then s.drop_pack2 = pk; icons.set_drop_pack2(pk); rt.icon_counts = nil; rt.dp2_missing = nil; mark_dirty(); end
        end
        ui.EndCombo();
    end
    tip('Used for any spell or ability the icon pack above has no icon for.');
    same();
    if (ui.Button('Rescan##icons_rescan')) then
        icons.rescan(); rt.icon_counts = nil; rt.crest_list = nil; rt.cp_text = nil; rt.drop_packs = nil;
        if (rt.dp_missing or rt.dp2_missing) then apply_settings(); end     -- a pack copied in since: use it now
    end
    tip('Re-read the folders (new packs, new files).');
    same();
    if (ui.Button('Open folder##icons_drop_open')) then open_folder((icons.drop_root:gsub('[\\/]+$', ''))); end
    tip('Opens icons\\packs. Make one folder per pack in it, then Rescan.');
    rt.icon_counts = rt.icon_counts or icons.count();
    local c = rt.icon_counts;
    help(fmt('Pack icons: %d   Textures loaded: %d   failed: %d', c.drop or 0, icons.loaded, icons.failed));
    help('/pxi recast icons list, /pxi recast icons use <name>, /pxi recast debug icons (file used per row).');
end
-- PartyramaXI: the settings are grouped like the other modules: Look, Text, Bars, Icons (plus Pinned Abilities and General).
local function tab_look()
    local s = rt.s;
    if (section('Theme##sec_theme', true)) then
        for i, t in ipairs(themes.LIST) do
            if (ui.Selectable(THEME_LABELS[i], s.theme == t.name)) then s.theme = t.name; mark_dirty(); end
        end
        if ((themes.find(s.theme) or {}).dragoon) then
            ui.Text('Dragoon palette:'); same();
            radio('Drachen (artifact, purple)##pal_drachen', 'dragoon_palette', 'Drachen'); same();
            radio('Wyrm (relic, blue)##pal_wyrm', 'dragoon_palette', 'Wyrm');
        end
    end
    -- PartyramaXI: its Frame group follows the Theme
    if (rt.extra ~= nil and rt.extra.after_theme ~= nil) then rt.extra.after_theme(); end
    if (section('Window##sec_frame', true)) then
        local dw = begin_disabled(s.attach == true);
        slider_i('Width##width', 'width', 200, 640);
        tip('Minimum width; the window grows when text or icons need more room. Not used while it is attached above the party list: it then takes the list\'s width.');
        end_disabled(dw);
        if (s.attach) then help('Width: attached, so the party list\'s (General > Placement).'); end
        slider_f('Opacity##opacity', 'opacity', 0.2, 1.0);
    end
    if (section('Header##sec_header', true)) then
        -- PartyramaXI: the header's job text, or the whole header, can go. 2.12.2: with the crest, in Appearance
        cb('Hide the header##hide_header', 'hide_header');
        tip('Shows only the timer rows: no header bar with jobs, crest and SP badges. The rows still hide, collapse and fade by the other rules. When everything is collapsed or idle, nothing is shown. Right-click a row for its menu; settings open with /pxi recast.');
        local dh = begin_disabled(s.hide_header);
        cb('No job text##hide_job_text', 'hide_job_text');
        tip('The header keeps its crest and SP badges but not the job / level line.');
        ui.Text('Crest:');
        radio('Theme crest##crest_theme', 'crest_source', 'theme'); same();
        radio('Job emblem##crest_job', 'crest_source', 'job'); same();
        radio('Custom PNG##crest_custom', 'crest_source', 'custom'); same();
        radio('None##crest_none', 'crest_source', 'none');
        tip('None draws no class crest. The job line starts at the left edge.');
        local dc = begin_disabled(s.crest_source ~= 'custom');
        do
            if (ui.InputText('File##crest_file', rt.crest_buf, 260)) then s.crest_file = rt.crest_buf[1]; mark_dirty(); end
            if (ui.BeginCombo('Browse##crest_browse', s.crest_file)) then
                rt.crest_list = rt.crest_list or icons.list_crests();
                if (#rt.crest_list == 0) then help('No PNGs in icons\\crests'); end
                for i, f in ipairs(rt.crest_list) do
                    ui.PushID(i);
                    if (ui.Selectable(f .. '##crest_pick', s.crest_file == f)) then s.crest_file = f; rt.crest_buf[1] = f; mark_dirty(); end
                    ui.PopID();
                end
                ui.EndCombo();
            end
            same();
            if (ui.Button('Open folder##crest_open')) then open_folder(icons.base .. 'crests'); rt.crest_list = nil; rt.cp_text = nil; end
            cb('Per-job file (crests\\<job>.png) first##crest_per_job', 'crest_per_job');
            ui.Text('Mask:'); same();
            radio('Circle##mask_circle', 'crest_mask', 'circle'); same();
            radio('Square##mask_square', 'crest_mask', 'square'); same();
            radio('None##mask_none', 'crest_mask', 'none');
            local jab = data.job_abbr(data.state.main);
            if (rt.cp_file ~= s.crest_file or rt.cp_job ~= jab or rt.cp_per ~= s.crest_per_job or rt.cp_text == nil) then
                rt.cp_file, rt.cp_job, rt.cp_per = s.crest_file, jab, s.crest_per_job;
                local path = icons.crest_path(s, jab);
                rt.cp_text = path and ('Using ' .. path) or 'No crest file found; the theme crest is drawn instead.';
            end
            help(rt.cp_text);
        end
        end_disabled(dc);
        local dn = begin_disabled(s.crest_source == 'none'); slider_i('Crest size##crest_size', 'crest_size', 20, 72); end_disabled(dn);
        end_disabled(dh);
    end
    if (section('Header texture##sec_texture', false)) then
        local dhh = begin_disabled(s.hide_header);        -- 2.12.2: no header, no texture
        cb('Header texture##header_texture', 'header_texture');
        tip('Regalia lattice, Bastok rivets, Windurst weave, Voidwatch scanlines, Dragoon scales.');
        local dt = begin_disabled(not s.header_texture);       -- PartyramaXI: greyed out instead of hidden
        slider_f('Texture intensity##texture_strength', 'texture_strength', 0.05, 1.0);
        local tdef = themes.find(s.theme);
        if (tdef ~= nil) then
            local sl = themes.STYLE_LIST[tdef.short];
            if (sl ~= nil and #sl > 1) then
                local cur = themes.style_for(tdef.short, s);
                local lab = STYLE_LABELS[tdef.short];
                if (ui.BeginCombo('Texture style##tex_style', (lab and lab[cur]) or cur)) then
                    for i = 1, #sl do
                        if (ui.Selectable(style_sel(tdef.short, sl[i]), sl[i] == cur)) then s[themes.STYLE_KEY[tdef.short]] = sl[i]; mark_dirty(); end
                    end
                    ui.EndCombo();
                end
                tip('Only the header pattern changes. The tile files for every style are in icons\\fx.');
            end
            if (sl ~= nil) then
                help(rt.fx_on and 'Texture: pre-rendered tiles (fast).'
                    or 'Texture: vector fallback (slower). Copy this style\'s tile files into addons\\partyramaxi\\icons\\fx.');
            end
        end
        end_disabled(dt);
        end_disabled(dhh);
    end
    if (section('Outer glow##sec_glow', false)) then
        cb('Outer glow##glow', 'glow');
        local d = begin_disabled(not s.glow); slider_f('Glow intensity##glow_strength', 'glow_strength', 0.05, 1.0); end_disabled(d);
    end
end
local function tab_text()
    local s = rt.s;
    if (section('Font##sec_font', true)) then
        if (ui.BeginCombo('Font##font', s.font)) then
            rt.font_list = rt.font_list or fonts.scan(X.path);
            for i, f in ipairs(rt.font_list) do
                f.label = f.label or (f.name .. '##font_' .. i);
                if (ui.Selectable(f.label, s.font == f.name)) then s.font = f.name; mark_dirty(); end
            end
            ui.EndCombo();
        end
        tip('Theme default uses the theme fonts; files in addons\\partyramaxi\\fonts are listed too.');
        if (not fonts.supported()) then help('This Ashita build cannot load font files; the default font is scaled instead.'); end
    end
    if (section('Font sizes##sec_fonts', true)) then
        slider_i('Font size (base)##font_size', 'font_size', 10, 36);
        tip('Base size; every element set to 0 (automatic) follows it.');
        slider_f('Master scale##fs_scale', 'fs_scale', 0.5, 2.0, '%.2fx');
        tip('Multiplies every text size below. Sizes are always kept within 8-36 px.');
        fs_slider('Job line##fs_job', 'fs_job', 'The job/level line in the header.');
        fs_slider('Group headings##fs_group', 'fs_group', 'SPELLS / ABILITIES headings and the "+N more" line.');
        fs_slider('Row names##fs_name', 'fs_name', 'Spell and ability names in the rows.');
        fs_slider('Row times##fs_time', 'fs_time', 'The time column (and Ready).');
        fs_slider('SP badges##fs_badge', 'fs_badge', 'SP1/SP2 header badges.');
        fs_slider('Idle line##fs_idle', 'fs_idle', '"All recasts ready".');
        if (ui.Button('Reset font sizes##fs_reset')) then
            s.fs_scale = 1.0;
            for k in pairs(FS_KEYS) do s[k] = 0; end
            mark_dirty();
        end
        help(fmt('Now: job %d, groups %d, names %d, times %d, badges %d, idle %d, perf %d px',
            L.ssize or 0, L.gfs or 0, L.nfs or 0, L.tfs or 0, L.bf or 0, L.ifs or 0, L.pfs or 0));
    end
end
local function tab_bars()
    local s = rt.s;
    if (section('Effects level##sec_fxlevel', true)) then
        ui.Text('Level:');
        same(); radio('Off##fx_off', 'fx_level', 'off');
        same(); radio('Subtle##fx_subtle', 'fx_level', 'subtle');
        same(); radio('Full##fx_full', 'fx_level', 'full');
        tip('Off: none of the effects below. Subtle: softer gloss, heat shift and Ready sweep only. Full: everything switched on below. Safe drawing turns all of them off.');
        local d = begin_disabled(s.fx_level == 'off');
        slider_f('Effect strength##fx_strength', 'fx_strength', 0.1, 1.0);
        tip('How bright the gloss, shine, spark and sweep are.');
        end_disabled(d);
        help('Moving effects also need Animate on (General).');
    end
    if (section('Rows and timer bars##sec_rows', true)) then
        cb('Timer bars##show_bars', 'show_bars');
        local db = begin_disabled(not s.show_bars); slider_i('Bar height##bar_height', 'bar_height', 2, 16); end_disabled(db);
        cb('Compact mode##compact', 'compact'); same(); cb('Tint pinned rows##pin_tint', 'pin_tint');
        cb('Gold tenths under 10 s##gold_tenths', 'gold_tenths');
        tip('Shows 9.4 style times in gold for the last ten seconds.');
        ready_color_edit();
        nomp_edit();
    end
    if (section('Bar effects##sec_barfx', true)) then
        local d = begin_disabled(s.fx_level == 'off');
        cb('Gloss##fx_gloss', 'fx_gloss');
        tip('A bright top edge and darker lower edge on every timer bar.');
        cb('Moving shine##fx_shine', 'fx_shine');
        tip('A band of light that glides across each bar now and then. Full level only.');
        local d1 = begin_disabled(not s.fx_shine); slider_f('Seconds between shines##fx_shine_period', 'fx_shine_period', 2.0, 12.0, '%.1f'); end_disabled(d1);
        cb('Leading-edge spark##fx_spark', 'fx_spark');
        tip('A glint at the end of the filled bar. Full level only.');
        local d2 = begin_disabled(not s.fx_spark);
        slider_f('Spark size##fx_spark_size', 'fx_spark_size', 0.1, 1.0, '%.2f');
        slider_f('Spark strength##fx_spark_strength', 'fx_spark_strength', 0.1, 1.0, '%.2f');
        end_disabled(d2);
        cb('Heat shift##fx_heat', 'fx_heat');
        tip('The filled bar eases into amber, then red-orange, as the timer runs low (under 35%) and pulses in the last 5 seconds. Works on every theme.');
        end_disabled(d);
    end
    if (section('Ready flash##sec_flash', true)) then
        ui.Text('Style:');
        for i, f in ipairs(FLASH_STYLES) do
            same();
            local active = (f[2] == nil and not s.ready_flash) or (f[2] ~= nil and s.ready_flash and s.flash_style == f[2]);
            if (ui.RadioButton(f[1], active)) then
                if (f[2] == nil) then s.ready_flash = false; else s.ready_flash = true; s.flash_style = f[2]; end
                mark_dirty();
            end
        end
        tip('None: no flash. Fill: the row pulses. Outline: a bright border pulses inside the row. Both: fill and outline.');
        local d = begin_disabled(not s.ready_flash);
        slider_f('Flash intensity##flash_strength', 'flash_strength', 0.1, 1.0);
        tip('How bright the Ready pulse is.');
        slider_f('Flash seconds##flash_secs', 'flash_secs', 0.5, 10, '%.1f');
        tip('How long a row keeps flashing Ready after its timer ends.');
        end_disabled(d);
    end
    if (section('Ready moment##sec_readyfx', true)) then
        local d = begin_disabled(s.fx_level == 'off');
        cb('Ready gloss sweep##fx_sweep', 'fx_sweep');
        cb('Icon pop and flash##fx_ping', 'fx_ping');
        local d3 = begin_disabled(not s.fx_ping);
        ui.Text('Icon flash:'); same();
        radio('Border##fx_ps_border', 'fx_ping_style', 'border'); same();
        radio('Diagonal swipe##fx_ps_swipe', 'fx_ping_style', 'swipe'); same();
        radio('Both##fx_ps_both', 'fx_ping_style', 'both');
        tip('Border: a streak runs around the icon edge. Swipe: a quick diagonal glint across the icon, kept inside the icon image so any icon shape works.');
        end_disabled(d3);
        tip('The icon pop and flash need the Full level.');
        end_disabled(d);
        help('These play during the Ready flash, so Ready flash: None turns them off too.');
    end
end
local function tab_icons()
    local s = rt.s;
    if (section('Icons##sec_icons', true)) then
    icons_body();
    end
end

local function tab_general()
    local s = rt.s;
    -- PartyramaXI: Visibility split into Window, When it shows and Rows
    if (section('Window##sec_win', true)) then
        cb('Lock window##locked', 'locked');
        tip('Separate window only: stops it being dragged. Attached, it follows the party list.');
        cb('Pinned Abilities button and right-click menus##quick_menu', 'quick_menu');
        tip('A small Pinned Abilities button appears on the header while the mouse is over it, and right-click on the header opens Settings > Pinned Abilities. Right-click a row to pin, unpin or hide that spell or ability. Works while the window is locked.');
        cb('Click group headers to collapse##collapsible', 'collapsible');
    end
    if (section('When it shows##sec_show', true)) then
        cb('Hide during cutscenes##hide_cutscene', 'hide_cutscene');
        tip('Hides the tracker while a cutscene or NPC event is playing and fades it back in afterwards. /pxi recast cutscene shows how events are detected.');
        cb('Hide when not in battle##hide_no_combat', 'hide_no_combat');
        tip('Hides the tracker unless you or a party member is engaged, or a monster claimed by the party is nearby. It stays up for a few seconds after a fight ends. /pxi recast combat shows the current state.');
        ui.Text('When nothing is on recast:');
        radio('Collapse to header##idle_collapse', 'idle_mode', 'collapse'); same();
        radio('Hide##idle_hide', 'idle_mode', 'hide'); same();
        radio('Show "All recasts ready"##idle_show', 'idle_mode', 'show');
        cb('Keep pinned entries visible##keep_pinned', 'keep_pinned');
        tip('Pinned spells/abilities always stay in the list: Ready when off recast, greyed "Not available" when not usable now. While any is shown the window does not collapse or hide; "Show" still adds its line below them.');
        cb('Hide when nothing on recast even if pinned##hide_idle_pinned', 'hide_idle_pinned');
        tip('Precedence: this option > Keep pinned entries visible > "When nothing is on recast". When it is on and nothing is counting down (Ready flashes finished), the tracker hides completely, even with kept pinned rows and whatever the idle mode is. It comes back as soon as anything goes on recast; pinned rows then show again.');
        if (rt.idle_rep == nil or rt.now - (rt.idle_rep_at or -1) >= 0.5) then   -- twice a second, not every frame
            rt.idle_rep, rt.idle_rep_at = idle_report(), rt.now;
        end
        for _, l in ipairs(rt.idle_rep) do help(l); end
    end
    if (section('Rows##sec_maxrows', true)) then
        help('Maximum rows (0 = no limit):');
        slider_i('Spells##max_spells', 'max_spells', 0, 50);
        tip('Rows over the limit fold into a "+N more" line. Pinned rows come first, then the least time left.');
        slider_i('Abilities##max_abilities', 'max_abilities', 0, 50);
        tip('Rows over the limit fold into a "+N more" line. Pinned rows come first, then the least time left.');
        slider_i('Total (both groups)##max_total', 'max_total', 0, 100);
        tip('Combined cap after the per-group caps. Pinned spells, then pinned abilities, then the least time left.');
    end
    if (section('Animation##sec_anim', false)) then
        cb('Animate resize##animate', 'animate');
        local da = begin_disabled(not s.animate); slider_f('Animation speed##anim_speed', 'anim_speed', 0.25, 4.0, '%.2fx'); cb('Rows slide and fade##row_motion', 'row_motion'); end_disabled(da);
    end
    if (section('SP1 / SP2##sec_sp', true)) then
        ui.Text('Show SP1/SP2:'); same();
        if (radio('Header badges##sp_header', 'sp_display', 'header')) then data.sp_rows = false; data.update_sp_shown(); rt.known = nil; end
        tip('Signs at the right of the header (Ready / cooldown).');
        same();
        if (radio('Ability rows##sp_list', 'sp_display', 'list')) then data.sp_rows = true; data.update_sp_shown(); rt.known = nil; end
        tip('Normal rows in the Abilities list: timer, pin and filter like any ability (and they keep the window busy while on recast).');
        local d = begin_disabled(s.sp_display ~= 'header');
        if (true) then
            cb('Badge tooltips##sp_hover', 'sp_hover'); same(); cb('Time in badge on cooldown##sp_show_time', 'sp_show_time');
            ui.Text('SP2 badge:'); same();
            if (radio('Auto (level 96+)##sp2_auto', 'sp2_mode', 'auto')) then data.sp2_mode = 'auto'; end same();
            if (radio('Always (muted if not available)##sp2_always', 'sp2_mode', 'always')) then data.sp2_mode = 'always'; end same();
            if (radio('Never##sp2_never', 'sp2_mode', 'never')) then data.sp2_mode = 'never'; end
            data.update_sp_shown();
        else
            help('Badge settings apply to header badges only.');
        end
        end_disabled(d);
    end
    if (section('Debug##sec_adv', false)) then      -- PartyramaXI: was Advanced
        cb('Safe drawing (no glow, texture, badge effects or clip rects)##safe_mode', 'safe_mode');
        tip('Use this if the tracker ever draws stretched across the screen; /pxi recast safe toggles it too.');
        ui.Text('Timer units (change only if /pxi recast debug shows wrong times):');
        if (radio('Abilities 1/60 s##ua60', 'units_ability', 60)) then data.units.ability = 60; end same();
        if (radio('Abilities seconds##ua1', 'units_ability', 1)) then data.units.ability = 1; end
        if (radio('Spells 1/60 s##us60', 'units_spell', 60)) then data.units.spell = 60; end same();
        if (radio('Spells seconds##us1', 'units_spell', 1)) then data.units.spell = 1; end
        fs_slider('Perf overlay text size##fs_perf', 'fs_perf', 'The /pxi recast perf overlay.');
    end
    ui.Separator();
    if (ui.Button('Save##save')) then settings.save(X.alias); rt.dirty_at = nil; msg('Settings saved.'); end
    same();
    if (ui.Button('Reset all settings##reset')) then settings.reset(X.alias); msg('Settings reset to defaults.'); end
    help('Settings are saved per character (config\\addons\\partyramaxi\\<character>\\recast.lua).');
end

local TABS = {
    { 'General##tab_general', tab_general },
    { 'Pinned Abilities##tab_filters', tab_filters },
    { 'Appearance##tab_appearance', tab_look },
    { 'Text##tab_text', tab_text },
    { 'Bars##tab_bars', tab_bars },
    { 'Icons##tab_visuals', tab_icons },
};
open_filters = function ()
    rt.tab_req = 'tab_filters';
    if (M.open_ui ~= nil) then M.open_ui('tab_filters'); end
end
local safe_banner, begin_tab, config_closed;
do
local REF_TABOPEN = { true };
-- tab item that can be forced selected for one frame (ImGuiTabItemFlags_SetSelected); falls back to the plain call
begin_tab = function (label, want)
    -- PartyramaXI: the sub-tab colors of its settings window (M.tab_item, set by pxiui)
    local item = M.tab_item or ui.BeginTabItem;
    if (want and ui.BeginTabItem ~= nil) then
        REF_TABOPEN[1] = true;
        local ok, res = pcall(item, label, REF_TABOPEN, flag('ImGuiTabItemFlags_SetSelected', 2));
        if (ok) then return res; end
    end
    return item(label);
end
local SAFE_GOLD = { 1.0, 0.82, 0.25, 1.0 };
-- shown above every tab while safe drawing is on (it hides glow, header texture and badge effects)
safe_banner = function ()
    local s = rt.s;
    if (not s.safe_mode) then return; end
    local txt = 'SAFE DRAWING IS ON: glow, header texture, badge effects and the bar/Ready effects are hidden. If the tracker looks correct on screen, turn safe drawing off to get them back.';
    if (ui.TextColored ~= nil) then
        if (ui.TextWrapped ~= nil and ui.PushStyleColor ~= nil and ui.PopStyleColor ~= nil) then
            ui.PushStyleColor(0, SAFE_GOLD);       -- ImGuiCol_Text
            ui.TextWrapped(txt);
            ui.PopStyleColor(1);
        else
            ui.TextColored(SAFE_GOLD, 'SAFE DRAWING IS ON: effects hidden. If the tracker looks correct, turn it off.');
        end
    else
        ui.Text(txt);
    end
    if (ui.Button('Turn safe drawing off##safe_banner_off')) then
        s.safe_mode = false; settings.save(X.alias); rt.dirty_at = nil; msg('Safe drawing off: glow, texture and badge effects restored.');
    end
    tip('Same as /pxi recast safe off. If the tracker draws stretched across the screen, turn it back on with /pxi recast safe on.');
    ui.Separator();
end
end   -- do (safe banner / tab helper)
-- The settings window closed (or the Recasts tab is no longer shown): drop the lists it built and save.
config_closed = function ()
    rt.cfg[1] = false;
    rt.known, rt.font_list, rt.crest_list, rt.packs, rt.icon_counts = nil, nil, nil, nil, nil;
    if (rt.dirty_at) then settings.save(X.alias); rt.dirty_at = nil; end
end
-- Why the tracker is not on screen right now (nil = it is, or should be).
function M.hidden_reason()
    local s = rt.s;
    if (s == nil) then return nil; end
    if (not s.enabled) then return 'The tracker is off (the Enabled button above).'; end

    if (not rt.hidden) then return nil; end
    if (rt.nocombat and not rt.cutscene) then return 'The tracker is hidden: nobody in the party is in battle and "Hide when not in battle" is on.'; end
    if (rt.cutscene) then return 'The tracker is hidden: a cutscene/event is playing and "Hide during cutscenes" is on.'; end
    return s.hide_idle_pinned and 'The tracker is hidden: nothing is on recast and "Hide when nothing on recast even if pinned" is on.' or 'The tracker is hidden: nothing is on recast and "When nothing is on recast" is Hide.';
end
-- PartyramaXI: the party list's background and border drawn as this theme's frame (no header band: the
-- list's group titles sit on its top edge). Screen rect, alpha 0-1. Returns false when there is nothing to draw with.
local TP_SAVE = {};
function M.theme_panel(dl, x0, y0, x1, y1, alpha)
    local s = rt.s;
    if (s == nil or dl == nil) then return false; end
    if (rt.th == nil or rt.th_name ~= s.theme or rt.th_pal ~= s.dragoon_palette) then
        rt.th = themes.resolve(s.theme, s.dragoon_palette); rt.th_name, rt.th_pal = s.theme, s.dragoon_palette;
    end
    local w, h = x1 - x0, y1 - y0;
    if (rt.th == nil or not (w >= 8 and h >= 8)) then return rt.th ~= nil; end
    local g = (themes.GLOW_SIZE or 10) + 2;
    -- the drawing state is put back after: this can run inside the tracker's own frame (its "party list" frame)
    local sv = TP_SAVE;
    sv[1], sv[2], sv[3], sv[4], sv[5], sv[6], sv[7], sv[8], sv[9] = D.dl, D.ox, D.oy, D.alpha, D.bx0, D.by0, D.bx1, D.by1, D.no_clip;
    D.no_clip = s.safe_mode;
    D.begin(dl, x0, y0, alpha or 1, -g, -g, w + g, h + g);
    local glow_k = (s.glow and not s.safe_mode) and s.glow_strength or 0;
    local ok, e = pcall(themes.draw_frame, rt.th, w, h, 0, false, (type(glow_k) == 'number') and glow_k or 0, 0, nil);
    D.dl, D.ox, D.oy, D.alpha, D.bx0, D.by0, D.bx1, D.by1, D.no_clip = sv[1], sv[2], sv[3], sv[4], sv[5], sv[6], sv[7], sv[8], sv[9];
    if (not ok) then error(e, 0); end
    return true;
end
-- RecastXI's own settings tabs, drawn inside the PartyramaXI settings window (RecastXI tab).
function M.config_body(extra)
    if (rt.s == nil) then return; end
    rt.cfg[1] = true; rt.cfg_frame = rt.frame; rt.extra = extra;
    safe_banner();
    -- 2.9.3: drawn straight into the settings window (no fixed-size scroll box); the window itself scrolls when tall.
    if (ui.BeginTabBar ~= nil and ui.BeginTabItem ~= nil) then
        if (ui.BeginTabBar('##rx_tabs')) then
            for _, t in ipairs(TABS) do
                if (begin_tab(t[1], rt.tab_req ~= nil and t[1]:find('##' .. rt.tab_req, 1, true) ~= nil)) then
                    -- PartyramaXI: its own groups lead General (placement) and Appearance (frame, pictures)
                    local pre = extra and extra[t[1]:match('##(.*)$')];
                    if (pre ~= nil) then pre(); end
                    t[2](); ui.EndTabItem();
                end
            end
            rt.tab_req = nil;
            ui.EndTabBar();
        end
    else
        for i, t in ipairs(TABS) do
            if (ui.CollapsingHeader(t[1], (i == 1) and flag('ImGuiTreeNodeFlags_DefaultOpen', 32) or 0)) then t[2](); end
        end
    end
    while (font_depth > 0) do pop_font(); end
end
-- PartyramaXI: the settings search draws every tab's body in turn (no tab bar); set_tab(name) names the tab.
function M.config_search(extra, set_tab)
    if (rt.s == nil) then return; end
    rt.cfg[1] = true; rt.cfg_frame = rt.frame; rt.extra = extra;
    for _, t in ipairs(TABS) do
        set_tab((t[1]:gsub('##.*$', '')));
        local pre = extra and extra[t[1]:match('##(.*)$')];
        if (pre ~= nil) then pre(); end
        t[2]();
    end
    while (font_depth > 0) do pop_font(); end
end

--[[ ------------------------------------------------------------------ /pxi recast perf overlay ]]
local PERF_POS, PERF_SIZE, PERF_PAD = { 0, 0 }, { 0, 0 }, { 6, 4 };
local perf_txt, perf_placed, perf_fs = nil, false, -1;
--[[
* v1.1.2: the overlay window gets an explicit, bounded size every frame (Cond_Always) instead of
* AlwaysAutoResize, and a finite, non-negative first position. It only uses imgui.Text: no draw
* list, no clip rects. The text is measured only when it changes (twice a second).
--]]
local function render_perf()
    local s = rt.s; if (s == nil) then return; end
    local txt = PF.overlay_text(rt.now);
    local pf = L.pfs or 13;
    if (txt ~= perf_txt or pf ~= perf_fs) then
        perf_txt, perf_fs = txt, pf;
        push_font(rt.f_num, pf);
        local tw, th = xy(imgui.CalcTextSize(txt));
        pop_font();
        tw, th = tonumber(tw) or 400, tonumber(th) or 14;
        PERF_SIZE[1] = max(60, min(1600, tw + 2 * PERF_PAD[1] + 2));
        PERF_SIZE[2] = max(16, min(120, th + 2 * PERF_PAD[2] + 2));
    end
    if (not perf_placed) then
        perf_placed = true;
        local px, py = s.x, s.y + rt.win_h + 4;
        if (not (px >= 0 and px < 8192)) then px = 0; end
        if (not (py >= 0 and py < 8192)) then py = 0; end
        PERF_POS[1], PERF_POS[2] = px, py;
        imgui.SetNextWindowPos(PERF_POS, flag('ImGuiCond_Always', 1));
    end
    imgui.SetNextWindowSize(PERF_SIZE, flag('ImGuiCond_Always', 1));
    local f = rt.perf_flags;
    if (f == nil) then
        f = bit.bor(flag('ImGuiWindowFlags_NoTitleBar', 1), flag('ImGuiWindowFlags_NoResize', 2), flag('ImGuiWindowFlags_NoScrollbar', 8),
            flag('ImGuiWindowFlags_NoCollapse', 32), flag('ImGuiWindowFlags_NoFocusOnAppearing', 4096), flag('ImGuiWindowFlags_NoNav', 0),
            flag('ImGuiWindowFlags_NoSavedSettings', 256));
        rt.perf_flags = f;
    end
    local sv = rawget(_G, 'ImGuiStyleVar_WindowPadding');
    if (type(sv) == 'number') then imgui.PushStyleVar(sv, PERF_PAD); end
    if (imgui.Begin('hpp Recasts perf##hpp_rx_perf', nil, f)) then
        push_font(rt.f_num, pf);
        imgui.Text(txt);
        pop_font();
    end
    imgui.End();
    if (type(sv) == 'number') then imgui.PopStyleVar(1); end
end

local function set_perf(on, overlay)
    if (on) then
        if (not PF.on) then PF.start(); end
        if (overlay and not PF.overlay) then perf_placed = false; end
        PF.overlay = overlay or PF.overlay;
    else
        PF.stop();
    end
    perf_on = PF.on;
end

--[[ ------------------------------------------------------------------ PartyramaXI hooks ]]
-- Attach above the party list, or detach to its own window where it is now (so it does not jump).
function M.set_attach(on)
    local s = rt.s; if (s == nil) then return; end
    if (s.attach and not on and rt.win_x ~= nil) then s.x, s.y = floor(rt.win_x + 0.5), floor(rt.win_y + 0.5); end
    s.attach = on == true; rt.place = true; mark_dirty();
end
function M.settings() return rt.s; end
-- PartyramaXI: Reset everything resets RecastXI's settings too
function M.reset() if (rt.s ~= nil) then settings.reset(X.alias); end end
function M.tab_req(t) rt.tab_req = t; end
function M.mark_dirty() if (rt.s ~= nil) then mark_dirty(); end end
function M.testing() return data.state.test == true; end
function M.set_test(on) data.set_test(on == true, rt.now); rt.known = nil; rt.next_scan = 0; end
-- After an error inside the tracker window: close what is still open so ImGui's stacks stay balanced.
function M.recover()
    while (font_depth > 0) do pop_font(); end
    if (rt.in_win) then
        rt.in_win = false;
        if (D.dl ~= nil and D.clips ~= nil) then D.dl = nil; end
        imgui.End();
        if ((rt.pushed or 0) > 0) then imgui.PopStyleVar(rt.pushed); end
    end
end
function M.save() if (rt.s ~= nil) then settings.save(X.alias); rt.dirty_at = nil; end end

--[[ ------------------------------------------------------------------ events ]]
local function on_settings(s)
    if (s ~= nil) then rt.s = s; end
    check_settings();
    apply_settings();
    list.clear();
    data.state.job_sig = -1;
end

-- Called from PartyramaXI's load event. base = addons\partyramaxi (no trailing slash).
function M.load(base)
    X.path = (base or ''):gsub('[\\/]+$', '');      -- icons\ and fonts\ are PartyramaXI's own folders
    rt.s = settings.load(default_settings, X.alias);
    find_event_flag();
    check_settings();
    apply_settings();
    settings.register(X.alias, 'partyramaxi_recast_update', on_settings);
    -- v1.1.2 safe start: the first load of this version starts in safe drawing (plain frame, no
    -- glow/texture/badge effects, no custom clip rects), so the 1.1.0/1.1.1 full-screen stretch can
    -- never cover the screen again on load. One /pxi recast safe off brings the effects back for good.
    if (not rt.s.safe_start_done) then
        rt.s.safe_start_done = true; rt.s.safe_mode = true; settings.save(X.alias);
        msg('1.1.2 starts in safe drawing once (no glow, header texture or badge effects). If the tracker looks right, type /pxi recast safe off to bring the effects back.');
    end
end

function M.unload()
    icons.release_all();
    if (rt.s ~= nil) then settings.save(X.alias); end
end

-- /pxi recast debug rect: every coordinate the drawing depends on (read on request only).
local function rect_report()
    local n = function (v) return (type(v) == 'number') and fmt('%.1f', v) or tostring(v); end
    local lines = {
        fmt('Window corner (cursor-derived) %s,%s  size set %sx%s  draw origin %s,%s  margin %d', n(rt.win_x), n(rt.win_y),
            n(rt.win_w), n(rt.win_h), n(rt.origin_x), n(rt.origin_y), MARGIN),
        fmt('Draw guard: %d primitives skipped last frame, %d total (last at %s,%s - %s,%s); %d clip rects last frame (all intersected)',
            D.skipped, D.skipped_total, n(D.last_skip[1]), n(D.last_skip[2]), n(D.last_skip[3]), n(D.last_skip[4]), D.clips),
        fmt('Safe drawing %s  glow %s  texture %s  hidden %s  header only %s', rt.s.safe_mode and 'ON' or 'off',
            tostring(rt.s.glow), tostring(rt.s.header_texture), tostring(rt.hidden), tostring(rt.header_only)),
    };
    -- for comparison only (never used for drawing)
    local ok, io = pcall(function () return imgui.GetIO ~= nil and imgui.GetIO() or nil; end);
    if (ok and io ~= nil) then
        local ok2, ds, fb = pcall(function () return io.DisplaySize, io.DisplayFramebufferScale; end);
        if (ok2) then
            local function v2(v) if (v == nil) then return '?'; end local x, y = xy(v); return n(x) .. 'x' .. n(y); end
            lines[#lines + 1] = fmt('io.DisplaySize %s  DisplayFramebufferScale %s  (not used for drawing)', v2(ds), v2(fb));
        end
    end
    lines[#lines + 1] = 'If the tracker still draws stretched: /pxi recast safe on. If that fixes it, report which of glow/texture/badges brings it back.';
    return lines;
end

local function print_lines(lines, limit)
    limit = limit or 40;
    for i = 1, min(#lines, limit) do msg(lines[i]); end
    if (#lines > limit) then msg(('... %d more lines.'):format(#lines - limit)); end
end

-- v1.5.0 /pxi recast pin | unpin | pins: by name (exact, or a unique part of the name)
local cmd_pin, cmd_pins;
do
local function strip_quotes(s)
    s = (s or ''):gsub('^%s+', ''):gsub('%s+$', '');
    local a, b = s:sub(1, 1), s:sub(-1);
    if (#s >= 2 and (a == '"' or a == "'") and a == b) then s = s:sub(2, -2); end
    return s;
end
local function ensure_known()
    local st = data.state;
    current_profile(false);
    if (rt.known == nil or rt.known_sig ~= st.job_sig * 2 + (st.test and 1 or 0)) then rebuild_known(); end
end
local function kind_word(key) return (key:sub(1, 1) == 's') and 'spell' or 'ability'; end
local function name_list(items, getname)
    local out = {};
    for i = 1, math.min(#items, 6) do out[i] = getname(items[i]); end
    return table.concat(out, ', ') .. ((#items > 6) and ', ...' or '');
end
-- returns the one matching entry, or nil after telling the user why
local function pick_one(items, getname, q, what)
    if (#items == 0) then err('No ' .. what .. ' matches "' .. q .. '".'); return nil; end
    if (#items > 1) then err(#items .. ' match "' .. q .. '": ' .. name_list(items, getname) .. '. Type more of the name.'); return nil; end
    return items[1];
end
cmd_pin = function (arg, pin)
    local q = strip_quotes(arg);
    if (q == '') then err(pin and 'Usage: /pxi recast pin <spell or ability name>' or 'Usage: /pxi recast unpin <name>'); return; end
    local ql = q:lower();
    local p = edit_profile();
    if (pin) then
        ensure_known();
        local exact, part = {}, {};
        for _, grp in ipairs({ 'spells', 'abilities' }) do
            for _, e in ipairs(rt.known[grp]) do
                if (e.lname == ql) then exact[#exact + 1] = e; elseif (e.lname:find(ql, 1, true)) then part[#part + 1] = e; end
            end
        end
        local e = pick_one((#exact > 0) and exact or part, function (x) return x.name .. ' (' .. kind_word(x.key) .. ')'; end, q, 'known spell or ability');
        if (e == nil) then return; end
        if (prof.pin_index(p, e.key) ~= nil) then msg(e.name .. ' is already pinned. (/pxi recast unpin ' .. e.name .. ' removes it.)'); return; end
        prof.toggle_pin(p, e.key); mark_dirty();
        msg('Pinned ' .. e.name .. ' (' .. kind_word(e.key) .. '). Profile: ' .. tostring(rt.prof_key) .. '.');
    else
        local exact, part = {}, {};
        for _, grp in ipairs({ 'spells', 'abilities' }) do
            for _, key in ipairs(p.pins[grp] or {}) do
                local nm = key_name(key);
                local item = { key = key, name = nm };
                if (nm:lower() == ql) then exact[#exact + 1] = item; elseif (nm:lower():find(ql, 1, true)) then part[#part + 1] = item; end
            end
        end
        local e = pick_one((#exact > 0) and exact or part, function (x) return x.name; end, q, 'pinned entry');
        if (e == nil) then return; end
        prof.toggle_pin(p, e.key); mark_dirty();
        msg('Unpinned ' .. e.name .. '.');
    end
end
cmd_pins = function ()
    current_profile(false);
    local p = edit_profile();
    local any = false;
    for _, grp in ipairs({ 'spells', 'abilities' }) do
        local names = {};
        for i, key in ipairs(p.pins[grp] or {}) do names[i] = i .. '. ' .. key_name(key); end
        if (#names > 0) then any = true; msg('Pinned ' .. grp .. ' (' .. tostring(rt.prof_key) .. '): ' .. table.concat(names, ', ')); end
    end
    if (not any) then msg('Nothing pinned in profile ' .. tostring(rt.prof_key) .. '. /pxi recast pin <name>, or right-click a row.'); end
end

end   -- do (pin command helpers)

local HELP = {
    '/pxi recast - open the RecastXI tab of the settings window',
    '/pxi recast lock | unlock - lock the window in place',
    '/pxi recast test - toggle sample timers',
    '/pxi recast cutscene [on|off] - hide the tracker during cutscenes (no argument: show status)',
    '/pxi recast combat [on|off] - hide the tracker when not in battle (no argument: show status)',
    '/pxi recast pinned - open settings on the Pinned Abilities tab (also: right-click the header)',
    '/pxi recast pin <name> | unpin <name> | pins - pin a spell or ability by name (or right-click its row)',
    '/pxi recast mp [on|off] - "Not enough MP" on spell rows (no argument: show MP, active cost effects and spell costs)',
    '/pxi recast theme <regalia|bastok|windurst|voidwatch|dragoon> - switch theme',
    '/pxi recast palette <drachen|wyrm> - Dragoon Forever palette',
    '/pxi recast debug - raw recast slots and units',
    '/pxi recast debug icons - icon lookup for the rows on screen',
    '/pxi recast icons list - icon packs found in icons\\packs',
    '/pxi recast icons use <name> - switch icon pack (default = loose files)',
    '/pxi recast debug idle - idle state and what keeps the tracker busy',
    '/pxi recast perf - toggle the frame-time overlay (avg / 5 s max / frames)',
    '/pxi recast perf report - one chat line with the numbers and a breakdown',
    '/pxi recast safe [on|off] - plain drawing: no glow, texture, badge effects or clip rects',
    '/pxi recast debug rect - window origin/size, draw guard and clip counts (for display bugs)',
    '/pxi recast reset - reset all settings (this character)',
};

-- /pxi recast <...>: args[1] = '/pxi recast', args[2] = the sub-command (PartyramaXI shifts them).
function M.command(args)
    if (rt.s == nil) then return; end
    local a = (args[2] or 'config'):lower();
    local s = rt.s;
    if (a == 'config' or a == 'settings' or a == 'show') then
        if (M.open_ui ~= nil) then M.open_ui(nil); end
    elseif (a == 'on' or a == 'off') then
        s.enabled = (a == 'on'); settings.save(X.alias); msg(s.enabled and 'Recast tracker on.' or 'Recast tracker off.');
    elseif (a == 'attach' or a == 'detach') then
        M.set_attach(a == 'attach'); settings.save(X.alias); msg(s.attach and 'Attached above the party list.' or 'Separate window (drag it where you want it).');
    elseif (a == 'lock' or a == 'unlock') then
        s.locked = (a == 'lock'); settings.save(X.alias); msg(s.locked and 'Window locked.' or 'Window unlocked.');
    elseif (a == 'reset') then
        settings.reset(X.alias); msg('Settings reset to defaults.');
    elseif (a == 'test') then
        local on = not data.state.test;
        if (args[3] ~= nil) then on = (args[3]:lower() == 'on'); end
        data.set_test(on, rt.now); rt.known = nil; rt.next_scan = 0;
        msg(on and 'Test mode on (sample timers). /pxi recast test again to stop.' or 'Test mode off.');
    elseif (a == 'cutscene') then
        local v = (args[3] or ''):lower();
        if (v == 'on' or v == 'off') then s.hide_cutscene = (v == 'on'); settings.save(X.alias); end
        msg(fmt('Hide during cutscenes: %s. Detection: %s. In a cutscene right now: %s.', s.hide_cutscene and 'ON' or 'off',
            (ev.ptr ~= 0) and 'client event flag' or 'player status fallback (event signature not found)', in_cutscene() and 'yes' or 'no'));
    elseif (a == 'pinned' or a == 'filters') then
        open_filters();
    elseif (a == 'pin' or a == 'unpin') then
        cmd_pin(table.concat(args, ' ', 3), a == 'pin');
    elseif (a == 'pins') then
        cmd_pins();
    elseif (a == 'mp') then
        local v = (args[3] or ''):lower();
        if (v == 'on' or v == 'off') then s.mp_check = (v == 'on'); settings.save(X.alias); end
        mpc.next_at = -1; mpc.update(rt.now or 0);
        msg(fmt('Not enough MP warning: %s. MP now %d / %d%s. Cost effects: %s.', s.mp_check and 'ON' or 'off', mpc.mp, mpc.maxmp,
            mpc.known and '' or ' (not readable right now)', mpc.effects_text()));
        local n = 0;
        for _, r in ipairs(data.state.spells) do
            if (n >= 8) then break; end
            local base = mpc.spell_meta(r.id).cost;
            if (base > 0) then
                n = n + 1;
                msg(fmt('  %s: base %d MP, costs %d now%s', r.name or ('#' .. r.id), base, mpc.current_cost(r.id) or 0, mpc.short(r.id) and ' - NOT ENOUGH MP' or ''));
            end
        end
        if (n == 0) then msg('  (no spell with an MP cost is on the list right now)'); end
    elseif (a == 'combat') then
        local v = (args[3] or ''):lower();
        if (v == 'on' or v == 'off') then s.hide_no_combat = (v == 'on'); settings.save(X.alias); end
        msg(fmt('Hide when not in battle: %s. In battle right now: %s.', s.hide_no_combat and 'ON' or 'off', in_combat(rt.now or 0) and 'yes' or 'no'));
    elseif (a == 'theme') then
        local t = themes.find(table.concat(args, ' ', 3));
        if (t == nil) then err('Unknown theme. Try regalia, bastok, windurst, voidwatch or dragoon.');
        else s.theme = t.name; settings.save(X.alias); msg('Theme: ' .. t.name); end
    elseif (a == 'palette') then
        local p = ENUMS.dragoon_palette[(args[3] or ''):lower()];
        if (p == nil) then err('Palette is drachen or wyrm.'); else s.dragoon_palette = p; settings.save(X.alias); msg('Dragoon palette: ' .. p); end
    elseif (a == 'icons') then
        local sub = (args[3] or 'list'):lower();
        if (sub == 'use') then
            local want = table.concat(args, ' ', 4);
            local pk = icons.find_drop_pack(want);
            if (pk == nil and want ~= '') then
                for _, name in ipairs(scan_drop_folders()) do
                    if (name:lower() == want:lower()) then pk = name; break; end
                end
            end
            if (pk == nil) then err('No icon pack ' .. show(want) .. ' in ' .. tostring(icons.drop_root) .. ' (/pxi recast icons list).');
            else use_drop_pack(pk); rt.drop_packs = nil; settings.save(X.alias); rt.dirty_at = nil; msg('Icon pack: ' .. drop_pack_label(pk)); end
        else
            local l = scan_drop_folders();
            rt.drop_packs = l;
            local names = { (icons.LOOSE or 'Loose files') .. ((s.drop_pack == '') and ' *' or '') };
            for _, pk in ipairs(l) do names[#names + 1] = pk .. ((type(s.drop_pack) == 'string' and s.drop_pack:lower() == pk:lower()) and ' *' or ''); end
            msg('Icon packs in ' .. icons.drop_root .. ': ' .. table.concat(names, ', ') .. '  (* = in use)');
        end
    elseif (a == 'debug') then
        if ((args[3] or ''):lower() == 'icons') then
            local lines = { 'Icon folder: ' .. icons.base .. '   icon pack: ' .. drop_pack_label(s.drop_pack) .. ' (' .. icons.drop .. ')' };
            for _, g in ipairs(list.order) do
                for _, r in ipairs(g.rows) do
                    if (r.rec ~= nil and r.state ~= 'leaving' and not r.over) then
                        local path, level = icons.lookup(r.rec);
                        local e = path and icons.error_for(path) or nil;
                        local st = icons.status_of(r.rec);
                        local nw, nh = nil, nil;
                        if (path ~= nil) then nw, nh = icons.native_size(path); end
                        local size = (nw ~= nil) and fmt('  native %dx%d -> drawn in a %d px slot', nw, nh, L.isz or 0) or fmt('  slot %d px', L.isz or 0);
                        lines[#lines + 1] = fmt('%s [%s %s, res %s, status %s]: %s (%s)%s%s', r.rec.name or '?', r.rec.kind or '?', tostring(r.rec.id),
                            tostring(r.rec.res_id), st and tostring(st) or 'none', path or 'no file -> drawn placeholder', level or 'none', size, e and ('  load error: ' .. e) or '');
                    end
                end
            end
            if (#lines == 1) then lines[2] = 'Nothing on recast. Try /pxi recast test first.'; end
            print_lines(lines);
        elseif ((args[3] or ''):lower() == 'rect') then
            print_lines(rect_report());
        elseif ((args[3] or ''):lower() == 'idle') then
            print_lines(idle_report());
        else
            local st = data.state;
            msg(fmt('Job %s%d/%s%d  scans %d  clock %s  SP1 %s: %s %.0fs  SP2 %s: %s%s %.0fs (mode %s)', data.job_abbr(st.main), st.mainlv,
                data.job_abbr(st.sub), st.sublv, st.scans, rt.clock_name, st.sp[1].name, data.sp_state(1, rt.now), st.sp[1].rem,
                st.sp[2].name, st.sp[2].shown and '' or 'hidden, ', data.sp_state(2, rt.now), st.sp[2].rem, data.sp2_mode));
            print_lines(idle_report());
            print_lines(data.debug_lines());
        end
    elseif (a == 'safe') then
        local v = (args[3] or ''):lower();
        local on = not s.safe_mode;
        if (v == 'on') then on = true; elseif (v == 'off') then on = false; end
        s.safe_mode = on; settings.save(X.alias);
        msg(on and 'Safe drawing ON: no glow, header texture, badge effects or clip rects. /pxi recast safe off to restore.'
               or 'Safe drawing off: glow, texture and badge effects restored.');
    elseif (a == 'perf') then
        local sub = (args[3] or ''):lower();
        if (sub == 'report') then
            local line = PF.on and PF.report_line(rt.cfg[1]) or nil;
            if (line ~= nil) then msg('Perf: ' .. line);
            else set_perf(true, false); msg('Perf: sampling started (timer: ' .. PF.timer_name .. '). Run /pxi recast perf report again in a few seconds.'); end
        elseif (sub == 'off' or (sub ~= 'on' and PF.overlay)) then
            set_perf(false); msg('Perf overlay off, sampling stopped.');
        else
            set_perf(true, true);
            msg('Perf overlay on (timer: ' .. PF.timer_name .. '). /pxi recast perf report for a breakdown, /pxi recast perf again to stop.');
        end
    elseif (a == 'help') then
        print_lines(HELP);
    else
        err('Unknown command. /pxi recast help');
    end
end

-- Once per frame from PartyramaXI, after the party list (so M.attach_box is this frame's).
function M.present()
    if (rt.s == nil) then return; end
    if (rt.cfg[1] and (rt.cfg_frame or -10) < rt.frame - 1) then config_closed(); end   -- the Recasts tab is no longer drawn
    if (rt.clock == nil) then rt.clock, rt.clock_name = make_clock(); end
    local pon = perf_on;
    local t0 = pon and PF.now() or 0;
    rt.frame = rt.frame + 1;
    icons.flush_pending();   -- textures dropped by a rescan last frame
    rt.now = rt.clock();
    update_fonts();      -- font loads happen here, before any Begin
    local t1 = t0;
    if (rt.s.enabled) then                                -- off (the Recasts tab's Enabled button): no reads, nothing drawn
        rt.cutscene = rt.s.hide_cutscene and in_cutscene() or false;
        rt.nocombat = rt.s.hide_no_combat and not data.state.test and not in_combat(rt.now) or false;
        update_model();
        t1 = pon and PF.now() or 0;
        render_main();
    else
        rt.hidden, rt.vis.v, rt.vis.from, rt.vis.to = true, 0, 0, 0;   -- turning it on again slides it up
    end
    local t2 = pon and PF.now() or 0;
    if (rt.dirty_at ~= nil and rt.now - rt.dirty_at > 1.0 and not (imgui.IsMouseDown ~= nil and imgui.IsMouseDown(0))) then
        settings.save(X.alias); rt.dirty_at = nil;
    end
    if (pon) then
        local t3 = PF.now();
        PF_cur[PF.UPDATE] = t1 - t0;
        PF_cur[PF.CONFIG] = t3 - t2;
        PF_cur[PF.DRAW] = t3 - t1;
        PF_cur[PF.TOTAL] = t3 - t0;
        PF.commit(rt.now, rt.cfg[1]);
        if (PF.overlay) then render_perf(); end   -- the overlay itself is not counted
    end
end

-- Offline test hook (set by the test kit only).
if (rawget(_G, 'RECASTXI_TEST')) then _G.RECASTXI_RT = rt; rt.L = L; rt.validate = validate_settings; rt.PF = PF; rt.set_perf = set_perf; end

return M
