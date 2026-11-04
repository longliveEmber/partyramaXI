--[[
* Addons - Copyright (c) 2025 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

--[[
* PartyramaXI by Banedon, (c) 2026, licensed under the GNU GPL v3 or later.
* Based on hideparty 1.1 by atom0s (Ashita Development Team, GPL v3), whose native window hiding it keeps and extends:
*  - each native window (party, alliance 2, alliance 3, target, cast info) can be hidden on its own;
*  - its own pointer, party / alliance list, target bar and recast timers (RecastXI, by Banedon, built in);
*  - in-game settings window; settings saved per character;
*  - pointer checks before every write, and every hidden window is shown again on unload.
* See LICENSE (GPL-3.0) and README.md for every credit.
--]]

addon.name      = 'partyramaxi';
addon.author    = 'Banedon (based on hideparty by atom0s)';
addon.version   = '1.0.8';
addon.desc      = 'Party and alliance list, target bar, pointer and recast timers that replace the game\'s own windows.';
addon.link      = 'https://ashitaxi.com/';

require('common')
local chat     = require('chat')
local settings = require('settings')
local imgui    = require('imgui')
local ffi      = require('ffi')
local d3d8     = require('d3d8')

local defaults = require('pxidefaults')
local Win      = require('pxiwin')
local Targets  = require('pxitarget')
local Buffer   = require('pxibuffer')
local Proj     = require('pxiproj')
local Draw     = require('pxidraw')
local ui       = require('pxiui')
local Png      = require('pxipng')
local Info     = require('pxiinfo')
local Fonts    = require('pxifonts')
local Fx       = require('pxifx')
local Weak     = require('pxiweak')    -- 2.7.7: weaknesses / resistances / immunities (LandSandBoat data)
local Mob      = require('pximob')     -- 2.8.0: everything else MobDB shows (aggro, links, detection, jobs, drops...)
local PData    = require('pxilistdata')
local PList    = require('pxilist')
local Buffs    = require('pxibuffs')
local Input    = require('pxiinput')
local PTheme   = require('pxilisttheme')
local Rx       = require('pxirecast')       -- the Recasts module (RecastXI)

local hpp = {
    s = nil,
    now = 0,
    save_at = nil,
    zoning = false,
    zone_ready_at = 0,
    zoning_at = 0,
    reload_pending = false,
    rescale = false,
    preview_until = 0,
    preview_hold = false,       -- sample shown until switched off (the Test toggles in the settings window)
    want = { party = false, alliance1 = false, alliance2 = false, target = false, castinfo = false },
    st = { main = 0, sub = 0, slot = -1, sub_active = false, held = 0 },
    dead = false,               -- your character is dead (probe_dead): no enemy bar, game target windows not hidden
    pos = { x = 0, y = 0, depth = 0 },
    src = { main = 'none', sub = 'none' },
    up_sign = -1, up_learned = false,
    sx = 1, sy = 1, scale_ok = false,
    dsx = 1, dsy = 1, disp_w = 0, disp_h = 0, disp_at = -1,
    ui_hidden = false, in_event = false, probe_at = -1,
    loaded = false,
}
_G.partyramaxi = hpp     -- for the config window module and for tests

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local function msg(text) print(chat.header(addon.name):append(chat.message(text))) end
local function err(text) print(chat.header(addon.name):append(chat.error(text))) end
hpp.msg, hpp.err = msg, err

---------------------------------------------------------------------------
-- Wall clock (os.clock is CPU time, not real time)
---------------------------------------------------------------------------
local function make_clock()
    -- imgui.GetTime is real time in seconds and returns a plain number (no table per call).
    if type(imgui.GetTime) == 'function' then
        local ok, v = pcall(imgui.GetTime)
        if ok and type(v) == 'number' then return imgui.GetTime, 'imgui.GetTime' end
    end
    local at = rawget(_G, 'ashita') and ashita.time
    if type(at) == 'table' and type(at.clock) == 'function' then
        local ok, c = pcall(at.clock)
        if ok and type(c) == 'table' and type(c.ms) == 'number' then
            local base = c.ms
            return function () return (at.clock().ms - base) / 1e3 end, 'ashita.time.clock'
        end
    end
    return os.clock, 'os.clock (fallback)'
end
hpp.clock, hpp.clock_name = make_clock()

---------------------------------------------------------------------------
-- Memory access
---------------------------------------------------------------------------
local amem = ashita.memory
local mem = {
    find     = function (sig, off) return amem.find(0, 0, sig, off or 0, 0) end,
    read_u32 = amem.read_uint32,
    read_u16 = amem.read_uint16,
    read_u8  = amem.read_uint8,
    write_u8 = amem.write_uint8,
    write_u32 = amem.write_uint32,
    write_u16 = amem.write_uint16,
    unprotect = amem.unprotect,
    find_ffxi = function (sig) return amem.find('FFXiMain.dll', 0, sig, 0, 0) end,
}
hpp.mem = mem

local function find_main(sig)
    local ok, p = pcall(amem.find, 'FFXiMain.dll', 0, sig, 0, 0)
    if ok and type(p) == 'number' then return p end
    return 0
end
-- Event / hidden-interface probes (signatures as used by XIUI core/gamestate.lua, credited to Velyn).
local P_EVENT  = find_main('A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3')
local P_UIHIDE = find_main('8B4424046A016A0050B9????????E8????????F6D81BC040C3')

local function probe_state()
    local ev, hid = false, false
    if P_EVENT ~= 0 then
        local p = mem.read_u32(P_EVENT + 1)
        if p ~= 0 then ev = mem.read_u8(p) == 1 end
    end
    if P_UIHIDE ~= 0 then
        local p = mem.read_u32(P_UIHIDE + 10)
        if p ~= 0 then hid = mem.read_u8(p + 0xB4) == 1 end
    end
    hpp.in_event, hpp.ui_hidden = ev, hid
end

---------------------------------------------------------------------------
-- Game interfaces
---------------------------------------------------------------------------
local mm = AshitaCore:GetMemoryManager()
local function get_target() return mm:GetTarget() end
local function get_party() return mm:GetParty() end
local function get_entity() return mm:GetEntity() end

-- Cancel one of your own status effects (packet 0x00F1, what the game sends when you right-click / confirm an icon).
function hpp.cancel_buff(id)
    id = tonumber(id)
    if id == nil or id < 1 or id > 1023 or id % 1 ~= 0 then return false end
    local ok, e = pcall(function ()
        AshitaCore:GetPacketManager():AddOutgoingPacket(0xF1, { 0xF1, 0x04, 0x00, 0x00, id % 256, math.floor(id / 256), 0x00, 0x00 })
    end)
    if not ok then err('Could not cancel the effect: ' .. tostring(e)) end
    return ok
end

-- /pxi buffs timers: your effects with the game's raw timer and what it was read as (to check the conversion).
function hpp.dump_self_timers()
    local n = 0
    for id, e in pairs(PData.self) do
        n = n + 1
        local left = e.exp and math.floor(e.exp - hpp.clock()) or nil
        msg(('%s (%d): raw %s -> %s'):format(Fx.name_of(id), id, tostring(e.raw), left and (left .. ' s left') or 'unknown'))
    end
    if n == 0 then msg('No effects read on you (the party list must be on, or its Test).') end
end

-- Are you dead? HP 0, or your character's status is dead (2 / 3). Checked every 0.2 s; a change re-applies the windows.
local function probe_dead()
    local p, e = get_party(), get_entity()
    local dead = false
    if p ~= nil and p:GetMemberIsActive(0) == 1 then
        local me = p:GetMemberTargetIndex(0) or 0
        local hp = p:GetMemberHP(0)
        local ok, stv = false, nil
        if e ~= nil and me ~= 0 then ok, stv = pcall(e.GetStatus, e, me) end
        dead = (hp ~= nil and hp == 0 and me ~= 0) or (ok and (stv == 2 or stv == 3))
    end
    if dead ~= hpp.dead then hpp.dead = dead; hpp.rebuild() end
end

local party_base = 0
do
    local ok, p = pcall(function () return AshitaCore:GetPointerManager():Get('party') end)
    if ok and type(p) == 'number' then party_base = p end
end

hpp.wins = Win.new(mem)
hpp.targets = Targets.new({
    target = get_target, party = get_party,
    party_base = function () return party_base end,
    read_u32 = mem.read_u32, read_u8 = mem.read_u8, write_u8 = mem.write_u8,
})
hpp.cam = Proj.camera(ffi, function () return d3d8.get_device() end)

local function arrows_dir()
    local base = (rawget(_G, 'addon') and addon.path) or ''
    base = base:gsub('[\\/]+$', '')
    return base .. '\\icons\\arrows\\'
end
local png_backend = rawget(_G, 'HPP_PNG_BACKEND') or Png.ashita_backend(ffi, d3d8)
hpp.png = Png.new(png_backend, arrows_dir())
-- 2.9.0: Recasts' element and category pictures follow the Target bar's picture style
require('pxirxicons').style_fn = function () return hpp.s and hpp.s.info and hpp.s.info.icon_style or nil end

-- Status effect icons: a pack and a fallback pack from addons\partyramaxi\icons\packs\, then the loose files
-- in icons\status\.
do
    local base = ((rawget(_G, 'addon') and addon.path) or ''):gsub('[\\/]+$', '')
    hpp.fx_dir = base .. '\\icons\\status\\'
    hpp.fx_pack_dir = base .. '\\icons\\packs\\'
    hpp.fx_root_png = Png.new(png_backend, hpp.fx_dir)
    -- 2.7.7: the weakness icons' element and damage type pictures
    Weak.png_elem = Png.new(png_backend, base .. '\\icons\\elements\\')
    Weak.png_weak = Png.new(png_backend, base .. '\\icons\\weak\\')
    -- 2.9.4: MobDB's data files, next to this addon (addons\\mobdb\\data\\<zone>.lua), when that addon is installed
    Weak.mdb_dir = base:gsub('[\\/][^\\/]+$', '') .. '\\mobdb\\data\\'
    -- 2.8.1: glossy (default) and flat sets; hpp.icon_style picks one each frame
    hpp.png_weak = { glossy = Weak.png_weak, flat = Png.new(png_backend, base .. '\\icons\\weak\\flat\\'),
        jewel = Png.new(png_backend, base .. '\\icons\\weak\\jewel\\') }                                          -- 2.9.0
    hpp.png_elem = { glossy = Weak.png_elem, flat = Png.new(png_backend, base .. '\\icons\\elements\\flat\\'),   -- 2.8.2
        painted = Png.new(png_backend, base .. '\\icons\\elements\\painted\\'),                                      -- 2.8.3
        jewel = Png.new(png_backend, base .. '\\icons\\elements\\jewel\\') }
    Weak.find_icon, Weak.placeholder = Fx.find_icon, Fx.placeholder
    Mob.png = Png.new(png_backend, base .. '\\icons\\mob\\')
    Info.png_badge = Png.new(png_backend, base .. '\\icons\\badges\\')     -- 1.0.4: the name icons
    hpp.png_mob = { glossy = Mob.png, flat = Png.new(png_backend, base .. '\\icons\\mob\\flat\\'),
        jewel = Png.new(png_backend, base .. '\\icons\\mob\\jewel\\') }
    -- 2.10.0: Glyph, High contrast and Glass (white symbol, colour glow): symbol-only pictures for all three kinds
    for _, st in ipairs({ 'glyph', 'contrast', 'glass' }) do
        hpp.png_weak[st] = Png.new(png_backend, base .. '\\icons\\weak\\' .. st .. '\\')
        hpp.png_elem[st] = Png.new(png_backend, base .. '\\icons\\elements\\' .. st .. '\\')
        hpp.png_mob[st] = Png.new(png_backend, base .. '\\icons\\mob\\' .. st .. '\\')
    end
    Mob.res = function () return AshitaCore:GetResourceManager() end
    hpp.fx_pack_pngs, hpp.fx_pack_key = {}, nil
    hpp.fx_packs = {}

    local function is_dir(path)
        local ok, r = pcall(function ()
            local fs = ashita.fs
            if fs.is_directory then return fs.is_directory(path) end
            if fs.status then local st = fs.status(path); return st ~= nil and st.is_directory == true end
            return false
        end)
        return ok and r == true
    end

    local function entries(recursive, dir)
        local ok, r = pcall(ashita.fs.get_directory, ((dir or hpp.fx_pack_dir):gsub('[\\/]+$', '')), '.*', recursive)
        if ok and type(r) == 'table' then return r end
        return {}
    end

    -- Pack folders = sub-folders of icons\packs\. Different Ashita builds list folders differently, so two
    -- listings are combined: the plain one (folders by name) and the recursive one (the first part of
    -- every file path inside a sub-folder).
    local function list_packs(dir)
        dir = dir or hpp.fx_pack_dir
        local found, seen = {}, {}
        local diag = { plain = 0, deep = 0 }
        if dir == hpp.fx_pack_dir then hpp.fx_diag = diag end
        local function take(name)
            if name ~= nil and name ~= '' and not seen[name:lower()] then
                seen[name:lower()] = true
                found[#found + 1] = name
            end
        end
        local root_l = dir:lower()
        for _, f in pairs(entries(false, dir)) do
            if type(f) == 'string' then
                diag.plain = diag.plain + 1
                local nm = f:gsub('[\\/]+$', ''):match('[^\\/]+$')
                if nm and not nm:find('.', 1, true) and is_dir(dir .. nm) then take(nm) end
            end
        end
        for _, f in pairs(entries(true, dir)) do
            if type(f) == 'string' then
                diag.deep = diag.deep + 1
                local rel = f
                if rel:lower():sub(1, #root_l) == root_l then rel = rel:sub(#root_l + 1) end
                rel = rel:gsub('^[\\/]+', '')
                local first = rel:match('^([^\\/]+)[\\/]')
                if first then take(first) end
            end
        end
        table.sort(found, function (x, y) return x:lower() < y:lower() end)
        return found
    end

    -- 2.12.1: every folder in icons\\elements, icons\\weak or icons\\mob is a picture style (Icon Pack), named by
    -- the folder (lower case); the built-in ones keep their labels. Read with the effect icon packs (Rescan).
    local STYLE_ROOT = base .. '\\icons\\'
    hpp.icon_styles = {}
    function hpp.scan_styles()
        local seen, out, has = {}, {}, {}
        for _, k in ipairs({ 'elements', 'weak', 'mob' }) do
            has[k] = {}
            for _, nm in ipairs(list_packs(STYLE_ROOT .. k .. '\\')) do
                local l = nm:lower()
                if l:match('^[%w _%-]+$') then
                    has[k][l] = true
                    if not seen[l] then seen[l] = true; out[#out + 1] = l end
                end
            end
        end
        hpp.icon_styles, hpp.style_has = out, has
    end
    -- the picture set of one style for elements / weak / mob, made the first time it is asked for
    function hpp.style_png(set, sub, st)
        if st == nil or st == 'glossy' then return set.glossy end
        local p = set[st]
        if p == nil and hpp.style_has and hpp.style_has[sub] and hpp.style_has[sub][st] then      -- a folder this kind has
            p = Png.new(png_backend, STYLE_ROOT .. sub .. '\\' .. st .. '\\'); set[st] = p
        end
        return p or set.glossy
    end

    -- 2.9.2: the pack a pack builds on (first line of its base.txt), or ''
    function hpp.pack_base(name)
        local f = io.open(hpp.fx_pack_dir .. name .. '\\base.txt', 'r')
        if f == nil then return '' end
        local line = f:read('*l') or ''
        f:close()
        return (line:gsub('^%s+', ''):gsub('%s+$', ''))
    end
    -- Called at the start of a frame: (re)reads folders when asked or when the pack choice changed.
    function hpp.fx_sync(force)
        local F = hpp.s.info.fx
        local k1, k2 = F.pack or '', F.pack2 or ''
        local last = hpp.fx_pack_key
        if not force and last ~= nil and last[1] == k1 and last[2] == k2 and hpp.fx_root_png.scanned then return end
        for _, p in ipairs(hpp.fx_pack_pngs) do pcall(p.release_all, p) end
        pcall(hpp.fx_root_png.reload, hpp.fx_root_png)
        pcall(Weak.png_elem.reload, Weak.png_elem)
        if Info.png_badge then pcall(Info.png_badge.reload, Info.png_badge) end      -- 1.0.4: name icons
        for _, set in ipairs({ hpp.png_weak, hpp.png_mob, hpp.png_elem }) do
            for _, p in pairs(set) do pcall(p.reload, p) end
        end
        hpp.fx_packs = list_packs()
        pcall(hpp.scan_styles)
        hpp.fx_pack_pngs = {}
        local list, seen = {}, {}
        -- 2.9.2: a pack holding only the pictures that differ from another pack names that pack in base.txt; the rest
        -- of its icons come from there (so two near-identical packs need not keep two copies of the same files)
        local function add(name, depth)
            if name == '' or seen[name:lower()] or depth > 3 then return end
            seen[name:lower()] = true
            local p = Png.new(png_backend, hpp.fx_pack_dir .. name .. '\\')
            pcall(p.scan, p)
            hpp.fx_pack_pngs[#hpp.fx_pack_pngs + 1] = p
            list[#list + 1] = p
            add(hpp.pack_base(name), depth + 1)
        end
        add(k1, 0); add(k2, 0)
        list[#list + 1] = hpp.fx_root_png
        hpp.fx_pack_key = { k1, k2 }
        Fx.set_sources(list)
        if hpp.fx_report then
            hpp.fx_report = false
            msg(('Loose icons: %s (%d PNG%s)'):format(hpp.fx_dir, #hpp.fx_root_png.files, #hpp.fx_root_png.files == 1 and '' or 's'))
            msg(('Packs in %s: %s  [listing: %d plain, %d recursive entries]'):format(
                hpp.fx_pack_dir, #hpp.fx_packs > 0 and table.concat(hpp.fx_packs, ', ') or 'none', hpp.fx_diag.plain, hpp.fx_diag.deep))
            for i, p in ipairs(hpp.fx_pack_pngs) do
                msg(('  %s: %s (%d PNG%s)'):format(i == 1 and 'pack' or 'fallback', p.dir, #p.files, #p.files == 1 and '' or 's'))
            end
        end
    end
end

-- 2.4: icons and fonts moved into icons\ and fonts\. Names the old folders that still hold pictures or fonts, once per load.
function hpp.old_folders()
    local base = ((rawget(_G, 'addon') and addon.path) or ''):gsub('[\\/]+$', '')
    local OLD = { { 'effects', 'icons\\status (pack folders go in icons\\packs)' }, { 'jobicons', 'icons\\jobs' },
                  { 'arrows', 'icons\\arrows' }, { 'recast\\icons\\drop', 'icons\\packs' }, { 'recast\\fonts', 'fonts' },
                  { 'icons\\spells', 'a pack: icons\\packs\\<pack>\\spells' }, { 'icons\\abilities', 'a pack: icons\\packs\\<pack>\\abilities' } }
    local out = {}
    for _, o in ipairs(OLD) do
        local ok, r = pcall(ashita.fs.get_directory, base .. '\\' .. o[1], '.*', true)
        if ok and type(r) == 'table' then
            for _, f in pairs(r) do
                local l = type(f) == 'string' and f:lower() or ''
                if l:match('%.png$') or l:match('%.ttf$') or l:match('%.otf$') then out[#out + 1] = o[1] .. '\\ -> ' .. o[2]; break end
            end
        end
    end
    if #out > 0 then
        err('Icons and fonts now live in icons\\ and fonts\\. Move your files from: ' .. table.concat(out, ';  ') .. ' (see icons\\README.txt).')
    end
end

-- Party effect timers kept between sessions (pxitimers.lua): read once your character's name is known, written on
-- unload and once a minute.
hpp.timers = require('pxitimers')
function hpp.timers_save()
    local T_ = hpp.timers
    if hpp.tm_path == nil then return end
    T_.write(hpp.tm_path, T_.snapshot(Fx, Buffs, PData, hpp.clock()))
end
function hpp.timers_tick(now)
    local p = get_party()
    local name = p and p:GetMemberName(0) or ''
    if type(name) ~= 'string' or name == '' then return end
    if name ~= hpp.tm_name then
        if hpp.tm_path ~= nil then pcall(hpp.timers_save) end      -- another character: keep the old one's first
        hpp.tm_name = name
        hpp.tm_path = hpp.timers.path((rawget(_G, 'addon') and addon.path) or '', name)
        local snap = hpp.tm_path and hpp.timers.read(hpp.tm_path)
        if snap then hpp.timers.restore(snap, Fx, Buffs, now) end
        hpp.tm_saved = now
    elseif now - (hpp.tm_saved or now) >= 60 then
        hpp.tm_saved = now
        hpp.timers_save()
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
function hpp.rebuild()
    local s = hpp.s
    for i = 1, #Win.NAMES do
        local n = Win.NAMES[i]
        -- while you are dead the game gets its target windows back (its own death handling, camera release)
        hpp.want[n] = (s.enabled == true) and (s.windows[n] == true) and not (hpp.dead and (n == 'target' or n == 'castinfo'))
    end
end

function hpp.schedule_save() hpp.save_at = hpp.clock() + 0.5 end
function hpp.flush_save()
    if hpp.save_at ~= nil then hpp.save_at = nil; settings.save() end
end
function hpp.changed() hpp.rebuild(); hpp.schedule_save() end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------
local band = bit.band

local function display_scale(now)
    if now - hpp.disp_at < 1 then return end
    hpp.disp_at = now
    local ok, w, h = pcall(function ()
        local ds = imgui.GetIO().DisplaySize
        return tonumber(ds.x or ds[1]) or 0, tonumber(ds.y or ds[2]) or 0
    end)
    if not ok then w, h = 0, 0 end
    hpp.disp_w, hpp.disp_h = w, h
    if not hpp.layout_done and w > 0 and h > 0 and hpp.s then pcall(hpp.fit_layout, w, h) end
    local vp = hpp.cam.vp
    if w > 0 and vp.Width > 0 then hpp.dsx, hpp.dsy = w / vp.Width, h / vp.Height else hpp.dsx, hpp.dsy = 1, 1 end
end

-- 2.13.3: the shipped window positions were made on a 3840 x 2160 screen (layout_w / layout_h). On a smaller screen,
-- when the party list would sit off it, every saved window position is scaled to this screen once (sizes are kept).
-- Positions that already fit (your own, or a bigger screen) are left alone.
function hpp.fit_layout(W, H)
    hpp.layout_done = true
    local s = hpp.s
    local lw, lh = tonumber(s.layout_w) or 0, tonumber(s.layout_h) or 0
    if lw <= 0 or lh <= 0 or (lw == W and lh == H) then return end
    local L = s.list
    local off = (tonumber(L.x) or 0) > W - 40 or (tonumber(L.y) or 0) > H - 10
    if (W < lw or H < lh) and off then
        local sx, sy = W / lw, H / lh
        local function sc(t, kx, ky)
            if type(t) ~= 'table' then return end
            t[kx] = math.floor((tonumber(t[kx]) or 0) * sx + 0.5)
            t[ky] = math.floor((tonumber(t[ky]) or 0) * sy + 0.5)
        end
        sc(L, 'x', 'y'); sc(L.ally_win, 'x', 'y'); sc(L.pets and L.pets.win, 'x', 'y')
        for _, K in pairs(s.info.kinds) do sc(K, 'ax', 'ay') end
        local R = hpp.rx and hpp.rx.settings and hpp.rx.settings() or nil
        if R ~= nil then sc(R, 'x', 'y'); hpp.rx.mark_dirty() end
        msg(('Window positions fitted to this %d x %d screen.'):format(W, H))
    end
    s.layout_w, s.layout_h = W, H
    hpp.changed()
end

-- Learn which way is up from the game's own arrow, when it sits over the target.
local function learn_up(t, e, idx)
    if hpp.up_learned or idx == 0 or t:GetIsArrowActive(0) ~= 1 then return end
    local dx = t:GetArrowPositionX(0) - e:GetLocalPositionX(idx)
    local dy = t:GetArrowPositionY(0) - e:GetLocalPositionY(idx)
    local dz = t:GetArrowPositionZ(0) - e:GetLocalPositionZ(idx)
    if dx * dx + dy * dy < 2.25 and math.abs(dz) > 0.3 then
        hpp.up_sign = dz < 0 and -1 or 1
        hpp.up_learned = true
    end
end

-- 2.9.2: over the character = a set height above the top of its head (the head bone, like the bars over members);
-- head_height above the feet only until the model has loaded
local ARROW_T = {}
local RIDE_UP = 1.2
local function entity_screen(idx, out)
    local cam = hpp.cam
    if not cam.ok or idx == 0 or idx > 2303 then return false end
    local a = hpp.s.arrow
    local now = hpp.now or 0
    local dt = now - (ARROW_T[idx] or now); ARROW_T[idx] = now
    -- 2.10.0: riding a chocobo or a mount (status 5 / 85): RIDE_UP yalms higher
    local e = get_entity()
    local stt = e and tonumber(e:GetStatus(idx)) or 0
    local ride = (stt == 5 or stt == 85) and RIDE_UP or 0
    if not hpp.head_screen(idx, (tonumber(a.head_gap) or 0.4) + ride, (tonumber(a.head_height) or 2.4) + ride, out, dt) then return false end
    if out.x < -50 or out.y < -50 or (hpp.disp_w > 0 and (out.x > hpp.disp_w + 50 or out.y > hpp.disp_h + 50)) then
        return false
    end
    return true
end

-- 2.7.6: any entity's screen point a given height (yalms) above its feet; out.depth = distance from the camera.
function hpp.world_screen(idx, up_h, out)
    local cam = hpp.cam
    if not cam.ok or idx == 0 or idx > 2303 then return false end
    local e = get_entity()
    if e == nil or band(e:GetRenderFlags0(idx) or 0, 0x200) == 0 then return false end
    local x, y, z = e:GetLocalPositionX(idx), e:GetLocalPositionY(idx), e:GetLocalPositionZ(idx)
    if not Proj.project(cam.v, cam.p, cam.vp, x, z + hpp.up_sign * up_h, y, out) then return false end
    out.x, out.y = out.x * hpp.dsx, out.y * hpp.dsy
    return out.x > -100 and out.y > -100 and not (hpp.disp_w > 0 and (out.x > hpp.disp_w + 100 or out.y > hpp.disp_h + 100))
end

-- 2.7.8: the top of an entity's head from its skeleton (bone 2, where nameplates sit), as an offset from the actor's
-- position. Read from the actor in memory: position at +0x678 (x, height, y = +0x678, +0x67C, +0x680), skeleton at
-- +0x6B8, then the bone's generator. The same reads LibraPlates uses for its nameplates. nil when not loaded.
local HEAD_BONE = 2
local function head_bone(actor)
    local mem_ = ashita.memory
    local ax, ah, ay = mem_.read_float(actor + 0x678), mem_.read_float(actor + 0x67C), mem_.read_float(actor + 0x680)
    local base = mem_.read_uint32(actor + 0x6B8)
    if base == 0 then return nil end
    local off = mem_.read_uint32(base + 0x0C)
    if off == 0 then return nil end
    local sk = mem_.read_uint32(off)
    if sk == 0 then return nil end
    local bones = mem_.read_uint16(sk + 0x32)
    if bones == nil or bones <= HEAD_BONE or bones > 512 then return nil end
    local g = sk + 0x30 + 0x04 + 0x1E * bones + 4 + HEAD_BONE * 0x1A + 0x0E
    local dx, dh, dy = mem_.read_float(g), mem_.read_float(g + 4), mem_.read_float(g + 8)
    if dx ~= dx or dh ~= dh or dy ~= dy or math.abs(dh) > 50 then return nil end       -- NaN / garbage
    return ax, ah, ay, dx, dh, dy
end
local HEAD = {}           -- idx -> eased head height (the bone moves with every step; the bar should not bob)
-- Screen point gap yalms above the top of entity idx's head, else (no skeleton yet) fallback yalms above its feet.
function hpp.head_screen(idx, gap, fallback, out, dt)
    local cam = hpp.cam
    if not cam.ok or idx == 0 or idx > 2303 then return false end
    local e = get_entity()
    if e == nil or band(e:GetRenderFlags0(idx) or 0, 0x200) == 0 then return false end
    local actor = e.GetActorPointer and e:GetActorPointer(idx) or 0
    local ok, ax, ah, ay, dx, dh, dy = false
    if actor ~= nil and actor ~= 0 and rawget(_G, 'ashita') and ashita.memory then ok, ax, ah, ay, dx, dh, dy = pcall(head_bone, actor) end
    if not ok or ax == nil then HEAD[idx] = nil; return hpp.world_screen(idx, fallback, out) end
    local h = HEAD[idx]
    if h == nil then h = dh else h = h + (dh - h) * math.min(1, (dt or 0) * 6) end
    HEAD[idx] = h
    if not Proj.project(cam.v, cam.p, cam.vp, ax + dx, ah + h + hpp.up_sign * gap, ay + dy, out) then return false end
    out.x, out.y = out.x * hpp.dsx, out.y * hpp.dsy
    return out.x > -100 and out.y > -100 and not (hpp.disp_w > 0 and (out.x > hpp.disp_w + 100 or out.y > hpp.disp_h + 100))
end

local function native_screen(which, out)
    local obj = hpp.wins:object('target')
    if obj == nil then return false end
    if not Proj.native(mem, obj, which, hpp.sx, hpp.sy, out) then return false end
    local a = hpp.s.arrow
    out.x = out.x + (tonumber(a.native_dx) or 0)
    out.y = out.y + (tonumber(a.native_dy) or 0)
    return true
end

-- Where to draw the arrow for entity idx. Returns the source name or nil.
local NATIVE_SINCE = { main = nil, sub = nil, idx_main = 0, idx_sub = 0 }
function hpp.place(which, idx, out)
    local mode = hpp.s.arrow.mode
    if (mode == 'entity' or mode == 'auto') and entity_screen(idx, out) then NATIVE_SINCE[which] = nil; return 'entity' end
    if (mode == 'native' or mode == 'auto') and native_screen(which, out) then
        -- In auto mode the game's own spot is only a fallback. A frame or two without the entity position (just
        -- targeted, not rendered yet) must not flash the arrow somewhere else before it jumps to the right place.
        if mode == 'auto' then
            local now = hpp.now or 0
            if NATIVE_SINCE['idx_' .. which] ~= idx then NATIVE_SINCE['idx_' .. which] = idx; NATIVE_SINCE[which] = nil end
            NATIVE_SINCE[which] = NATIVE_SINCE[which] or now
            if now - NATIVE_SINCE[which] < 0.35 then return nil end
        end
        return 'native'
    end
    return nil
end

-- A target must have been the same for a few frames before its arrow / info is drawn (the camera and the entity's
-- position settle after a target change; drawing earlier shows one frame in the wrong place).
local SETTLE = { main = { idx = -1, n = 0, f = -1 }, sub = { idx = -1, n = 0, f = -1 }, focus = { idx = -1, n = 0, f = -1 } }
function hpp.settled(which, idx)
    local s = SETTLE[which] or SETTLE.main
    if s.idx ~= idx then s.idx, s.n, s.f, s.t0 = idx, 0, hpp.fno, hpp.now end      -- t0: when it was picked
    if s.f ~= hpp.fno then s.f = hpp.fno; s.n = s.n + 1; if s.n == 3 then s.t = hpp.now end end
    return s.n >= 3
end

-- Opacity multiplier while a target's arrow / info fades in (the "Fade in" setting).
function hpp.fade_in_mul(which, now)
    local s = SETTLE[which] or SETTLE.main
    local d = tonumber(hpp.s.info.fade_in) or 0.15
    if d <= 0 or s.t == nil then return 1 end
    return math.max(0, math.min(1, (now - s.t) / d))
end

hpp.DOCK_PARTS = { 'name', 'bar', 'pct', 'dist', 'level', 'check', 'defev', 'weak', 'mob' }
hpp.DOCK_ALIGN = { name = 'center', dist = 'left', level = 'right', check = 'center', defev = 'center' }   -- 1.0.6: usual justify
-- 1.0.5 (Joshua): the check's results always fade in CHECK_SHOW s after the target was picked (or when the reply
-- came, if later), over CHECK_FADE s. Fixed, no setting.
hpp.CHECK_SHOW, hpp.CHECK_FADE = 0.2, 0.15
function hpp.check_fade_mul(which, c, now)
    local s = SETTLE[which] or SETTLE.main
    if s.t0 == nil then return 1 end
    local start = s.t0 + hpp.CHECK_SHOW
    if c ~= nil and (tonumber(c.at) or 0) > start then start = c.at end
    return math.max(0, math.min(1, (now - start) / hpp.CHECK_FADE))
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
function hpp.arrows_wanted()
    local a = hpp.s.arrow
    if a.mode == 'off' then return false end
    if a.hide_in_events and (hpp.ui_hidden or hpp.in_event) then return false end
    return a.when == 'always' or hpp.wins.hidden.target == true
end

hpp.OUT8 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -0.7, -0.7 }, { 0.7, -0.7 }, { -0.7, 0.7 }, { 0.7, 0.7 } }
-- One arrow, built-in shape or PNG. PNG problems fall back to the triangle.
function hpp.shape(dl, x, y, dir, size, col, alpha, line, thick)
    local a = hpp.s.arrow
    if dir == 'down' then Draw.hl_rect('arrow', 'arrow', x - size * 0.6, y - size * 1.15, x + size * 0.6, y + 2) end
    if dir == 'down' then Draw.obst(x - size * 0.6, y - size * 1.15, x + size * 0.6, y + 2)       -- 2.10.0: the target bar keeps off it
    else Draw.obst(x - size, y - size, x + size, y + size) end
    local file = Png.file_of(a.style)
    if file ~= nil then
        local e = hpp.png:get(file)
        if e.id ~= nil then
            -- 2.6: outline for PNG arrows: the picture's white silhouette in the outline color, drawn around it
            if line ~= 0 then
                local sil = hpp.png:silhouette(file)
                if sil.id ~= nil then
                    local t = thick or 2
                    for k = 1, 8 do
                        local o = hpp.OUT8[k]
                        Draw.image(dl, sil.id, x + o[1] * t, y + o[2] * t, dir, size, e.w, e.h, a.png_rotation, line)
                    end
                end
            end
            local tint = a.png_tint == false and Draw.u32(Draw.WHITE, (tonumber(col[4]) or 1) * alpha) or Draw.u32(col, alpha)
            Draw.image(dl, e.id, x, y, dir, size, e.w, e.h, a.png_rotation, tint)
            return
        end
        Draw.arrow(dl, 'triangle', x, y, dir, size, Draw.u32(col, alpha), line, thick)
        return
    end
    Draw.arrow(dl, a.style, x, y, dir, size, Draw.u32(col, alpha), line, thick, hpp.now)
end

local function draw_one(dl, which, idx, col, bob, alpha, line)
    local a = hpp.s.arrow
    -- The 3-frame wait is for the position over the character (camera / entity settle after a change). The game's own
    -- spot is right on the first frame (1.9.6 / 1.9.8 traces), so native mode draws at once: waiting only left a gap.
    if not hpp.settled(which, idx) and a.mode ~= 'native' then hpp.src[which] = 'none'; return end
    local src = hpp.place(which, idx, hpp.pos)
    hpp.src[which] = src or 'none'
    if src == nil then return end
    if which == 'main' then hpp.drawn_x, hpp.drawn_y = hpp.pos.x, hpp.pos.y end     -- for /pxi trace
    hpp.shape(dl, hpp.pos.x, hpp.pos.y - bob, 'down', tonumber(a.size) or 18, col, alpha, line, tonumber(a.outline_thickness) or 2)
    if a.sheen then hpp.arrow_sheen(dl, which, hpp.pos.x, hpp.pos.y - bob, alpha) end
end

-- Arrow sheen: one sweep (hpp.SHEEN_DUR s) at a random moment every sheen_min..sheen_max seconds, per arrow.
hpp.SHEEN_DUR = 0.6
hpp.sheen_t = { main = { t0 = -10, nxt = nil }, sub = { t0 = -10, nxt = nil } }
function hpp.arrow_sheen(dl, which, x, y, alpha)
    local a, now = hpp.s.arrow, hpp.now or 0
    local S = hpp.sheen_t[which]
    local lo = tonumber(a.sheen_min) or 5
    local hi = math.max(lo, tonumber(a.sheen_max) or 10)
    if S.nxt == nil then S.nxt = now + lo + math.random() * (hi - lo) end
    if now >= S.nxt then S.t0 = now; S.nxt = now + hpp.SHEEN_DUR + lo + math.random() * (hi - lo) end
    local p = (now - S.t0) / hpp.SHEEN_DUR
    if p > 0 and p < 1 then Draw.sheen(dl, a.style, x, y, 'down', tonumber(a.size) or 18, p, (tonumber(a.sheen_strength) or 0.6) * alpha, now) end
end

function hpp.draw_arrows(now)
    local a = hpp.s.arrow
    local st = hpp.st
    hpp.src.main, hpp.src.sub = 'none', 'none'
    local dl = imgui.GetForegroundDrawList()
    local bob, alpha = Draw.anim(a, now)
    local line = a.outline and Draw.u32(a.outline_color, alpha) or 0
    if st.sub ~= 0 then draw_one(dl, 'sub', st.sub, a.sub_color, bob, alpha, line) end
    if a.show_main and st.main ~= 0 then
        -- while choosing a sub-target the held target's arrow stays still, like the game's
        if st.sub ~= 0 then draw_one(dl, 'main', st.main, a.main_color, 0, 1, a.outline and Draw.u32(a.outline_color, 1) or 0)
        else draw_one(dl, 'main', st.main, a.main_color, bob, alpha, line) end
    end
end

---------------------------------------------------------------------------
-- Text scaling support of this Ashita build (PushFont with a size, like XIUI does).
---------------------------------------------------------------------------
local function fn(name) local f = imgui[name]; return type(f) == 'function' and f or nil end
local HAS_SCALE = fn('SetWindowFontScale')
local HAS_PUSHFONT = fn('PushFont') and fn('PopFont') and fn('GetFont') and fn('GetFontSize')
hpp.font_method = HAS_SCALE and 'SetWindowFontScale' or (HAS_PUSHFONT and 'PushFont' or 'none')

---------------------------------------------------------------------------
-- Party list (pxilist.lua). Optional: if it errors it turns itself off, says why once, and the rest keeps running.
---------------------------------------------------------------------------
function hpp.draw_list(now, sample, cycle)
    PList.draw(now, sample, cycle)
end

-- 2.7.6: health bars over party members (pxiover.lua)
local OVER_DT = 0
-- 2.9.2: per-job settings for the bars over members. 2.10.0: always on. On a job change the old job's settings are
-- saved as its own and the new job's own (if it has any) are loaded; a job without its own keeps the current ones.
local OVJ = { job = nil, t = 0 }
hpp.ovj = OVJ
function hpp.my_job()
    local pl = mm and mm:GetPlayer()
    local j = pl and tonumber(pl:GetMainJob()) or 0
    return j > 0 and PData.JOB[j] or nil
end
local function over_copy(src, dst)
    dst = dst or {}
    for k, v in pairs(src) do
        if type(v) == 'table' then dst[k] = over_copy(v, type(dst[k]) == 'table' and dst[k] or {}) else dst[k] = v end
    end
    return dst
end
hpp.over_copy = over_copy
function hpp.over_job_sync(now)
    local L = hpp.s.list
    local job = hpp.my_job()
    if job == nil or job == OVJ.job then return end
    local J, old = L.over_jobs, OVJ.job
    OVJ.job, OVJ.t = job, now
    if old == nil then return end            -- first look after loading: the saved settings are this job's latest
    J[old] = over_copy(L.over)
    if J[job] ~= nil then over_copy(J[job], L.over) end
    -- 2.10.1: the status icons' sort, pins and type order too (fresh copies: lists must not keep the old job's entries)
    local BJ, B = L.buff_jobs, L.buffs
    BJ[old] = { sort = B.sort, pins = over_copy(B.pins or {}), pin_mode = over_copy(B.pin_mode or {}), type_order = over_copy(B.type_order or {}),
        type_hide = over_copy(B.type_hide or {}) }
    local nb = BJ[job]
    if nb ~= nil then
        B.sort, B.pins, B.pin_mode, B.type_order = nb.sort or B.sort, over_copy(nb.pins or {}), over_copy(nb.pin_mode or {}), over_copy(nb.type_order or {})
        B.type_hide = over_copy(nb.type_hide or {})
        Buffs.rank_dirty()
    end
    hpp.changed()
end
-- 2.7.8: over the head (nameplate height) by default; "From the feet" keeps the fixed height
local function over_screen(idx, up, out)
    local O = hpp.s.list.over
    if O.anchor == 'feet' then return hpp.world_screen(idx, up, out) end
    return hpp.head_screen(idx, tonumber(O.head_gap) or 0.3, up, out, OVER_DT)
end
-- 2.8.1: which members a monster is going after. hpp.mob_last[monster server id] = { target server id, time } from
-- action packets (melee, moves, spells...); the enemy's own target (GetTargetedIndex) comes first.
hpp.mob_last = {}
local AGGRO_SECS = 6                -- an action this recent still counts
local MARK = {}                     -- member target index -> 'main' (your enemy's target) | 'other' (another monster's)
local function member_idx(party, sid)
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == sid then return party:GetMemberTargetIndex(i) end
    end
    return nil
end
local function alive_mob(e, idx)
    return idx ~= nil and idx ~= 0 and idx < 2304 and hpp.is_monster ~= nil and hpp.is_monster(idx) and (e:GetHPPercent(idx) or 0) > 0
end
-- 2.10.0: both options mark everyone a monster the party is fighting is after: your enemy, and every monster a party
-- member is engaged with (its own target, else whom it acted on last). 'any' also marks whom any other monster acted
-- on in the last AGGRO_SECS, fainter.
local FIGHT, MEMB = {}, {}          -- monster index / member index -> true, rebuilt each frame
local function mob_target(e, party, en, now)
    local ok, ti = pcall(e.GetTargetedIndex, e, en)
    ti = ok and tonumber(ti) or 0
    if ti == 0 then
        local v = hpp.mob_last[e:GetServerId(en) or 0]
        if v and now - v[2] <= AGGRO_SECS then ti = member_idx(party, v[1]) or 0 end
    end
    return ti
end
local function aggro_marks(O, now)
    for k in pairs(MARK) do MARK[k] = nil end
    for k in pairs(FIGHT) do FIGHT[k] = nil end
    for k in pairs(MEMB) do MEMB[k] = nil end
    local mode = O.aggro or 'focus'
    if mode == 'off' then return end
    local e, party = get_entity(), get_party()
    if e == nil or party == nil then return end
    local members = MEMB
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local mi = party:GetMemberTargetIndex(i) or 0
            if mi ~= 0 then
                members[mi] = true
                if (e:GetStatus(mi) or 0) == 1 then          -- engaged: what it is fighting
                    local ok, t = pcall(e.GetTargetedIndex, e, mi)
                    t = ok and tonumber(t) or 0
                    if alive_mob(e, t) then FIGHT[t] = true end
                end
            end
        end
    end
    local en = hpp.info_main or 0
    if not alive_mob(e, en) then en = hpp.focus or 0 end
    if alive_mob(e, en) then FIGHT[en] = true end
    -- 'any': every monster that acted on a member lately
    for actor, v in pairs(hpp.mob_last) do
        if now - v[2] > AGGRO_SECS then hpp.mob_last[actor] = nil
        elseif mode == 'any' and alive_mob(e, actor % 0x1000) then
            local mi = member_idx(party, v[1])
            if mi and mi ~= 0 then MARK[mi] = 'other' end
        end
    end
    for mob in pairs(FIGHT) do
        local ti = mob_target(e, party, mob, now)
        if ti ~= 0 and members[ti] then MARK[ti] = 'main' end
    end
end
-- 2.10.0: the bars over members show only in battle: someone in the party is engaged, or a monster acted on a member
-- in the last AGGRO_SECS
function hpp.party_in_battle(now)
    local e, party = get_entity(), get_party()
    if e == nil or party == nil then return false end
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local mi = party:GetMemberTargetIndex(i) or 0
            if mi ~= 0 and (e:GetStatus(mi) or 0) == 1 then return true end
        end
    end
    for _, v in pairs(hpp.mob_last) do if now - v[2] <= AGGRO_SECS then return true end end
    return false
end
local OVER = { party = nil, screen = over_screen, test = false, now = 0, dt = 0, marks = MARK,
    push = function (sc) return hpp.push_font ~= nil and hpp.push_font(sc) or false end }
function hpp.draw_over(now)
    OVER.party, OVER.test, OVER.dt, OVER.now = get_party(), hpp.list_test == true, now - (OVER.now or now), now
    OVER_DT = OVER.dt
    pcall(aggro_marks, hpp.s.list.over, now)
    require('pxiover').draw(hpp.s.list, hpp.s.list.over, OVER)
end

---------------------------------------------------------------------------
-- Enemy info (name, health bar, level range, check) next to the pointer
---------------------------------------------------------------------------
local function push_font_size(scale)
    if not HAS_PUSHFONT then return false end
    local f = Fonts.font                       -- the font chosen in the settings, nil = the default one
    if scale == 1 and f == nil then return false end
    local size = (tonumber(imgui.GetFontSize()) or 14) * scale
    return Fonts.push(f or imgui.GetFont(), size)
end
hpp.push_font = push_font_size

local function is_monster(idx)
    local e = get_entity()
    if e == nil or idx == nil or idx == 0 or idx > 2303 then return false end
    return band(e:GetSpawnFlags(idx) or 0, 0x10) ~= 0
end
hpp.is_monster = is_monster
-- Another player character (spawn flag 0x01), not you: gets the bar too when "Also for other players" is on. Anything else
-- you can target (NPCs, doors, ??? points, trusts...) gets it in the NPC color when "Also for NPCs and objects" is on.
-- Returns 'mob' | 'pc' | 'npc', or nil for no bar.
-- 2.9.0: each kind can be switched off (Target bar > Enemies / Players / NPCs).
function hpp.info_kind(idx)
    local K = hpp.s.info.kinds
    if is_monster(idx) then return K.mob.enabled and 'mob' or nil end
    local e = get_entity()
    if e == nil or idx == nil or idx == 0 or idx > 2303 then return nil end
    local p = get_party()
    if p ~= nil and idx == (p:GetMemberTargetIndex(0) or 0) then return (K.pc.enabled and K.pc.self) and 'pc' or nil end   -- 2.9.1: you, if asked
    if band(e:GetSpawnFlags(idx) or 0, 0x01) ~= 0 then return K.pc.enabled and 'pc' or nil end
    return K.npc.enabled and 'npc' or nil
end
function hpp.shows_info(idx) return hpp.info_kind(idx) ~= nil end

-- Where the info for entity idx goes (the pointer position), whatever the arrow settings are.
local function info_place_src(which, idx, out)
    if which == 'focus' then return entity_screen(idx, out) end     -- the remembered enemy: only ever over its own model
    if hpp.s.arrow.mode == 'native' then
        return native_screen(which, out) or entity_screen(idx, out)
    end
    return entity_screen(idx, out) or native_screen(which, out)
end
-- 1.0.8 (Joshua): the target counts as off the screen as soon as its spot leaves the screen (the game's pointer spot
-- has no edge test, and the model's had a 50 px margin, so it took a target nearly behind you to dock)
local function info_place_raw(which, idx, out)
    if not info_place_src(which, idx, out) then return false end
    local W, H = hpp.disp_w or 0, hpp.disp_h or 0
    if W > 0 and H > 0 and (out.x < 0 or out.y < 0 or out.x > W or out.y > H) then return false end
    return true
end

-- The info stays where it was while the sub-target cursor is in use. The game's pointer for the held target can move
-- or hide while you pick a sub-target; so, while no sub-target is active, remember how far the spot we use is from the
-- monster's own position and, while one is active, keep that same offset from the monster.
local ANCH, TMPP = {}, { x = 0, y = 0 }
hpp.anch = ANCH
local function info_place(which, idx, out)
    local ok = info_place_raw(which, idx, out)
    if which == 'sub' then return ok end
    local busy = (hpp.st.sub or 0) ~= 0
    if not busy then
        if ok and entity_screen(idx, TMPP) then
            local a = ANCH[idx]
            if a == nil then a = {}; ANCH[idx] = a end
            a.dx, a.dy = out.x - TMPP.x, out.y - TMPP.y
        end
        return ok
    end
    local a = ANCH[idx]
    if a ~= nil and entity_screen(idx, TMPP) then
        out.x, out.y = TMPP.x + a.dx, TMPP.y + a.dy
        local W, H = hpp.disp_w or 0, hpp.disp_h or 0          -- 1.0.8: off the screen is off the screen here too
        return not (W > 0 and H > 0 and (out.x < 0 or out.y < 0 or out.x > W or out.y > H))
    end
    return ok
end

local fx_list, fx_sample = {}, {}
local weak_list, weak_sample = {}, {}      -- 2.7.7: the weakness icons being shown, and the Test sample's
local mob_list, mob_sample = {}, {}        -- 2.8.0: the monster info badges
local fade = { prog = 0, since = nil, last = nil, target = 0, want = 0,       -- battle fade: 0 = fully shown, 1 = fully faded
    gval = 0, gto = 0, gfrom = 0, gq = 1 }                                     -- glide: position 0..1, its tween

-- Is somebody engaged? Entity status 1 = engaged.
local function is_engaged(e, idx)
    if idx == nil or idx == 0 then return false end
    local ok, v = pcall(e.GetStatus, e, idx)
    return ok and v == 1
end

-- Is the (engaged) monster idx fighting us, i.e. the player, a party / alliance member or the player's pet?
-- true / false, or nil when this Ashita build can't tell (callers then fall back to "somebody is engaged").
local function fighting_us(e, idx)
    local party = get_party()
    if party == nil then return nil end
    local me = party:GetMemberTargetIndex(0) or 0
    local ok, pt = pcall(e.GetPetTargetIndex, e, me)
    if ok and (tonumber(pt) or 0) == idx then return true end        -- my pet is on it
    local ok2, claim = pcall(e.GetClaimStatus, e, idx)
    if not ok2 then return nil end
    claim = tonumber(claim) or 0
    if claim == 0 then return false end
    local lo = claim % 65536
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 then
            local sid = party:GetMemberServerId(i) or 0
            if sid ~= 0 and (sid == claim or sid % 65536 == lo) then return true end
        end
    end
    return false
end

local function engaged(I, e)
    local w = I.fade_when
    if w ~= 'target' then
        local party = get_party()
        if is_engaged(e, party and party:GetMemberTargetIndex(0) or 0) then return true end
    end
    local tm = hpp.info_main or hpp.st.main
    if w ~= 'me' and is_engaged(e, tm) then
        local f = fighting_us(e, tm)
        return f ~= false            -- nil (can't tell) counts as engaged, like before
    end
    return false
end

hpp.FADE = 0.28           -- every fade of the enemy bar's elements (battle fade in / out; appear / disappear defaults)
local function moves(I) return (tonumber(I.glide_x) or 0) ~= 0 or (tonumber(I.glide_y) or 0) ~= 0 end

-- 2.7.6: is anybody in the party / alliance engaged? And is the player dead (status 2 / 3)?
local function party_engaged(e)
    local party = get_party()
    if party == nil then return false end
    for i = 0, 17 do
        if party:GetMemberIsActive(i) == 1 and is_engaged(e, party:GetMemberTargetIndex(i) or 0) then return true end
    end
    return false
end
local function me_dead(e)
    local party = get_party()
    local me = party and party:GetMemberTargetIndex(0) or 0
    if me == 0 then return false end
    local ok, v = pcall(e.GetStatus, e, me)
    return ok and (v == 2 or v == 3)
end

local function fade_update(I, e, now)
    local any = I.name.fade or I.bar.fade or I.level.fade or I.check.fade or I.defev.fade or I.fx.fade or I.dist.fade or I.weak.fade or I.mob.fade
        or moves(I)
    local eng = any and engaged(I, e)
    -- 2.7.6: once engaged, the battle position is latched: it holds through target switches, a monster dying while the
    -- fight goes on, and claim readings that flicker, until nobody in the party is engaged any more or you die.
    if eng then fade.latch = true end
    if fade.latch then
        if not any or not party_engaged(e) or me_dead(e) then fade.latch = false else eng = true end
    end
    -- A new target starts over, unless the fight goes on: then the in-battle position is kept (a caster switching
    -- between monsters, or a claim reading that flickers, must not make the bar slide back and forth).
    if (hpp.info_main or hpp.st.main) ~= fade.target then
        fade.target = hpp.info_main or hpp.st.main
        if not eng then fade.since = nil end
    end
    local dt = math.min(0.25, math.max(0, now - (fade.last or now)))
    fade.last = now
    local want = 0
    if eng then
        fade.since = fade.since or now
        fade.lost = nil
    elseif fade.since ~= nil and fade.want == 1 then
        -- the fight seems to have ended: stay in the battle position as long as it took to get there ("Start after"),
        -- then go back. Engaged again meanwhile: nothing moves.
        fade.lost = fade.lost or now
        if now - fade.lost >= (tonumber(I.fade_delay) or 3) then fade.since, fade.lost = nil, nil end
    else
        fade.since, fade.lost = nil, nil
    end
    if fade.since ~= nil and now - fade.since >= (tonumber(I.fade_delay) or 3) then want = 1 end
    local step = dt / math.max(0.1, tonumber(I.fade_time) or 1.5)            -- the glide's own speed
    local fstep = dt / hpp.FADE                                               -- the battle fade: always 0.28 s, both ways
    fade.want = want
    if want == 1 then fade.prog = math.min(1, fade.prog + fstep) else fade.prog = math.max(0, fade.prog - fstep) end
    -- Glide: a tween to the battle spot (1) or home (0) with the chosen curve, so both ways arrive with the same motion
    -- (a bounce or spring settles at home too, instead of playing backwards at the start). If the direction changes
    -- midway, a new tween starts from where the bar is: no jump, no back-and-forth.
    if fade.gto ~= want then fade.gto, fade.gfrom, fade.gq = want, fade.gval or 0, 0 end
    if fade.gq < 1 then
        fade.gq = math.min(1, fade.gq + step)
        local E = Info.EASE[I.glide_ease] or Info.EASE.smooth
        fade.gval = fade.gfrom + (want - fade.gfrom) * E(fade.gq)
    end
end

local function fade_alpha(el)
    if not el.fade or fade.prog <= 0 then return 1 end
    return 1 - fade.prog * (1 - (tonumber(el.fade_alpha) or 0.2))
end
local info_d = { name = '', hp = 0, level = nil, check = nil, check_color = nil, idx = nil, now = nil }

-- A target that dies fades out over this long instead of vanishing.
local DEATH_FADE = 0.30             -- replaced each frame by the "Fade out" setting
hpp.alive, hpp.dying, hpp.prev_main, hpp.ghost, hpp.focus = {}, {}, 0, 0, 0

-- Opacity multiplier for monster idx: 1 while alive, fading to 0 after its health reaches 0, nil once it is gone.
local function death_mul(e, idx, now)
    if (e:GetHPPercent(idx) or 0) > 0 then hpp.alive[idx], hpp.dying[idx] = true, nil; return 1 end
    if not hpp.alive[idx] then return 1 end              -- never seen alive (a corpse targeted later): leave as it was
    local t0 = hpp.dying[idx]
    if t0 == nil then t0 = now; hpp.dying[idx] = now end
    local m = 1 - (now - t0) / DEATH_FADE
    if m <= 0 then return nil end
    return m
end

-- 2.9.5: a glide offset g that keeps a box a0..a1 (drawn without glide) margin px inside 0..size; a box too big for
-- the screen keeps its left / top edge in. 2.10.0: the margin is GLIDE_MARGIN of the screen (7.5%).
local GLIDE_MARGIN = 0.075
local function clamp_glide(g, a0, a1, size, margin)
    local hi, lo = size - margin - a1, margin - a0
    if g > hi then g = hi end
    if g < lo then g = lo end
    return g
end
-- 2.10.0: the smallest extra move (dx, dy) that takes the box off every rect another part of the addon drew last frame
-- (its windows, the pointer arrows), staying inside the margins when it can. Up to three passes for overlapping rects.
local AVOID_PAD = 6
local function avoid(bx0, by0, bx1, by1, W, H, mx, my)
    local OB = Draw.OBP
    local dx, dy = 0, 0
    for _ = 1, 3 do
        local hit = false
        for k = 0, OB.n - 1 do
            local o0, o1, o2, o3 = OB[k * 4 + 1], OB[k * 4 + 2], OB[k * 4 + 3], OB[k * 4 + 4]
            local x0, y0, x1, y1 = bx0 + dx, by0 + dy, bx1 + dx, by1 + dy
            if x0 < o2 and x1 > o0 and y0 < o3 and y1 > o1 then
                -- up, down, left, right: the shortest that stays on screen (else the shortest)
                local best, bdx, bdy, any = 1e9, 0, 0, 1e9
                local function try(cx, cy)
                    local d = math.abs(cx) + math.abs(cy)
                    local fits = x0 + cx >= mx and x1 + cx <= W - mx and y0 + cy >= my and y1 + cy <= H - my
                    if fits and d < best then best, bdx, bdy = d, cx, cy end
                    if d < any then any = d; if best == 1e9 then bdx, bdy = cx, cy end end
                end
                try(0, o1 - y1 - AVOID_PAD); try(0, o3 - y0 + AVOID_PAD); try(o0 - x1 - AVOID_PAD, 0); try(o2 - x0 + AVOID_PAD, 0)
                dx, dy, hit = dx + bdx, dy + bdy, true
            end
        end
        if not hit then break end
    end
    return dx, dy
end
hpp.glide_avoid = avoid
local AV = { x = 0, y = 0, t = nil }       -- the avoiding move, eased so the bar slides out of the way
hpp.clamp_glide = clamp_glide
-- What the main target gets that others don't: the battle fade and the glide, set once per frame.
local MAIN = { name = 1, bar = 1, level = 1, check = 1, defev = 1, dist = 1, fx = 1, weak = 1, mob = 1, gx = 0, gy = 0 }

-- 2.9.0: players and NPCs have their own offset for the effect icons; Fx.draw adds the enemies' (fx.dx / dy), so
-- the difference moves the anchor.
local function fx_shift(F, d)
    local o = d.off and d.off.fx
    if o == nil then return 0, 0 end
    return (tonumber(o.dx) or 0) - (tonumber(F.dx) or 0), (tonumber(o.dy) or 0) - (tonumber(F.dy) or 0)
end
local function draw_fx_layer(dl, d)
    local I = hpp.s.info
    local sx, sy = fx_shift(I.fx, d)
    Fx.draw(dl, I.fx, (d.px or hpp.pos.x) + sx, (d.py or hpp.pos.y) + sy, fx_list, d.fx_n, d.fx_now, push_font_size, tonumber(I.text_size) or 1, d.fx_alpha, d.gx, d.gy)
end

-- 2.7.7: the weakness icons, one more layer of the info
-- 1.0.5: the docked card's own place for the weakness icons / monster info: the difference moves the anchor
local function off_shift(k, el, d)
    local o = d.off and d.off[k]
    if o == nil then return 0, 0 end
    return (tonumber(o.dx) or 0) - (tonumber(el.dx) or 0), (tonumber(o.dy) or 0) - (tonumber(el.dy) or 0)
end
local function draw_weak_layer(dl, d)
    local I = hpp.s.info
    local sx, sy = off_shift('weak', I.weak, d)
    local st = I.weak.icon_style or I.icon_style             -- 2.10.1: the weaknesses have their own picture style
    if hpp.png_weak then Weak.png_weak = hpp.style_png(hpp.png_weak, 'weak', st) end
    if hpp.png_elem then Weak.png_elem = hpp.style_png(hpp.png_elem, 'elements', st) end
    Weak.draw(dl, I.weak, (d.px or hpp.pos.x) + sx, (d.py or hpp.pos.y) + sy, d.weak_l, d.weak_n, d.weak_k, d.weak_alpha, d.gx, d.gy, push_font_size, tonumber(I.text_size) or 1, d.mob_rec)
end
-- 2.8.0: the monster info badges (aggro, links, detection...) and their summary line
local function draw_mob_layer(dl, d)
    local I = hpp.s.info
    if hpp.png_mob then Mob.png = hpp.style_png(hpp.png_mob, 'mob', I.icon_style) end
    local wk = d.weak_k or (d.mob_rec and d.mob_rec.K)
    local wt = wk and Weak.tooltip(wk, I.weak, true) or nil
    local sx, sy = off_shift('mob', I.mob, d)
    Mob.draw(dl, I.mob, (d.px or hpp.pos.x) + sx, (d.py or hpp.pos.y) + sy, d.mob_l, d.mob_n, d.mob_rec, d.mob_alpha, d.gx, d.gy, push_font_size, tonumber(I.text_size) or 1, wt)
end

-- Draw the info (and effects) of one monster. as_main = true for the main target (fade + glide apply).
local NPC_BLUE = { 0.55, 0.75, 1.00, 1 }
-- 2.12.0: the main target off the screen: its bar docks above the party list instead (the side nearest the screen's
-- edge, DOCK_M px apart), in a panel with the party list's background and border; RecastXI, when attached, moves up
-- above it. DOCK.r* = the bar's box relative to its anchor (last drawn), DOCK.list = the list's box last frame.
-- 2.12.2: the panel is the party list's width (the bar centred in it), fades in over DOCK_FADE and RecastXI slides up
-- (and back down) over the same time (DOCK.slide); info.dock_pin keeps the current target there even when on screen.
local DOCK = { lay = {}, rx0 = -90, ry0 = -70, rx1 = 90, ry1 = 10, on = false, was = nil, t0 = -10, list = nil, box = { 0, 0, 0, 0 }, pad = 13,     -- 2.13.2: 13 px inside the panel (was 8)
               slide = { from = 0, to = 0, cur = 0, t0 = -10 } }
local DOCK_M, DOCK_FADE = 20, 0.2
hpp.dock = DOCK
-- 1.0.6: the card's anchor no longer follows what this target shows (its box used to be centred in the panel, so a
-- level, a longer distance or name icons moved everything): it sits at the middle of the list, and the panel's
-- height comes from the layout (DOCK.ly0 / ly1: the room of every part switched on), growing only for more rows
-- (effects, extra weakness rows). Its sides reach the list's, or further when a part sticks out.
local function dock_place(out)
    local W, H = hpp.disp_w > 0 and hpp.disp_w or 1280, hpp.disp_h > 0 and hpp.disp_h or 720
    local p = DOCK.pad
    local top, bot = DOCK.ry0, DOCK.ry1
    if DOCK.ly0 ~= nil and DOCK.ly0 < top then top = DOCK.ly0 end
    if DOCK.ly1 ~= nil and DOCK.ly1 > bot then bot = DOCK.ly1 end
    local bh = bot - top + 2 * p
    local L, cx, by1 = DOCK.list, nil, nil
    local bx0, bx1
    if L ~= nil then
        cx, by1 = (L[1] + L[3]) / 2, L[2] - DOCK_M
        bx0, bx1 = L[1], L[3]                       -- 1.0.8 (Joshua): the party list's width, always
    else
        cx, by1 = W - DOCK_M - p - DOCK.rx1, H * 0.7
        bx0, bx1 = cx + DOCK.rx0 - p, cx + DOCK.rx1 + p
    end
    local sh = 0                                    -- kept on the screen
    if bx0 < DOCK_M then sh = DOCK_M - bx0 elseif bx1 > W - DOCK_M then sh = (W - DOCK_M) - bx1 end
    bx0, bx1, cx = bx0 + sh, bx1 + sh, cx + sh
    local by0 = math.max(DOCK_M, by1 - bh)
    local B = DOCK.box
    B[1], B[2], B[3], B[4] = bx0, by0, bx1, by0 + bh
    out.x, out.y = cx, by0 + p - top
end
-- RecastXI's lift above the list (px): eases to the docked panel's top over DOCK_FADE, and back to 0
local function dock_slide(want, now)
    local S = DOCK.slide
    if math.abs(want - S.to) > 0.5 then S.from, S.to, S.t0 = S.cur, want, now end
    local u = math.max(0, math.min(1, (now - S.t0) / DOCK_FADE))
    u = u * u * (3 - 2 * u)
    S.cur = S.from + (S.to - S.from) * u
    return S.cur
end
-- 1.0.3: the sub-target's card moves off the main target's card when they would overlap (plus info.apart px between
-- them): up when it sits above the main card's middle, else down, easing there and back. SEP.main = the main card's
-- box this frame (or nil); SUBB = the sub card's box, kept relative to its anchor (last frame).
local SUBB = { x0 = 0, y0 = 0, x1 = 0, y1 = 0, n = 0, gx = 0, gy = 0, on = false, ok = false, rx0 = 0, ry0 = 0, rx1 = 0, ry1 = 0 }
local SEP = { main = nil, cur = 0, t = nil, idx = 0 }
local MAIN_IB = Draw.IB
hpp.sep, hpp.subb = SEP, SUBB
local function sub_apart(I, idx, now)
    local dt = math.min(0.1, now - (SEP.t or now)); SEP.t = now
    if SEP.idx ~= idx then SEP.idx, SUBB.ok = idx, false end
    local want = 0
    local M_ = SEP.main
    if M_ ~= nil and SUBB.ok then
        local m = math.max(0, tonumber(I.apart) or 10)
        local x0, y0 = hpp.pos.x + SUBB.rx0, hpp.pos.y + SUBB.ry0
        local x1, y1 = hpp.pos.x + SUBB.rx1, hpp.pos.y + SUBB.ry1
        if x0 < M_.x1 + m and x1 > M_.x0 - m and y0 < M_.y1 + m and y1 > M_.y0 - m then
            if (y0 + y1) / 2 < (M_.y0 + M_.y1) / 2 then want = (M_.y0 - m) - y1 else want = (M_.y1 + m) - y0 end
        end
    end
    local k = 1 - math.exp(-dt * 14)
    SEP.cur = SEP.cur + (want - SEP.cur) * k
    if math.abs(want - SEP.cur) < 0.3 then SEP.cur = want end
    hpp.pos.y = hpp.pos.y + SEP.cur
end

-- 1.0.7 (Joshua): the party's hate list on the docked card. A monster is on it while it is alive, within 50 yalms, and
-- claimed by a party / alliance member, or fought by one (engaged on it), or targeting one, or acted on one / was acted
-- on by one in the last HATE_SECS. Rows keep the order they joined in, so they do not jump around. Click a row to
-- target that monster.
local HATE_SECS = 30
local HATE = { rows = {}, n = 0, seen = {}, first = {}, at = -1, ms = {}, mi = {}, fight = {}, h = 0, t0 = -10, was = false }
hpp.hate = HATE
local function hate_sort(a, b) if a.first ~= b.first then return a.first < b.first end return a.idx < b.idx end
function hpp.hate_build(now)
    if now - HATE.at < 0.25 then return end
    HATE.at = now
    local e, party = get_entity(), get_party()
    local MS, MI, FI = HATE.ms, HATE.mi, HATE.fight
    for k in pairs(MS) do MS[k] = nil end
    for k in pairs(MI) do MI[k] = nil end
    for k in pairs(FI) do FI[k] = nil end
    local n = 0
    if e ~= nil and party ~= nil then
        for i = 0, 17 do
            if party:GetMemberIsActive(i) == 1 then
                local sid, mi = party:GetMemberServerId(i) or 0, party:GetMemberTargetIndex(i) or 0
                if sid ~= 0 then MS[sid] = true end
                if mi ~= 0 then
                    MI[mi] = true
                    if (e:GetStatus(mi) or 0) == 1 then
                        local ok, t = pcall(e.GetTargetedIndex, e, mi)
                        t = ok and tonumber(t) or 0
                        if t ~= 0 then FI[t] = true end
                    end
                end
            end
        end
        for idx = 1, 1023 do
            if is_monster(idx) and (e:GetHPPercent(idx) or 0) > 0 then
                local sid = e:GetServerId(idx) or 0
                if sid ~= 0 then
                    local hot = FI[idx] == true
                    if not hot then
                        local ok, c = pcall(e.GetClaimStatus, e, idx)
                        c = ok and tonumber(c) or 0
                        hot = c ~= 0 and MS[c] == true
                    end
                    if not hot then
                        local t = HATE.seen[sid]
                        hot = t ~= nil and now - t <= HATE_SECS
                    end
                    if not hot then
                        local ok, t = pcall(e.GetTargetedIndex, e, idx)
                        t = ok and tonumber(t) or 0
                        hot = t ~= 0 and MI[t] == true
                    end
                    local d2 = hot and tonumber(e:GetDistance(idx)) or nil
                    if hot and d2 ~= nil and d2 >= 0 and d2 <= 2500 then
                        n = n + 1
                        local r = HATE.rows[n]
                        if r == nil then r = {}; HATE.rows[n] = r end
                        if HATE.first[sid] == nil then HATE.first[sid] = now end
                        r.idx, r.sid, r.first = idx, sid, HATE.first[sid]
                    end
                end
            end
        end
    end
    for i = n + 1, #HATE.rows do HATE.rows[i] = nil end
    HATE.n = n
    -- forget the join times of monsters no longer on it
    for sid in pairs(HATE.first) do
        local on = false
        for i = 1, n do if HATE.rows[i].sid == sid then on = true; break end end
        if not on then HATE.first[sid] = nil end
    end
    for sid, t in pairs(HATE.seen) do if now - t > HATE_SECS then HATE.seen[sid] = nil end end
    table.sort(HATE.rows, hate_sort)
end
-- this frame's names, health and distance of the rows (cheap; the list itself is rebuilt 4 times a second)
-- 1.0.8 (Joshua): your current target is on its card, not in the list: it leaves the list while it is your target
-- and comes back (in its old place) when you target something else. HATE.show = the rows shown, in order.
HATE.show = {}
local function hate_cur() return hpp.st.main ~= 0 and hpp.st.main or (hpp.st.held or 0) end
local function hate_count(max)
    local cur, n = hate_cur(), 0
    for i = 1, HATE.n do if HATE.rows[i].idx ~= cur then n = n + 1; if n >= max then break end end end
    return n
end
local function hate_fill(e, max)
    local cur, n, S = hate_cur(), 0, HATE.show
    for i = 1, HATE.n do
        local r = HATE.rows[i]
        if r.idx ~= cur and n < max then
            n = n + 1
            S[n] = r
            r.name, r.hp = e:GetName(r.idx), e:GetHPPercent(r.idx) or 0
            local d2 = tonumber(e:GetDistance(r.idx))
            r.dist = (d2 ~= nil and d2 >= 0) and math.sqrt(d2) or nil
        end
    end
    for i = n + 1, #S do S[i] = nil end
    return n
end
-- targets a monster by its index (Ashita's target object); false when this Ashita cannot
function hpp.target_index(idx)
    local ok, r = pcall(function ()
        local t = AshitaCore:GetMemoryManager():GetTarget()
        return t:SetTarget(idx, false)
    end)
    if not ok and not hpp.target_err then
        hpp.target_err = true
        err('Could not target from the hate list (this Ashita has no SetTarget): ' .. tostring(r))
    end
    return ok
end
-- the rows' click areas: an invisible window over them, one button per row
local HWIN = { pos = { 0, 0 }, size = { 0, 0 }, open = { true }, btn = { 0, 0 } }
local function hate_clicks(x0, y0, w, h, n)
    if n <= 0 or h <= 0 then return end
    local fl = function (name) local v = rawget(_G, name); return type(v) == 'number' and v or 0 end
    local flags = bit.bor(fl('ImGuiWindowFlags_NoDecoration'), fl('ImGuiWindowFlags_NoBackground'), fl('ImGuiWindowFlags_NoNav'),
        fl('ImGuiWindowFlags_NoFocusOnAppearing'), fl('ImGuiWindowFlags_NoSavedSettings'), fl('ImGuiWindowFlags_NoScrollWithMouse'),
        fl('ImGuiWindowFlags_NoMove'), fl('ImGuiWindowFlags_NoBringToFrontOnFocus'))
    HWIN.pos[1], HWIN.pos[2], HWIN.size[1], HWIN.size[2] = x0, y0, w, h
    imgui.SetNextWindowPos(HWIN.pos, fl('ImGuiCond_Always'))
    imgui.SetNextWindowSize(HWIN.size, fl('ImGuiCond_Always'))
    local okb, open = pcall(imgui.Begin, 'partyramaxi_hate', HWIN.open, flags)
    if okb and open then
        pcall(function ()
            for i = 1, n do
                local r = HATE.show[i]
                if r ~= nil and r.y0 ~= nil then
                    HWIN.btn[1], HWIN.btn[2] = w, math.max(1, r.y1 - r.y0)
                    imgui.SetCursorScreenPos({ x0, r.y0 })
                    if imgui.InvisibleButton('##pxi_hate' .. i, HWIN.btn) then hpp.target_index(r.idx) end
                end
            end
        end)
    end
    if okb then imgui.End() end
end
local function hate_draw(dl, I, x0, y0, w, alpha, now)
    local e = get_entity()
    if e == nil then return 0 end
    local n = hate_fill(e, math.max(1, math.floor(tonumber(I.dock_hate_max) or 8)))
    local ok, h = pcall(Info.draw_hate, dl, I, x0, y0, w, HATE.show, n, hate_cur(), alpha, push_font_size)
    if not ok then
        if not hpp.hate_err then hpp.hate_err = true; err('The hate list hit an error: ' .. tostring(h)) end
        return 0
    end
    hate_clicks(x0, y0, w, h, n)
    return h
end

-- mode (2.12.7): nil = over the target, docked when off the screen (or pinned); 'dock' = only the docked card;
-- 'float' = only over the target (the pinned card's "keep the bar over the target too" pass)
local PIN_TMP = { x = 0, y = 0 }
local function draw_target(e, I, dl, idx, which, as_main, now, mode)
    local dm = death_mul(e, idx, now)
    if dm == nil then return end
    if not (idx == hpp.ghost and idx ~= hpp.st.main) then dm = dm * hpp.fade_in_mul(which, now) end
    local name = e:GetName(idx)
    -- players and NPCs get no level / check; NPCs and objects get a soft blue name. 2.9.0: name, health bar, distance
    -- and icons are switched per kind (Enemies / Players / NPCs), and each kind can sit at a fixed spot on the screen.
    local kind = hpp.info_kind(idx) or 'mob'
    local K = I.kinds[kind]
    if not K.enabled then return end
    if K.hide_events and (hpp.ui_hidden or hpp.in_event) then return end
    if type(name) ~= 'string' or name == '' or not ((idx == hpp.ghost and idx ~= hpp.st.main) or hpp.settled(which, idx)) then return end
    local docked = false
    local pin = as_main and I.dock ~= false and I.dock_pin == true and mode ~= 'float'   -- 2.12.2: pinned there even when on screen
    if K.abs then
        -- 1.0.8 (Joshua): a pinned kind (its spot replaces floating) still docks when its target is off the screen,
        -- or always with "Always dock the current target"; else it sits at its spot
        if as_main and I.dock ~= false and mode ~= 'float' and (pin or not info_place(which, idx, PIN_TMP)) then
            dock_place(hpp.pos); docked = true
        elseif mode == 'dock' then return
        else hpp.pos.x, hpp.pos.y = tonumber(K.ax) or 0, tonumber(K.ay) or 0 end
    elseif pin or not info_place(which, idx, hpp.pos) then
        if mode == 'float' or not (as_main and I.dock ~= false) then return end
        dock_place(hpp.pos); docked = true
    end
    if which == 'sub' and not K.abs then sub_apart(I, idx, now) end
    if as_main and mode ~= 'float' then
        -- fades in at its new place each time it docks or undocks (and for a new target)
        if DOCK.was ~= docked or (docked and DOCK.idx ~= idx) then DOCK.t0 = now end
        DOCK.was, DOCK.idx = docked, idx
        DOCK.on = docked
        if docked or now - DOCK.t0 < DOCK_FADE then dm = dm * math.min(1, (now - DOCK.t0) / DOCK_FADE) end
    end
    info_d.name, info_d.hp, info_d.idx, info_d.now = name, e:GetHPPercent(idx) or 0, idx, now
    info_d.tint = (kind == 'npc') and (I.npc_color or NPC_BLUE) or nil
    info_d.mob = kind == 'mob'
    info_d.off = (kind ~= 'mob') and K.off or nil
    info_d.badge_n = 0
    -- 1.0.5: the docked card has its own switch for each part (info.dock_*), apart from the kind's
    if kind == 'pc' and ((docked and I.dock_badges ~= false) or (not docked and K.badges ~= false)) then hpp.name_badges(e, idx, info_d, K) end
    info_d.dock = docked
    if docked then info_d.off = I.dock_pos end       -- 1.0.5: the docked card's own place for each part
    -- 1.0.6: the room each part switched on takes on the docked card, whatever this target shows
    if docked then
        local LY = DOCK.lay
        LY.name, LY.dist, LY.bar = I.dock_name ~= false, I.dock_dist ~= false, I.dock_bar ~= false
        LY.level, LY.check, LY.defev = I.dock_level == true, I.dock_check == true, I.dock_defev == true
        LY.weak, LY.mob = I.dock_weak == true, I.dock_mob == true
        info_d.lay = LY
    else
        info_d.lay = nil
    end
    if docked then
        info_d.noname, info_d.nobar, info_d.nodist = I.dock_name == false, I.dock_bar == false, I.dock_dist == false
    else
        info_d.noname, info_d.nobar, info_d.nodist = not K.name, not K.hp, not K.dist
    end
    if kind == 'pc' and not info_d.nodist then       -- 2.9.2: no distance when the target is you
        local p = get_party()
        if p ~= nil and idx == (p:GetMemberTargetIndex(0) or 0) then info_d.nodist = true end
    end
    info_d.nopct = (docked and I.dock_pct == false) or (not docked and I.bar['pct_' .. kind] == false)
    local c = info_d.mob and Info.get(idx, name) or nil
    info_d.level = info_d.mob and Info.level_text(c) or nil
    info_d.check, info_d.check_color = nil, nil
    if c then info_d.check, info_d.check_color = Info.check_text(c, I.check.style) end
    info_d.eva, info_d.def = c and c.eva, c and c.def
    info_d.inferred = false
    -- 2.8.0: LandSandBoat's record for this monster (weaknesses, aggro, detection, level...); its level (exact, so it replaces the check's estimate)
    local rec = nil
    if info_d.mob and (I.weak.show or I.mob.show or I.level.db ~= false or (docked and (I.dock_weak or I.dock_mob))) then rec = Mob.lookup(e:GetServerId(idx) or 0, name) end
    info_d.mob_rec = rec
    -- 2.10.0: this monster's own check (its level, when the server tells it) wins; else the data's level range
    if rec and I.level.db ~= false and not (c and c.level) then info_d.level = Mob.level_text(rec) or info_d.level end
    local d2 = tonumber(e:GetDistance(idx))
    info_d.dist = (d2 ~= nil and d2 >= 0) and math.sqrt(d2) or nil       -- the game keeps the squared distance
    local mx, my, fx_alpha = 0, 0, dm
    if as_main then
        info_d.a_name, info_d.a_bar, info_d.a_level = MAIN.name * dm, MAIN.bar * dm, MAIN.level * dm
        info_d.a_check, info_d.a_defev, info_d.a_dist = MAIN.check * dm, MAIN.defev * dm, MAIN.dist * dm
        mx, my, fx_alpha = MAIN.gx, MAIN.gy, MAIN.fx * dm
        if K.abs or docked then mx, my = 0, 0 end    -- a fixed spot (or the dock) does not glide
    else
        info_d.a_name, info_d.a_bar, info_d.a_level, info_d.a_check, info_d.a_defev, info_d.a_dist = dm, dm, dm, dm, dm, dm
    end
    info_d.gx, info_d.gy = mx, my
    -- 1.0.5: the docked card's own switches for level, check and defense / evasion (2.12.3's "only name, health and
    -- distance" became these, off by default)
    if docked then
        if I.dock_level ~= true then info_d.a_level = 0 end
        if I.dock_check ~= true then info_d.a_check = 0 end
        if I.dock_defev ~= true then info_d.a_defev = 0 end
    end
    -- 1.0.5: the check's results (level, difficulty, defense / evasion) fade in over CHECK_FADE s, starting
    -- CHECK_SHOW s after the target was picked, or when the reply came if that was later
    if info_d.mob then
        local cm = hpp.check_fade_mul(which, c, now)
        info_d.a_level, info_d.a_check, info_d.a_defev = info_d.a_level * cm, info_d.a_check * cm, info_d.a_defev * cm
    end
    -- the effect icons are one more layer of the info (drawn from Info.draw at their place in the stack)
    info_d.fx_n = 0
    local dock_fx = docked and I.dock_fx ~= false        -- 1.0.0: the docked card uses the party list's status icons instead
    if K.icons and not docked then
        local sid = e:GetServerId(idx) or 0
        if sid ~= 0 then
            info_d.fx_n = Fx.active(sid, now, I.fx, fx_list)
            info_d.fx_alpha, info_d.fx_now = fx_alpha, now
        end
    end
    info_d.fx_draw = info_d.fx_n > 0 and draw_fx_layer or nil
    -- weaknesses (monsters only; LandSandBoat's data by server id, else zone and name). 2.9.4: MobDB's numbers when
    -- its addon's data has this monster (Data: MobDB if installed)
    info_d.weak_n, info_d.weak_draw, info_d.weak_k = 0, nil, nil
    local WK = rec and rec.K or nil
    local weak_on = (docked and I.dock_weak == true) or (not docked and I.weak.show)     -- 1.0.5: the dock's own switch
    if weak_on and info_d.mob and I.weak.source ~= 'lsb' then
        WK = Weak.mobdb(e:GetServerId(idx) or 0, name, WK) or WK
    end
    if weak_on and WK ~= nil then
        local K = WK
        info_d.weak_n = Weak.build(K, I.weak, weak_list)
        info_d.weak_k, info_d.weak_l = K, weak_list
        info_d.weak_alpha = as_main and MAIN.weak * dm or dm
        info_d.weak_draw = info_d.weak_n > 0 and draw_weak_layer or nil
    end
    info_d.mob_n, info_d.mob_draw = 0, nil
    if rec ~= nil and ((docked and I.dock_mob == true) or (not docked and I.mob.show)) then
        info_d.mob_n = Mob.build(rec, I.mob, mob_list)
        info_d.mob_l, info_d.mob_alpha = mob_list, as_main and MAIN.mob * dm or dm
        info_d.mob_draw = draw_mob_layer
    end
    info_d.px, info_d.py = hpp.pos.x, hpp.pos.y
    local IB = Draw.IB
    if as_main then IB.on, IB.n, IB.gx, IB.gy = true, 0, mx, my end      -- 2.9.5: its box, for the glide clamp
    local main_ib = nil
    if which == 'sub' and not as_main then      -- 1.0.3: the sub card's own box (for keeping it off the main card)
        main_ib = IB
        IB = SUBB; IB.on, IB.n, IB.gx, IB.gy = true, 0, 0, 0
        Draw.IB = IB
    end
    if docked then
        local B, a = DOCK.box, info_d.a_name
        pcall(PList.panel, dl, B[1], B[2], B[3], B[4], math.max(info_d.a_bar or 0, a or 0))
    end
    Info.draw(dl, I, hpp.pos.x, hpp.pos.y, info_d, push_font_size)
    -- 1.0.0: effects on the docked card, drawn like the party list's status icons (its size, countdown, sort and pins),
    -- in a row under the card; the panel grows to hold them (next frame, like the rest of the card)
    if dock_fx then
        -- 1.0.2: they wrap at the panel's inner width (from its left edge), so every icon stays inside the card, at the
        -- card's own icon size and countdown switch
        local sid = e:GetServerId(idx) or 0
        -- 1.0.3: a target that died has lost its effects (the ones the addon saw land are dropped too)
        if (info_d.hp or 0) <= 0 and sid ~= 0 then Fx.fx[sid] = nil; sid = 0 end
        local B, p = DOCK.box, DOCK.pad
        local x0, iw = B[1] + p, math.max(1, (B[3] - B[1]) - 2 * p)
        -- 1.0.6: under the layout's room too, so the icons start at the same height for every target
        local LY = DOCK.lay
        local base_y = (IB.n > 0 and IB.y1 or hpp.pos.y)
        if LY.y1 ~= nil and LY.y1 > base_y then base_y = LY.y1 end
        local y0 = base_y + 8       -- 1.0.4: 8 px under the card's content (was 4)
        -- 1.0.5: or with the party list's own settings and place (off the card when the list's are)
        local ok, fw, fh, away = pcall(PList.buffs_ext, dl, hpp.s.list.buffs, sid, x0, y0, iw, dm, now, I.dock_fx_size, I.dock_fx_timers ~= false,
            I.dock_fx_list == true, B[2])
        if ok and (fh or 0) > 0 and not away then
            -- only the height grows the card: the icons never reach past the panel's sides, and its width stays the
            -- list's (or the card's), so the card is not pushed sideways by its own icons
            if IB.n == 0 then IB.x0, IB.y0, IB.x1, IB.y1 = x0, y0, x0 + fw, y0 + fh
            else IB.y1 = math.max(IB.y1, y0 + fh) end
            IB.n = IB.n + 1
        elseif not ok and not hpp.dock_fx_err then hpp.dock_fx_err = true; err('Effects on the docked card are off after an error: ' .. tostring(fw)) end
    end
    -- 1.0.7: the party's hate list under the card
    if docked and as_main and I.dock_hate == true and hate_count(1) > 0 then
        local B, p = DOCK.box, DOCK.pad
        local x0, iw = B[1] + p, math.max(1, (B[3] - B[1]) - 2 * p)
        local base_y = (IB.n > 0 and IB.y1 or hpp.pos.y)
        local LY = DOCK.lay
        if LY.y1 ~= nil and LY.y1 > base_y then base_y = LY.y1 end
        local y0 = base_y + 8
        local h = hate_draw(dl, I, x0, y0, iw, dm, now)
        if h > 0 then
            if IB.n == 0 then IB.x0, IB.y0, IB.x1, IB.y1 = x0, y0, x0 + iw, y0 + h
            else IB.y1 = math.max(IB.y1, y0 + h) end
            IB.n = IB.n + 1
            HATE.drawn = true
        end
    end
    IB.on = false
    if main_ib ~= nil then
        Draw.IB = main_ib
        SUBB.ok = SUBB.n > 0
        if SUBB.ok then
            SUBB.rx0, SUBB.ry0 = SUBB.x0 - hpp.pos.x, SUBB.y0 - hpp.pos.y
            SUBB.rx1, SUBB.ry1 = SUBB.x1 - hpp.pos.x, SUBB.y1 - hpp.pos.y
        end
    end
    if docked and IB.n > 0 then              -- 2.12.0: the docked card's box around its anchor, for its panel
        DOCK.rx0, DOCK.ry0 = IB.x0 - IB.gx - hpp.pos.x, IB.y0 - IB.gy - hpp.pos.y
        DOCK.rx1, DOCK.ry1 = IB.x1 - IB.gx - hpp.pos.x, IB.y1 - IB.gy - hpp.pos.y
    end
    if docked then                           -- 1.0.6: the layout's room, for the panel's height
        local LY = DOCK.lay
        DOCK.ly0 = LY.y0 and (LY.y0 - hpp.pos.y) or nil
        DOCK.ly1 = LY.y1 and (LY.y1 - hpp.pos.y) or nil
    end
    info_d.px, info_d.py = nil, nil
end

function hpp.draw_info(now)
    local I = hpp.s.info
    DEATH_FADE = math.max(0.05, tonumber(I.fade_out) or 0.30) + 1.0      -- 2.7.6: one second longer after a monster dies
    local e = get_entity()
    if e == nil then return end
    local st = hpp.st
    local dl = imgui.GetForegroundDrawList()
    do
        Fx.me = (get_party() and get_party():GetMemberServerId(0)) or 0
        Fx.tick(now)
    end
    fade_update(I, e, now)
    MAIN.name, MAIN.bar, MAIN.level, MAIN.check, MAIN.defev = fade_alpha(I.name), fade_alpha(I.bar), fade_alpha(I.level), fade_alpha(I.check), fade_alpha(I.defev)
    MAIN.fx, MAIN.dist, MAIN.weak, MAIN.mob = fade_alpha(I.fx), fade_alpha(I.dist), fade_alpha(I.weak), fade_alpha(I.mob)

    -- Glide: position from the tween in fade_update (same curve and speed both ways).
    local glide = fade.gval or 0
    MAIN.gx, MAIN.gy = (tonumber(I.glide_x) or 0) * glide, (tonumber(I.glide_y) or 0) * glide
    -- 2.9.5: the glide never pushes the info off the screen: last frame's box (less the glide it was drawn with) is
    -- kept inside the margin (2.10.0: 7.5% of the screen) and moved off the addon's windows and pointer arrows. The
    -- correction grows with the glide, so it eases in and out with it.
    Draw.IB = MAIN_IB                          -- 1.0.3: (the sub card borrows it only while it draws)
    local IB = Draw.IB
    local W, H = hpp.disp_w, hpp.disp_h
    local adt = math.min(0.1, now - (AV.t or now)); AV.t = now
    if glide > 0 and IB.n > 0 and W > 0 and H > 0 then
        local mx, my = W * GLIDE_MARGIN, H * GLIDE_MARGIN
        local bx0, by0, bx1, by1 = IB.x0 - IB.gx, IB.y0 - IB.gy, IB.x1 - IB.gx, IB.y1 - IB.gy
        local gx = clamp_glide(MAIN.gx, bx0, bx1, W, mx)
        local gy = clamp_glide(MAIN.gy, by0, by1, H, my)
        local ax, ay = avoid(bx0 + gx, by0 + gy, bx1 + gx, by1 + gy, W, H, mx, my)
        local k = math.min(1, adt * 10)
        AV.x, AV.y = AV.x + (ax - AV.x) * k, AV.y + (ay - AV.y) * k
        local g = math.min(1, glide)
        MAIN.gx = MAIN.gx + (gx + AV.x - MAIN.gx) * g
        MAIN.gy = MAIN.gy + (gy + AV.y - MAIN.gy) * g
    else
        AV.x, AV.y = 0, 0
    end
    IB.n = 0
    DOCK.on = false
    HATE.drawn = false
    if I.dock_hate == true and I.dock ~= false and not (hpp.ui_hidden or hpp.in_event) then hpp.hate_build(now) else HATE.n = 0 end

    -- You died: no enemy bar (the fight is over for you), and nothing remembered for when you get up.
    if hpp.dead then hpp.focus, hpp.ghost, hpp.prev_main = 0, 0, 0; return end
    -- A main target that just died keeps its info for the short fade-out even if the game already cleared the target.
    local main, sub = st.main, st.sub
    -- The sub-target cursor on the target you hold: the game reports it only as the sub-target. Keep the info where it
    -- is (as the held target) instead of moving it to the cursor's spot.
    if main == 0 and sub ~= 0 and st.held == sub then main = sub end
    -- The focus enemy: the last monster you targeted or attacked (or, with none, one that attacked you). Its info stays
    -- over it while you target allies, until you target or attack another monster, or it dies / leaves.
    if main ~= 0 and is_monster(main) and (e:GetHPPercent(main) or 0) > 0 then hpp.focus = main end
    local fo = hpp.focus
    if fo ~= 0 and fo ~= main then
        local nm = e:GetName(fo)
        if (e:GetHPPercent(fo) or 0) == 0 and hpp.alive[fo] then
            hpp.dying[fo] = hpp.dying[fo] or now; hpp.ghost = fo; hpp.focus = 0
        elseif type(nm) ~= 'string' or nm == '' or not is_monster(fo) then hpp.focus = 0 end
    end
    local main_ok = main ~= 0 and hpp.shows_info(main)
    hpp.info_main = main_ok and main or hpp.focus
    if main ~= hpp.prev_main then
        local pm = hpp.prev_main
        if main == 0 then hpp.focus = 0 end      -- Esc / target cleared: the remembered enemy goes too
        if pm ~= 0 and hpp.alive[pm] and (e:GetHPPercent(pm) or 1) == 0 then
            hpp.dying[pm] = hpp.dying[pm] or now
            hpp.ghost = pm
        end
        hpp.prev_main = main
    end

    -- 2.12.7: pinned with "keep the bar over the target too": the docked card first, then the floating bar (whose
    -- box the glide clamp uses next frame)
    local both = I.dock ~= false and I.dock_pin == true and I.dock_float == true
    local function draw_main(idx, which)
        if both then
            draw_target(e, I, dl, idx, which, true, now, 'dock')
            draw_target(e, I, dl, idx, which, true, now, 'float')
        else draw_target(e, I, dl, idx, which, true, now) end
    end
    if main_ok then draw_main(main, 'main')
    -- the remembered enemy only while you target someone (an ally); not after Esc
    elseif main ~= 0 and hpp.focus ~= 0 and hpp.focus ~= sub then draw_main(hpp.focus, 'focus') end
    -- The sub-target cursor shows the info as long as it is over a monster, but never fades or glides.
    -- 1.0.3: it keeps off the main card drawn above (Draw.IB holds that card's box now)
    SEP.main = (Draw.IB.n > 0) and Draw.IB or nil
    if I.show_sub and sub ~= 0 and sub ~= main and hpp.shows_info(sub) then draw_target(e, I, dl, sub, 'sub', false, now) end
    local g = hpp.ghost
    if g ~= 0 then
        local t0 = hpp.dying[g]
        if t0 == nil or now - t0 >= DEATH_FADE then hpp.ghost = 0
        elseif g ~= main and g ~= sub and g ~= hpp.focus then draw_main(g, 'main') end
    end
    -- 1.0.7: no docked card this frame but monsters on the hate list: the list alone, in the dock's panel
    local alone = I.dock_hate == true and I.dock ~= false and not HATE.drawn and not DOCK.on and hate_count(1) > 0
    if alone ~= HATE.was then HATE.t0 = now; HATE.was = alone end
    if alone then
        local a = math.min(1, (now - HATE.t0) / DOCK_FADE)
        local keep = HATE.keep or {}
        HATE.keep = keep
        keep[1], keep[2], keep[3], keep[4], keep[5], keep[6] = DOCK.rx0, DOCK.ry0, DOCK.rx1, DOCK.ry1, DOCK.ly0, DOCK.ly1
        DOCK.rx0, DOCK.ry0, DOCK.rx1, DOCK.ry1, DOCK.ly0, DOCK.ly1 = -40, 0, 40, math.max(1, HATE.h), nil, nil
        local P = HATE.pos or {}
        HATE.pos = P
        dock_place(P)
        local B, p = DOCK.box, DOCK.pad
        pcall(PList.panel, dl, B[1], B[2], B[3], B[4], a)
        HATE.h = hate_draw(dl, I, B[1] + p, B[2] + p, math.max(1, (B[3] - B[1]) - 2 * p), a, now)
        DOCK.on = true                      -- RecastXI keeps above it, like above the docked card
        DOCK.rx0, DOCK.ry0, DOCK.rx1, DOCK.ry1, DOCK.ly0, DOCK.ly1 = keep[1], keep[2], keep[3], keep[4], keep[5], keep[6]
    end
end

-- Asks the server for the check (2.7.1: always on). 2.10.0: once per individual monster (server id), again after
-- Info.KEEP s; nothing is reused by name or saved (data\checks.txt is no longer used).
Info.sid_of = function (idx) local e = get_entity(); return e and e:GetServerId(idx) or nil end
Info.now = function () return hpp.clock() end
-- 2.13.1: a check with no reply is sent again after CHECK_WAIT[n] s (n = tries so far), up to #CHECK_WAIT + 1 sends;
-- targeting the monster again after that starts a new round. Never two sends closer than CHECK_GAP s.
-- 2.13.2: the timing: 0.1, 0.2, 0.3, 1, 3, 8 s. The replies to these checks are kept out of the chat log.
-- 1.0.5 (Joshua): sent at once, then after 0.05 and 0.05 s, then no more (3 sends in all).
hpp.CHECK_WAIT, hpp.CHECK_GAP = { 0.05, 0.05 }, 0.05
hpp.CHECK_TRIES = #hpp.CHECK_WAIT + 1
local function check_dbg(fmt, ...) if hpp.check_dbg then msg(('Check debug: ' .. fmt):format(...)) end end
-- One automatic /check for idx when it is due (no reply yet, tries left, waits kept). sel = the selection counter
-- (a new round after the tries ran out once you pick it again); how = 'main' (/check <t>) or 'sub' (the check packet).
local function check_one(idx, now, sel, selkey, how)
    local e = get_entity()
    if e == nil or not is_monster(idx) or (e:GetHPPercent(idx) or 0) <= 0 then return end
    local name = e:GetName(idx)
    if type(name) ~= 'string' or name == '' then return end
    local sid = e:GetServerId(idx) or 0
    if sid == 0 then return end                                -- not spawned in yet: the server would not find it
    local c = Info.get(idx, name)
    if c ~= nil and (c.diff ~= nil or c.level ~= nil or c.eva ~= nil) then return end
    local t = Info.tried[sid]
    if type(t) ~= 'table' or now - t.t > Info.KEEP then t = { t = -100, n = 0 }; Info.tried[sid] = t end
    -- a new round when you target it again after the tries ran out (it is a new choice of yours, not a loop)
    if t[selkey] ~= sel then
        if t.n >= hpp.CHECK_TRIES then t.n = 0 end
        t[selkey] = sel
    end
    if t.n >= hpp.CHECK_TRIES then return end
    if t.n > 0 and now - t.t < (hpp.CHECK_WAIT[t.n] or 8) - 1e-6 then return end
    if now - (hpp.check_at or -100) < hpp.CHECK_GAP - 1e-6 then return end
    t.t, t.n, hpp.check_at = now, t.n + 1, now
    hpp.check_last = idx
    check_dbg('sending /check to %s (index %d, %s), try %d of %d', name, idx, how, t.n, hpp.CHECK_TRIES)
    if how == 'sub' then
        -- 1.0.6: the sub-target: the packet /check itself sends (0x00DD: server id, index, kind 0 = check), since
        -- /check <st> would open a target cursor of its own
        AshitaCore:GetPacketManager():AddOutgoingPacket(0xDD, { 0xDD, 0x08, 0x00, 0x00,
            sid % 256, math.floor(sid / 256) % 256, math.floor(sid / 65536) % 256, math.floor(sid / 16777216) % 256,
            idx % 256, math.floor(idx / 256) % 256, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 })
    else
        hpp.ac_queued = (hpp.ac_queued or 0) + 1        -- the command event tells these from a /check you type
        AshitaCore:GetChatManager():QueueCommand(-1, '/check <t>')
    end
end
hpp.check_one = check_one

function hpp.auto_check(now)
    local I = hpp.s.info
    if hpp.st.main ~= hpp.ac_main then hpp.ac_main = hpp.st.main; hpp.target_sel = (hpp.target_sel or 0) + 1 end
    if hpp.st.sub ~= hpp.ac_sub then hpp.ac_sub = hpp.st.sub; hpp.sub_sel = (hpp.sub_sel or 0) + 1 end
    if not (I.enabled and I.auto_check) then return end
    if hpp.ui_hidden or hpp.in_event then return end          -- the server ignores /check during events
    if hpp.st.main ~= 0 then check_one(hpp.st.main, now, hpp.target_sel, 'sel', 'main') end
    -- 1.0.6: the sub-target cursor's monster too (its card shows the check like the main one)
    local sub = hpp.st.sub or 0
    if sub ~= 0 and sub ~= hpp.st.main and I.show_sub ~= false then check_one(sub, now, hpp.sub_sel, 'ssel', 'sub') end
end

-- 2.13.4: the icons over a player's name: linkshell pearl (its color) and the game's name icons, in the game's order.
-- info_d.badges[i] = { t = text or nil (pearl), c = color }; badge_n = how many; badge_px = their height.
-- 1.0.4: each name icon is a picture in icons\badges\ (f = its file); the label pill (t, c) is only the fallback
-- when the picture is missing. lfm (Flags3 bit 1) is level sync (it was shown as INV).
local BADGE = {
    ls     = { 0, 0, 0, 1 },                                             -- color set per player
    lfp    = { t = 'LFP',  f = 'lfp.png',    c = { 0.30, 0.60, 1.00, 1 } },   -- seeking a party (Flags1 bit 11)
    lfm    = { t = 'SYNC', f = 'sync.png',   c = { 0.25, 0.75, 0.95, 1 } },   -- level sync (Flags3 bit 1)
    anon   = { t = 'ANON', f = 'anon.png',   c = { 0.62, 0.45, 0.85, 1 } },   -- /anon (bit 12)
    away   = { t = 'AWAY', f = 'away.png',   c = { 0.55, 0.55, 0.60, 1 } },   -- /away (bit 14)
    bazaar = { t = 'BAZ',  f = 'bazaar.png', c = { 0.95, 0.75, 0.20, 1 } },   -- bazaar open (bit 31)
    mentor = { t = 'MNT',  f = 'mentor.png', c = { 0.35, 0.80, 0.45, 1 } },   -- mentor (Flags3 bit 24)
    new    = { t = 'NEW',  f = 'new.png',    c = { 0.60, 0.90, 0.35, 1 } },   -- new adventurer (Flags3 bit 23)
    dead   = { t = 'DC',   f = 'dc.png',     c = { 0.85, 0.30, 0.30, 1 } },   -- link dead (bit 18)
    gm     = { t = 'GM',   f = 'gm.png',     c = { 1.00, 0.35, 0.55, 1 } },   -- GM level (bits 24-26)
}
hpp.BADGE = BADGE
local function bitset(v, b) return math.floor(v / 2 ^ b) % 2 == 1 end
-- 1.0.4: in the game's order of importance (link dead, away, GM, seeking party / level sync, new adventurer / mentor,
-- bazaar; /anon has no game icon and comes last), then the pearl, nearest the name. K.badge_one: only the most
-- important icon (the pearl stays), the way the game shows one.
function hpp.name_badges(e, idx, d, K)
    local list = d.badges
    if list == nil then list = {}; d.badges = list end
    local n = 0
    local one = K.badge_one == true
    local function add(b, col)
        if one and n > 0 then return end
        n = n + 1; local x = list[n]; if x == nil then x = {}; list[n] = x end; x.t, x.c, x.f = b.t, col or b.c, b.f
    end
    local lc = tonumber(e:GetLinkshellColor(idx)) or 0                   -- BGR, alpha ignored; 0 = no linkshell
    local f = hpp.pc_flags[idx]
    local sid = e:GetServerId(idx) or 0
    if f ~= nil and f.sid ~= sid then f = nil end                         -- the index belongs to someone else now
    if f ~= nil then
        local f1, f3 = f.f1, f.f3
        if bitset(f1, 18) then add(BADGE.dead) end
        if bitset(f1, 14) then add(BADGE.away) end
        if math.floor(f1 / 2 ^ 24) % 8 > 0 then add(BADGE.gm) end
        if bitset(f1, 11) then add(BADGE.lfp) end
        if bitset(f3, 1) then add(BADGE.lfm) end
        if bitset(f3, 23) and K.badge_new ~= false then add(BADGE.new) end
        if bitset(f3, 24) then add(BADGE.mentor) end
        if bitset(f1, 31) then add(BADGE.bazaar) end
        if bitset(f1, 12) then add(BADGE.anon) end
    end
    if lc % 16777216 ~= 0 and (f == nil or bitset(f.f1, 17)) then
        local c = BADGE.ls
        c[1], c[2], c[3] = (lc % 256) / 255, (math.floor(lc / 256) % 256) / 255, (math.floor(lc / 65536) % 256) / 255
        one = false                                                       -- the pearl is always shown
        add({}, c)
    end
    d.badge_n, d.badge_px, d.badge_gap = n, tonumber(K.badge_size) or 16, tonumber(K.badge_gap) or 6
end

hpp.WEAK_SAMPLE = { e = { -2, 5, 0, 0, 0, 0, 0, 0 }, p = { 0, -25, 25, 0, 0 }, s = { dark_sleep = 99, light_sleep = 99 } }
hpp.MOB_SAMPLE = { K = hpp.WEAK_SAMPLE, nm = false, aggro = true, link = true, truesight = false, charm = false, jobs = 'WAR/THF',
    respawn = 330, detects = { sight = true }, family = 'Goblin', element = 'dark', drops = {}, steal = {}, lvmin = 18, lvmax = 20 }
local function draw_sample_fx(dl, d)
    local sx, sy = fx_shift(hpp.s.info.fx, d)
    Fx.draw(dl, hpp.s.info.fx, d.px + sx, d.py + sy, fx_sample, 3, d.fx_now, push_font_size, tonumber(hpp.s.info.text_size) or 1, 1, 0, 0)
end

function hpp.draw_preview(now)
    local a = hpp.s.arrow
    local dl = imgui.GetForegroundDrawList()
    local bob, alpha = Draw.anim(a, now)
    local line = a.outline and Draw.u32(a.outline_color, alpha) or 0
    local w = hpp.disp_w > 0 and hpp.disp_w or 1280
    local h = hpp.disp_h > 0 and hpp.disp_h or 720
    local size = tonumber(a.size) or 18
    local th = tonumber(a.outline_thickness) or 2
    hpp.shape(dl, w * 0.5 - size * 1.5, h * 0.35 - bob, 'down', size, a.sub_color, alpha, line, th)
    hpp.shape(dl, w * 0.5 + size * 1.5, h * 0.35, 'down', size, a.main_color, 1, line, th)
    -- and one over your own character, to check the over-head projection
    local party = get_party()
    local me = party and party:GetMemberTargetIndex(0) or 0
    if me ~= 0 and entity_screen(me, hpp.pos) then
        hpp.src.self = 'entity'
        hpp.shape(dl, hpp.pos.x, hpp.pos.y - bob, 'down', size, a.sub_color, alpha, line, th)
    else
        hpp.src.self = 'none'
    end
    if hpp.s.info.enabled then
        local kind = hpp.preview_kind or 'mob'
        local K = hpp.s.info.kinds[kind]
        local px, py = w * 0.5, h * 0.62
        if me ~= 0 and hpp.src.self == 'entity' then px, py = hpp.pos.x, hpp.pos.y end
        if K.abs then px, py = tonumber(K.ax) or px, tonumber(K.ay) or py end
        hpp.draw_sample(dl, kind, px, py, now)
    end
end

-- A sample target bar of one kind ('mob' | 'pc' | 'npc') with its tip at px, py: the Test buttons and the fixed-spot
-- markers use it. Its health drops, then refills, so the bar's trail, sheen and comet can be seen.
local SAMPLE_NAME = { mob = 'Sample Goblin', pc = 'Sample Player', npc = 'Sample NPC' }
function hpp.draw_sample(dl, kind, px, py, now)
    local I = hpp.s.info
    local K = I.kinds[kind]
    local d = info_d
    local t = now % 10
    local hp = 100
    if t >= 2 and t < 4 then hp = 100 - 60 * (t - 2) / 2 elseif t >= 4 and t < 6 then hp = 40 elseif t >= 6 and t < 8 then hp = 40 + 60 * (t - 6) / 2 end
    local mob = kind == 'mob'
    d.name, d.hp, d.level, d.idx, d.now, d.inferred = SAMPLE_NAME[kind], hp, mob and 'Lv 18-20' or nil, -1, now, false
    d.mob, d.tint = mob, (kind == 'npc') and (I.npc_color or NPC_BLUE) or nil
    d.noname, d.nobar, d.nodist, d.nopct = not K.name, not K.hp, not K.dist, I.bar['pct_' .. kind] == false
    d.off = (not mob) and K.off or nil
    d.a_name, d.a_bar, d.a_level, d.a_check, d.a_defev, d.a_dist = 1, 1, 1, 1, 1, 1
    d.eva, d.def, d.dist = mob and 1 or nil, mob and -1 or nil, 8.4 + 14 * (now % 10) / 10
    d.gx, d.gy = 0, 0
    d.check, d.check_color = nil, nil
    if mob then d.check, d.check_color = Info.check_text({ diff = 4 }, I.check.style) end
    local F = I.fx
    d.fx_n, d.fx_draw = 0, nil
    if K.icons then
        -- three sample effects that count down in a loop (the last one wears off and shows the dimmed look)
        local cyc = 20
        local left = cyc - (now % cyc)
        local ids = { 134, 2, 13 }
        for i = 1, 3 do
            local e = fx_sample[i]
            if e == nil then e = {}; fx_sample[i] = e end
            e.status, e.spell, e.actor, e.dur = ids[i], 0, 0, cyc
            e.exp, e.t0 = now + left - (i - 1) * 3, now - (cyc - left)
        end
        d.fx_n, d.fx_now, d.fx_alpha, d.fx_draw = 3, now, 1, draw_sample_fx
    end
    d.px, d.py = px, py
    -- a sample monster that is weak to fire and blunt, resists ice and piercing and can't be slept
    d.weak_n, d.weak_draw, d.mob_rec = 0, nil, mob and hpp.MOB_SAMPLE or nil
    if mob and I.weak.show then
        d.weak_k = hpp.WEAK_SAMPLE
        d.weak_n = Weak.build(d.weak_k, I.weak, weak_sample)
        d.weak_l, d.weak_alpha = weak_sample, 1
        d.weak_draw = d.weak_n > 0 and draw_weak_layer or nil
    end
    d.mob_n, d.mob_draw = 0, nil
    if mob and I.mob.show then
        d.mob_n = Mob.build(hpp.MOB_SAMPLE, I.mob, mob_sample)
        d.mob_l, d.mob_alpha, d.mob_draw = mob_sample, 1, draw_mob_layer
    end
    Info.draw(dl, I, px, py, d, push_font_size)
    d.fx_draw, d.weak_draw, d.mob_draw, d.mob_rec, d.off = nil, nil, nil, nil, nil
    d.px, d.py = nil, nil
end

-- 2.9.0: while the settings window is open, each kind with "Fixed spot on the screen" on shows a sample there with a
-- handle under it to drag it somewhere else. The handle is a small ImGui window (so a drag never reaches the game);
-- its position is set every frame unless it is being dragged, and Begin always follows SetNextWindowPos.
local ABS_LABEL = { mob = 'Enemies', pc = 'Players', npc = 'NPCs' }
local ABS_DRAG, ABS_SIZE, ABS_POS = {}, { 150, 26 }, { 0, 0 }
function hpp.draw_abs(now)
    local I = hpp.s.info
    local dl = imgui.GetForegroundDrawList()
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar or 0, ImGuiWindowFlags_NoResize or 0, ImGuiWindowFlags_NoScrollbar or 0,
        rawget(_G, 'ImGuiWindowFlags_NoSavedSettings') or 0, rawget(_G, 'ImGuiWindowFlags_NoCollapse') or 0)
    for _, kind in ipairs({ 'mob', 'pc', 'npc' }) do
        local K = I.kinds[kind]
        if K.abs and K.enabled then
            local ax, ay = tonumber(K.ax) or 0, tonumber(K.ay) or 0
            hpp.draw_sample(dl, kind, ax, ay, now)
            if not ABS_DRAG[kind] then
                ABS_POS[1], ABS_POS[2] = ax - ABS_SIZE[1] / 2, ay + 4
                imgui.SetNextWindowPos(ABS_POS, ImGuiCond_Always)
            end
            imgui.SetNextWindowSize(ABS_SIZE, ImGuiCond_Always)
            if imgui.Begin('##hpp_abs_' .. kind, nil, flags) then
                imgui.Text('Target bar: ' .. ABS_LABEL[kind])
                local hov = imgui.IsWindowHovered and imgui.IsWindowHovered() or false
                local down = imgui.IsMouseDown and imgui.IsMouseDown(0) or false
                if down and hov and ABS_DRAG[kind] == nil then ABS_DRAG[kind] = true end
                if not down and ABS_DRAG[kind] then ABS_DRAG[kind] = nil; hpp.schedule_save() end
                if ABS_DRAG[kind] then
                    local wx, wy = imgui.GetWindowPos()
                    if type(wx) == 'table' then wx, wy = wx.x or wx[1], wx.y or wx[2] end
                    wx, wy = tonumber(wx), tonumber(wy)
                    if wx and wy then K.ax, K.ay = math.max(0, math.floor(wx + ABS_SIZE[1] / 2 + 0.5)), math.max(0, math.floor(wy - 4 + 0.5)) end
                end
            end
            imgui.End()
        end
    end
end

-- 2.9.0: the monster card (hover over the monster info or weakness icons) is drawn last, in front of everything.
function hpp.draw_card()
    local I = hpp.s.info
    Mob.flush(imgui.GetForegroundDrawList(), push_font_size, tonumber(I.mob.card_scale) or 1, hpp.disp_w, hpp.disp_h)
    Fonts.unwind()
end

---------------------------------------------------------------------------
-- Guards: one failing part must not stop the others, and must not spam the chat
---------------------------------------------------------------------------
local ZONE_TIMEOUT = 90          -- a zone change that never finishes (missed packet) is dropped after this
local reported, reported_n = {}, 0

local function guard(tag, fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    local key = tag .. ': ' .. tostring(v)
    if not reported[key] and reported_n < 20 then
        reported[key] = true; reported_n = reported_n + 1
        err('Error in ' .. tag .. ' (reported once): ' .. tostring(v))
    end
    return nil
end

---------------------------------------------------------------------------
-- Settings check: the settings file is plain Lua and can be edited by hand (or come from an older
-- version), so every value is checked on load and on character switch. Wrong types and unknown
-- choices go back to the default, numbers are clamped; one chat line lists what was changed.
---------------------------------------------------------------------------
local ENUMS = {
    ['arrow.mode'] = { auto = true, entity = true, native = true, off = true },
    ['arrow.mode_on'] = { auto = true, entity = true, native = true },
    ['arrow.when'] = { hidden = true, always = true },
    ['info.check.style'] = { short = true, full = true, both = true },
    ['info.bar.gloss'] = { none = true, gradient = true, glossy = true, shine = true },
    ['info.fade_when'] = { me = true, target = true, either = true },
    ['info.glide_ease'] = { smooth = true, smoother = true, ease_in = true, back = true, bounce = true, spring = true },
    ['info.fx.sort'] = { soonest = true, oldest = true, newest = true },
    ['list.buffs.timer_pos'] = { inside = true, below = true, off = true }, ['list.buffs.ring'] = { none = true, ring = true, bar = true, top = true }, ['list.buffs.ring_shape'] = { circle = true, square = true }, ['list.buffs.timer_unknown'] = { elapsed = true, none = true }, ['list.buffs.sort'] = { game = true, recent = true, soonest = true, longest = true, type = true },
    ['list.buffs.cancel'] = { confirm = true, click = true, off = true },
    ['info.fx.align'] = { center = true, left = true, right = true },
    ['info.fx.text'] = { below = true, inside = true, off = true },
    ['info.fx.ring'] = { none = true, ring = true, bar = true, top = true },
    ['info.fx.ring_shape'] = { circle = true, square = true },
}
local LIST_ENUMS = {
    ['list.bg.mode'] = { color = true, png = true }, ['list.bg.scope'] = { window = true, row = true },
    ['list.bg.frame.fit'] = { stretch = true, tile = true },
    ['list.job.format'] = { both = true, jobs = true, main = true, lv = true, none = true },
}
for _, b in ipairs({ 'hp', 'mp', 'tp' }) do
    LIST_ENUMS['list.' .. b .. '.gloss'] = { none = true, gradient = true, glossy = true, shine = true }
    LIST_ENUMS['list.' .. b .. '.text'] = { current = true, current_max = true, percent = true, both = true, none = true }
    LIST_ENUMS['list.' .. b .. '.text_pos'] = { center = true, left = true, right = true }
end
for k, v in pairs(LIST_ENUMS) do ENUMS[k] = v end
local RANGES = {   -- { min, max, integer }
    ['arrow.size'] = { 6, 64, true }, ['arrow.outline_thickness'] = { 1, 5, true },
    ['arrow.bob_amount'] = { 1, 20, true }, ['arrow.anim_speed'] = { 0.2, 4 },
    ['arrow.head_height'] = { 2, 5 }, ['arrow.head_gap'] = { -1, 3 }, ['arrow.native_dx'] = { -64, 64, true }, ['arrow.native_dy'] = { -250, 40, true },
    ['arrow.png_rotation'] = { 0, 270, true }, ['arrow.sheen_min'] = { 1, 60 }, ['arrow.sheen_max'] = { 1, 60 }, ['arrow.sheen_strength'] = { 0.1, 1 },
    ['list.x'] = { -20000, 20000, true }, ['list.y'] = { -20000, 20000, true },
    ['info.text_size'] = { 0.6, 3.5 },
    ['info.bar.width'] = { 20, 300, true }, ['info.bar.height'] = { 3, 30, true },
    ['info.bar.rounding'] = { 0, 30, true }, ['info.bar.border_width'] = { 1, 8, true },
    ['info.bar.gloss_strength'] = { 0, 1 }, ['info.bar.tick_len'] = { 1, 30, true }, ['info.bar.percent_scale'] = { 0.4, 2 },
    ['info.fade_delay'] = { 0, 30 }, ['info.fade_time'] = { 0.1, 2.5 }, ['info.glide_hold'] = { 0, 60 }, ['info.fade_in'] = { 0, 1 }, ['info.outline_w'] = { 1, 3, true }, ['list.outline_w'] = { 1, 3, true }, ['info.fade_out'] = { 0.05, 1 }, ['info.fx.flash_speed'] = { 0.5, 5 },
    ['info.fx.size'] = { 15, 72, true }, ['info.fx.spacing'] = { 0, 12, true }, ['info.fx.per_row'] = { 1, 16, true },
    ['info.fx.dx'] = { -4000, 4000, true }, ['info.glide_x'] = { -4000, 4000, true }, ['info.glide_y'] = { -4000, 4000, true }, ['info.fx.dy'] = { -4000, 4000, true }, ['info.fx.text_scale'] = { 0.4, 4 },
    ['info.fx.flash_min'] = { 0.1, 1 }, ['info.fx.ended_alpha'] = { 0.1, 1 },
    ['info.bar.outline_width'] = { 0, 5, true }, ['info.bar.pct_dx'] = { -200, 200, true }, ['info.bar.pct_dy'] = { -100, 100, true }, ['info.bar.comet_speed'] = { 0.3, 3 },
    ['info.fx.warn_secs'] = { 0, 30 }, ['info.fx.ring_width'] = { 1, 6, true }, ['info.fx.ring_pad'] = { 0, 10, true }, ['info.fx.duration_pct'] = { 25, 300, true },
}
local LR = {
    gap = { 0, 20, true }, gap_ally = { 0, 20, true }, gap_pet = { 0, 20, true }, out_alpha = { 0.1, 1 },
    ['cards.party.w'] = { 60, 800, true }, ['cards.party.h'] = { 10, 400, true }, ['cards.alliance.w'] = { 60, 800, true }, ['cards.alliance.h'] = { 10, 400, true },
    ['cards.pet.w'] = { 60, 800, true }, ['cards.pet.h'] = { 10, 400, true }, ['cards.sel.dw'] = { -100, 300, true }, ['cards.sel.dh'] = { -100, 300, true },
    ['sel.repeat_every'] = { 1, 15 },
    ['win.border_w'] = { 0, 3, true }, ['win.border_slice'] = { 1, 64, true }, ['win.top_dy'] = { -60, 60, true }, ['sel.rounding'] = { 0, 30, true }, ['win.rounding'] = { 0, 30, true },
    ['bg.slice'] = { 0, 64, true },
    ['card.border_w'] = { 0, 4, true }, ['card.rounding'] = { 0, 30, true },
    ['sel.border_w'] = { 1, 5, true }, ['sel.tint'] = { 0, 0.5 }, ['sel.move_dx'] = { -16, 16, true }, ['sel.move_dy'] = { -16, 16, true },
    ['head.scale'] = { 0.5, 5 }, ['name.scale'] = { 0.6, 5 }, ['job.scale'] = { 0.5, 5 },
    ['icon.size'] = { 10, 50, true }, ['icon.rounding'] = { 0, 30, true },
    ['action.scale'] = { 0.5, 5 }, ['action.bar_h'] = { 1, 8, true }, ['action.hold'] = { 0.5, 5 },
    ['buffs.size'] = { 15, 72, true }, ['buffs.flash_min'] = { 1, 900 }, ['buffs.flash_max'] = { 1, 900 }, ['buffs.flash_strength'] = { 0.1, 1 }, ['buffs.per_row'] = { 1, 32, true }, ['buffs.max'] = { 1, 32, true }, ['buffs.gap'] = { 0, 10, true }, ['buffs.timer_scale'] = { 0.3, 5 },
    ['buffs.fit_pad'] = { 0, 25, true }, ['buffs.ring_width'] = { 1, 6, true }, ['buffs.ring_pad'] = { 0, 10, true }, ['buffs.warn_secs'] = { 0, 30 }, ['buffs.warn_speed'] = { 0.5, 5 }, ['buffs.warn_min'] = { 0.1, 1 },
}
for _, b in ipairs({ 'hp', 'mp', 'tp' }) do
    LR[b .. '.height'] = { 3, 40, true }; LR[b .. '.rounding'] = { 0, 30, true }; LR[b .. '.border_w'] = { 1, 8, true }; LR[b .. '.outline_w'] = { 0, 5, true }
    LR[b .. '.gloss_strength'] = { 0, 1 }; LR[b .. '.text_scale'] = { 0.4, 5 }
end
for _, el in ipairs({ 'name', 'job', 'icon', 'ptext', 'hp', 'mp', 'tp', 'action', 'buffs' }) do
    LR[el .. '.dx'] = { -600, 600, true }; LR[el .. '.dy'] = { -600, 600, true }
end
LR['pointer.size'] = { 16, 60, true }; LR['pointer.dx'] = { -400, 400, true }; LR['pointer.dy'] = { -400, 400, true };
LR['hp.warn_at'] = { 0.05, 0.95 }; LR['hp.low_at'] = { 0.02, 0.9 }
LR['bg.frame.tile'] = { 0.1, 4 }; LR['bg.frame.scale'] = { 0.25, 3 }; LR['bg.frame.inset'] = { -20, 60, true }; LR['pointer.glide_speed'] = { 2, 40 }
ENUMS['list.over.aggro'] = { focus = true, any = true, off = true }; ENUMS['list.over.aggro_style'] = { arrow = true, outline = true, both = true }
LR['over.head'] = { 0.5, 6 }; LR['over.head_gap'] = { -1, 3 }; LR['over.width'] = { 20, 200, true }; LR['over.height'] = { 2, 20, true }; LR['over.rounding'] = { 0, 10, true }
LR['over.dx'] = { -200, 200, true }; LR['over.dy'] = { -200, 200, true }; LR['over.num_scale'] = { 0.3, 3 }; LR['over.num_dx'] = { -100, 100, true }; LR['over.num_dy'] = { -100, 100, true }
LR['over.ref'] = { 2, 30 }; LR['over.min_scale'] = { 0.1, 1 }; LR['over.max_scale'] = { 1, 3 }; LR['over.max_px'] = { 20, 600, true }; LR['over.max_dist'] = { 5, 60 }; LR['over.alpha'] = { 0.1, 1 }; LR['over.mp_height'] = { 1, 10, true }
for _, k in ipairs({ 'leader', 'aleader', 'qm' }) do
    LR['roles.' .. k .. '.size'] = { 6, 32, true }; LR['roles.' .. k .. '.dx'] = { -100, 100, true }; LR['roles.' .. k .. '.dy'] = { -100, 100, true }
    ENUMS['list.roles.' .. k .. '.style'] = { crown = true, star = true, coin = true, badge = true, dot = true, name = true, strip = true, none = true }
    ENUMS['list.roles.' .. k .. '.place'] = { icon = true, name = true, card = true }
end
LR['anim.speed'] = { 0.3, 3 }
LR['pets.scale'] = { 0.5, 5 }; LR['pets.indent'] = { 0, 60, true }; LR['pets.bar_h'] = { 3, 20, true }
LR['invite.banner'] = { 5, 120 }; LR['invite.timeout'] = { 60, 1800 }; LR['invite.text_scale'] = { 0.4, 3 }; LR['invite.size'] = { 12, 48, true }
LR['invite.dx'] = { -200, 200, true }; LR['invite.dy'] = { -200, 200, true }
ENUMS['info.bar.comet'] = { off = true, once = true }
ENUMS['info.dist.format'] = { short = true, long = true, plain = true, whole = true }
for k in pairs({ name = 1, dist = 1, level = 1, check = 1, defev = 1 }) do ENUMS['info.dock_pos.' .. k .. '.align'] = { left = true, center = true, right = true } end   -- 1.0.6
RANGES['info.dist.far_at'] = { 1, 60 }
RANGES['buffer.window'] = { 0.1, 1.0 }
RANGES['buffer.delay'] = { 0, 0.5 }
LR['sel.height'] = { -20, 40, true }
ENUMS['list.pets.mode'] = { attached = true, section = true }
ENUMS['list.pets.scope'] = { me = true, party = true, all = true }
ENUMS['list.invite.mode'] = { banner = true, icon = true, off = true }
for _, el in ipairs({ 'name', 'job', 'icon', 'ptext', 'hp', 'mp', 'tp', 'action', 'buffs', 'hpnum', 'mpnum', 'tpnum' }) do LR[el .. '.z'] = { -100, 100, true } end
for _, el in ipairs({ 'bar', 'name', 'level', 'check', 'defev', 'fx', 'dist', 'weak', 'mob' }) do RANGES['info.' .. el .. '.z'] = { -100, 100, true } end
-- 2.8.0: monster info badges
RANGES['info.mob.size'] = { 10, 48, true }; RANGES['info.mob.spacing'] = { 0, 12, true }; RANGES['info.mob.text_scale'] = { 0.4, 2 }
RANGES['info.mob.dx'] = { -4000, 4000, true }; RANGES['info.mob.dy'] = { -4000, 4000, true }
ENUMS['info.mob.align'] = { center = true, left = true, right = true }
-- painted: elements only (badges / damage types use glossy). 2.12.1: also any folder name (your own Icon Pack folders)
ENUMS['info.icon_style'] = setmetatable({ glossy = true, jewel = true, painted = true, flat = true, glyph = true, contrast = true, glass = true },
    { __index = function (_, v) return type(v) == 'string' and v:match('^[%w _%-]+$') ~= nil end })
ENUMS['info.weak.icon_style'] = ENUMS['info.icon_style']     -- 2.10.1
RANGES['info.mob.card_scale'] = { 0.6, 2 }
RANGES['info.kinds.pc.badge_size'] = { 10, 40, true }      -- 2.13.4: the name icons' height
-- 2.9.0: per kind of target
for _, k in ipairs({ 'mob', 'pc', 'npc' }) do
    RANGES['info.kinds.' .. k .. '.ax'] = { 0, 20000, true }; RANGES['info.kinds.' .. k .. '.ay'] = { 0, 20000, true }
    if k ~= 'mob' then
        for _, el in ipairs({ 'name', 'bar', 'dist', 'fx' }) do
            RANGES['info.kinds.' .. k .. '.off.' .. el .. '.dx'] = { -4000, 4000, true }; RANGES['info.kinds.' .. k .. '.off.' .. el .. '.dy'] = { -4000, 4000, true }
        end
        RANGES['info.kinds.' .. k .. '.off.pct.dx'] = { -200, 200, true }; RANGES['info.kinds.' .. k .. '.off.pct.dy'] = { -100, 100, true }
    end
end
RANGES['info.dock_hate_max'] = { 1, 20, true }   -- 1.0.7
-- 1.0.5: the docked card's own place for each part
for _, k in ipairs(hpp.DOCK_PARTS) do
    RANGES['info.dock_pos.' .. k .. '.dx'] = { -4000, 4000, true }; RANGES['info.dock_pos.' .. k .. '.dy'] = { -4000, 4000, true }
end
-- 2.7.7: weakness icons
RANGES['info.weak.size'] = { 10, 48, true }; RANGES['info.weak.spacing'] = { 0, 12, true }; RANGES['info.weak.per_row'] = { 1, 16, true }
RANGES['info.weak.dx'] = { -4000, 4000, true }; RANGES['info.weak.dy'] = { -4000, 4000, true }
RANGES['info.weak.resist_rank'] = { 1, 10, true }; RANGES['info.weak.resist_alpha'] = { 0.1, 1 }; RANGES['info.weak.pct_scale'] = { 0.5, 2 }
ENUMS['info.weak.align'] = { center = true, left = true, right = true }
ENUMS['info.weak.marks'] = { arrows = true, percent = true }
ENUMS['info.weak.source'] = { auto = true, lsb = true }
for _, b in ipairs({ 'hp', 'mp', 'tp' }) do
    LR[b .. '.text_dx'] = { -300, 300, true }; LR[b .. '.text_dy'] = { -100, 100, true }; LR[b .. '.comet_speed'] = { 0.3, 3 }
    ENUMS['list.' .. b .. '.comet'] = { off = true, once = true }; LR[b .. '.length'] = { 10, 500, true }
end
LR['tp.num_flash_speed'] = { 0.3, 4 }; LR['tp.num_flash_min'] = { 0, 1 }
LR['head.dx'] = { -400, 400, true }; LR['head.dy'] = { -400, 400, true }; LR['win.lines'] = { 0, 0.3 }
ENUMS['list.head.align'] = { left = true, center = true, right = true }
ENUMS['list.win.style'] = { line = true, tb = true, corners = true, gilded = true, custom = true, double = true, glow = true, bevel = true }   -- the last three: themes only
LR['ptext.scale'] = { 0.5, 5 }; LR['ptext.hold'] = { 1, 60 }; LR['ptext.fade'] = { 0.1, 10 }
-- 2.7.0: the alliance's own sizes and offsets have the party's ranges
for _, el in ipairs({ 'name', 'job', 'icon', 'action', 'hp', 'mp', 'tp' }) do
    for _, f in ipairs({ 'scale', 'size', 'height', 'length', 'dx', 'dy', 'text_scale', 'text_dx', 'text_dy' }) do
        if LR[el .. '.' .. f] then LR['ally_look.' .. el .. '.' .. f] = LR[el .. '.' .. f] end
    end
end
for k, v in pairs(LR) do RANGES['list.' .. k] = v end
ENUMS['list.ptext.mode'] = { both = true, note = true, chat = true, off = true }
ENUMS['list.ptext.scope'] = { all = true, party = true }
ENUMS['list.select_action'] = { auto = true, target = true }
ENUMS['list.over.anchor'] = { head = true }           -- 2.10.1: from the feet removed
ENUMS['list.over.num_fmt'] = { list = true, current = true, percent = true, both = true }
for _, el in ipairs({ 'name', 'bar', 'level', 'check', 'defev', 'dist' }) do
    RANGES['info.' .. el .. '.dx'] = { -4000, 4000, true }
    RANGES['info.' .. el .. '.dy'] = { -4000, 4000, true }
    RANGES['info.' .. el .. '.scale'] = { 0.5, 4 }
end
for _, el in ipairs({ 'name', 'bar', 'level', 'check', 'defev', 'fx', 'dist', 'weak', 'mob' }) do RANGES['info.' .. el .. '.fade_alpha'] = { 0, 1 } end
local function is_color(d) return type(d) == 'table' and #d == 4 and type(d[1]) == 'number' end
local function deepcopy(v)
    if type(v) ~= 'table' then return v end
    local r = {}
    for k, x in pairs(v) do r[k] = deepcopy(x) end
    if rawget(_G, 'T') then return T(r) end
    return r
end

function hpp.sanitize(s)
    local fixed = {}
    if type(s) ~= 'table' then return fixed end
    if type(s.info) == 'table' and not s.info.snap190 then        -- 1.9: snappier enemy fades (once; change them freely afterwards)
        s.info.fade_in, s.info.fade_out, s.info.fade_time, s.info.snap190 = 0.08, 0.15, 0.8, true
    end
    if type(s.list) == 'table' and type(s.list.bg) == 'table' and s.list.bg.mode == 'frame' then   -- 2.2: layered PNGs gone
        s.list.bg.mode = 'color'
    end
    local C = type(s.list) == 'table' and s.list.cards
    if type(C) == 'table' and C.link ~= false and type(C.party) == 'table' and type(C.alliance) == 'table' then   -- 2.2.1: linked card widths
        C.alliance.w = C.party.w
    end
    local SL = type(s.list) == 'table' and s.list
    if type(SL) == 'table' and not SL.cfg2101 then                 -- 2.10.1: sort by id gone; one anchor; largest size in px
        SL.cfg2101 = true
        if type(SL.buffs) == 'table' and SL.buffs.sort == 'id' then SL.buffs.sort = 'type' end
        local function px(O)
            if type(O) ~= 'table' then return end
            O.anchor = 'head'
            O.max_px = math.floor((tonumber(O.width) or 60) * (tonumber(O.max_scale) or 1.5) + 0.5)
        end
        px(SL.over)
        if type(SL.over_jobs) == 'table' then for _, O in pairs(SL.over_jobs) do px(O) end end
    end
    local WK = type(s.info) == 'table' and s.info.weak
    if type(WK) == 'table' and WK.icon_style == nil then WK.icon_style = s.info.icon_style end   -- 2.10.1: was shared with the badges
    if type(WK) == 'table' and not WK.rank293 then               -- 2.9.3: rank 4 hid every 15-40% resistance MobDB shows
        if WK.resist_rank == nil or tonumber(WK.resist_rank) == 4 then WK.resist_rank = 1 end
        WK.rank293 = true
    end
    if type(s.info) == 'table' and not s.info.fade220 then        -- 2.2: appear / disappear take 0.28 s like the battle fade
        s.info.fade_in, s.info.fade_out, s.info.fade220 = 0.28, 0.28, true
    end
    if type(s.list) == 'table' and not s.list.lay193 then          -- 1.9.3: fixed card sizes, no padding settings
        local L = s.list
        local function num(v, d) v = tonumber(v); if v == nil then return d end return v end
        local function px(sc) return math.floor(14 * num(sc, 1) + 0.5) end
        local function sub(k) return type(L[k]) == 'table' and L[k] or {} end
        local pad, cp, vg, hg = num(L.pad, 6), num(L.cpad, 5), num(L.vgap, 3), num(L.hgap, 4)
        local nm, jb, ic, hp, mp, tp, ac, bf, pc = sub('name'), sub('job'), sub('icon'), sub('hp'), sub('mp'), sub('tp'), sub('action'), sub('buffs'), sub('pets')
        local nameh = (nm.show ~= false) and px(nm.scale) or 0
        local jobh = (jb.show ~= false and jb.format ~= 'none') and px(jb.scale or 0.8) or 0
        local iconh = num(ic.size, 18)
        local hh, mh, th = num(hp.height, 14), num(mp.height, 9), num(tp.height, 9)
        local h = cp * 2 + math.max(nameh, jobh, iconh, 8)
        if L.layout == 'inline' then
            local bh = 0
            if hp.show ~= false then bh = math.max(bh, hh) end
            if mp.show ~= false then bh = math.max(bh, mh) end
            if tp.show ~= false or tp.text ~= 'none' then bh = math.max(bh, th) end
            if bh > 0 then h = h + vg + bh end
        else
            if hp.show ~= false then h = h + vg + hh end
            local tpon = tp.show ~= false or tp.text ~= 'none'     -- 2.7.6: bar or number
            if mp.show ~= false or tpon then h = h + vg + math.max(mp.show ~= false and mh or 0, tpon and th or 0) end
        end
        if ac.show ~= false and ac.reserve ~= false then h = h + vg + px(ac.scale or 0.8) + 2 end
        if bf.show ~= false and bf.reserve ~= false then
            local ex = (bf.timers ~= false and bf.timer_pos == 'below') and math.floor(14 * num(bf.timer_scale, 0.6) + 0.5) or 0
            h = h + vg + num(bf.size, 16) + ex
        end
        local ch = cp * 2 + math.max(nameh, iconh > 0 and math.min(iconh, nameh + 4) or 0, hp.show ~= false and hh or 0, 8)
        local cw = math.max(60, num(L.width, 260) - pad * 2)
        local ph = 6 + px(num(nm.scale, 1) * num(pc.scale, 0.85)) + 2 + num(pc.bar_h, 8) + ((pc.mptp ~= false) and 5 or 0)
        L.cards = { link = true, party = { w = cw, h = h }, alliance = { w = cw, h = ch }, pet = { w = math.max(60, cw - num(pc.indent, 14)), h = ph }, sel = { dw = 0, dh = 0 } }
        -- the old padding / line spacing moved the elements; keep them where they were, as offsets
        local d, dv = cp - 5, vg - 3
        if d ~= 0 or dv ~= 0 then
            local function mv(t, dx, dy) if type(t) == 'table' then t.dx = num(t.dx, 0) + dx; t.dy = num(t.dy, 0) + dy end end
            mv(ic, d, d); mv(nm, d, d); mv(sub('ptext'), d, d); mv(jb, -d, d)
            mv(hp, d, d + dv); mv(mp, d, d + 2 * dv); mv(tp, d, d + 2 * dv); mv(ac, d, d + 3 * dv); mv(bf, d, d + 4 * dv)
        end
        for _, k in ipairs({ 'width', 'pad', 'cpad', 'vgap', 'hgap', 'layout', 'inline_hp', 'mp_split', 'trim' }) do L[k] = nil end
        L.lay193 = true
    end
    if type(s.list) == 'table' then                                -- 1.9.1: the comet now plays once
        for _, b in ipairs({ 'hp', 'mp', 'tp' }) do
            local t = s.list[b]
            if type(t) == 'table' and (t.comet == 'ready' or t.comet == 'always') then t.comet = 'once' end
            if type(t) == 'table' and type(t.length) == 'number' and t.length < 10 then t.length = 150 end
        end
    end
    -- 2.4: the chat module is gone, and effect icons take one pack plus one fallback (the old third pack fills a gap)
    s.chat_zero, s.chat_rows, s.chat_guard = nil, nil, nil
    if type(s.windows) == 'table' then s.windows.chat = nil end
    local FX = type(s.info) == 'table' and s.info.fx
    if type(FX) == 'table' and FX.pack3 ~= nil then
        if (FX.pack or '') == '' then FX.pack, FX.pack2 = FX.pack2 or '', FX.pack3
        elseif (FX.pack2 or '') == '' then FX.pack2 = FX.pack3 end
        FX.pack3 = nil
    end
    -- 2.9.0: the "who gets a bar" switches became one set per kind of target (Enemies / Players / NPCs), and players
    -- and NPCs got their own offsets. Built once from the old switches, so nothing changes on screen.
    local I0 = type(s.info) == 'table' and s.info or nil
    if I0 ~= nil and type(I0.kinds) ~= 'table' then
        local function t(v) return type(v) == 'table' and v or {} end
        local nm, br, ds, fxs = t(I0.name), t(I0.bar), t(I0.dist), t(I0.fx)
        local ev, icons = I0.hide_in_events ~= false, fxs.enabled ~= false
        local function off()
            local function el(e, dx, dy) return { dx = tonumber(e.dx) or dx, dy = tonumber(e.dy) or dy } end
            return { name = el(nm, 0, -66), bar = el(br, 0, -52), dist = el(ds, 56, -52), fx = el(fxs, 0, -98),
                     pct = { dx = tonumber(br.pct_dx) or 0, dy = tonumber(br.pct_dy) or 0 } }
        end
        I0.kinds = {
            mob = { enabled = true, hide_events = ev, name = nm.show ~= false, hp = br.show ~= false and I0.mob_hp ~= false,
                    dist = ds.show ~= false and ds.mob ~= false, icons = icons, abs = false, ax = 0, ay = 0 },
            pc  = { enabled = I0.players ~= false, self = false, hide_events = ev, name = nm.show ~= false, hp = br.show ~= false and I0.player_hp ~= false,
                    dist = ds.show ~= false and ds.pc ~= false, icons = icons, abs = false, ax = 0, ay = 0, off = off() },
            npc = { enabled = I0.npcs ~= false, hide_events = ev, name = nm.show ~= false, hp = br.show ~= false and I0.npc_hp == true,
                    dist = ds.show ~= false and ds.npc ~= false, icons = icons, abs = false, ax = 0, ay = 0, off = off() },
        }
        I0.players, I0.player_hp, I0.npcs, I0.mob_hp, I0.npc_hp = nil, nil, nil, nil, nil
        ds.mob, ds.pc, ds.npc = nil, nil, nil
    end
    local function walk(sec, d, path)
        for k, dv in pairs(d) do
            local v, p = sec[k], path .. k
            local td = type(dv)
            if td == 'table' then
                if type(v) ~= 'table' then
                    sec[k] = deepcopy(dv); fixed[#fixed + 1] = p
                elseif is_color(dv) then
                    for i = 1, 4 do
                        local c = tonumber(v[i])
                        if c == nil or c ~= c then sec[k] = deepcopy(dv); fixed[#fixed + 1] = p; break end
                        if c < 0 then c = 0 elseif c > 1 then c = 1 end
                        v[i] = c
                    end
                else
                    walk(v, dv, p .. '.')
                end
            elseif td == 'number' then
                local n = tonumber(v)
                if n == nil or n ~= n or n == math.huge or n == -math.huge then
                    sec[k] = dv; fixed[#fixed + 1] = p
                else
                    local r = RANGES[p]
                    if r then
                        if r[3] then n = math.floor(n + 0.5) end
                        if n < r[1] then n = r[1] elseif n > r[2] then n = r[2] end
                    end
                    if n ~= v then sec[k] = n; if type(v) ~= 'number' or r then fixed[#fixed + 1] = p end end
                end
            elseif td == 'boolean' then
                if type(v) ~= 'boolean' then
                    local l = type(v) == 'string' and v:lower() or v
                    if l == 'true' or l == 1 then sec[k] = true
                    elseif l == 'false' or l == 0 then sec[k] = false
                    else sec[k] = dv end
                    fixed[#fixed + 1] = p
                end
            elseif td == 'string' then
                local bad = type(v) ~= 'string'
                if not bad and ENUMS[p] and not ENUMS[p][v] then bad = true end
                if not bad and p == 'arrow.style' and not (Draw.STYLE_LABELS[v] or v:sub(1, 4) == 'png:') then bad = true end
                if bad then sec[k] = dv; fixed[#fixed + 1] = p end
            end
        end
    end
    walk(s, defaults, '')
    -- 2.9.2: each job's own copy of the bars over members is checked like the settings themselves
    if type(s.list.over_jobs) == 'table' then
        for k, v in pairs(s.list.over_jobs) do
            if type(k) ~= 'string' or not k:match('^%u%u%u$') or type(v) ~= 'table' then s.list.over_jobs[k] = nil
            else walk(v, defaults.list.over, 'list.over.') end
        end
    end
    if type(s.list.buff_jobs) == 'table' then                       -- 2.10.1
        local SORT_OK = ENUMS['list.buffs.sort']
        for k, v in pairs(s.list.buff_jobs) do
            if type(k) ~= 'string' or not k:match('^%u%u%u$') or type(v) ~= 'table' then s.list.buff_jobs[k] = nil
            else
                if not SORT_OK[v.sort] then v.sort = (v.sort == 'id') and 'type' or 'game' end
                if type(v.pins) ~= 'table' then v.pins = {} end
                if type(v.pin_mode) ~= 'table' then v.pin_mode = {} end
                if type(v.type_hide) ~= 'table' then v.type_hide = {} end
                v.type_order = Buffs.fix_order(v.type_order)
            end
        end
    end
    s.list.buffs.type_order = Buffs.fix_order(s.list.buffs.type_order)
    -- 2.9.1: the action buffer has no options: always on, held up to 0.30 s early, sent 0.25 s after the recast reads ready
    s.buffer.enabled, s.buffer.window, s.buffer.delay, s.buffer.messages = true, 0.30, 0.25, false
    -- 2.6: settings whose options were removed keep one fixed value; a few defaults changed once
    local A = s.arrow
    if not A.cfg260 then
        A.cfg260 = true
        if A.mode == 'auto' then A.mode = 'native' end
        if A.mode_on == 'auto' then A.mode_on = 'native' end
        A.head_height = 2.4
    end
    if A.mode == 'auto' then A.mode = 'native' end
    A.when, A.show_main, A.hide_in_events, A.flip_height, A.png_tint = 'always', true, true, false, true
    A.sheen_min, A.sheen_max = 2, 8
    s.catch_first = true
    local L = s.list
    L.smooth, L.click_select, L.target_on_select, L.select_action, L.debug = true, true, true, 'auto', false
    L.anim.enable, L.anim.slide, L.anim.speed = true, true, 1.15
    if L.win.style == 'custom' then L.win.style = 'line' end
    L.win.curved = true
    if not L.cfg260 then L.cfg260 = true; L.win.rounding = 0; L.gap_ally, L.gap_pet = L.gap, L.gap end
    -- 2.7.0: removed options: no note / chat text, no bar outlines (text and pointer outlines stay), level / check
    -- reuse on and no automatic /check (their defaults), fixed effect flash (every 3-10 s, strength 0.80) and warning
    -- fade (2.5 per second, dimmest 0.45)
    L.ptext.mode = 'off'
    for _, b in ipairs({ 'hp', 'mp', 'tp' }) do L[b].outline_w = 0 end
    s.info.bar.outline_width = 0
    if not L.top271 then L.top271 = true; L.from_bottom = false end     -- 2.7.1: you at the top (once; the option stays)
    s.info.auto_check, s.info.reuse_name = true, true     -- 2.7.1: /check is always sent once per new monster name
    local BF = L.buffs
    BF.flash_min, BF.flash_max, BF.flash_strength = 300, 600, 0.8     -- 2.7.1: every 5-10 minutes
    BF.warn_speed, BF.warn_min = 2.5, 0.45
    -- 2.6.1: the TP number is the full number or nothing; the highlight box fill takes its own color once
    if L.tp.text ~= 'none' then L.tp.text = 'current' end
    if not L.sel.fill261 then
        L.sel.fill261 = true
        local c = L.sel.select
        L.sel.fill = { c[1], c[2], c[3], tonumber(L.sel.tint) or 0.12 }
    end
    -- 2.9.0: the per-kind switches decide what is shown; the elements' own show switches stay on. Leader /
    -- quartermaster flag bits use the defaults (their settings were removed).
    local I = s.info
    I.name.show, I.bar.show, I.dist.show, I.fx.enabled, I.hide_in_events = true, true, true, true, true
    -- 1.0.5: "Docked: only name, health and distance" off becomes the docked card's level, check, defense / evasion,
    -- weaknesses and monster info switches on; the /names switch is gone
    if I.dock_simple ~= nil then
        if I.dock_simple == false then
            I.dock_level, I.dock_check, I.dock_defev, I.dock_weak, I.dock_mob = true, true, true, true, true
        end
        I.dock_simple = nil
    end
    I.names_on, I.names_cfg, I.names_cfg_on = nil, nil, nil
    I.dock_w_on, I.dock_w = nil, nil          -- 1.0.7: the own-width option was taken out again
    -- 1.0.5: the docked card's positions start from the enemies' (the card looks as before until moved)
    if type(I.dock_pos) ~= 'table' then I.dock_pos = {} end
    local DP = I.dock_pos
    for _, k in ipairs(hpp.DOCK_PARTS) do
        local src = (k == 'pct') and { dx = I.bar.pct_dx, dy = I.bar.pct_dy } or I[k]
        if type(DP[k]) ~= 'table' then DP[k] = {} end
        if DP.init ~= true or tonumber(DP[k].dx) == nil then DP[k].dx = tonumber(src and src.dx) or 0 end
        if DP.init ~= true or tonumber(DP[k].dy) == nil then DP[k].dy = tonumber(src and src.dy) or 0 end
        local al = hpp.DOCK_ALIGN[k]          -- 1.0.6: the text parts' justify
        if al ~= nil and not (DP[k].align == 'left' or DP[k].align == 'center' or DP[k].align == 'right') then DP[k].align = al end
    end
    DP.init = true
    for _, K in pairs(I.kinds or {}) do if type(K) == 'table' then K.name_names = nil end end
    local R, RD = L.roles, defaults.list.roles
    R.leader_mask, R.aleader_mask, R.qm_mask = RD.leader_mask, RD.aleader_mask, RD.qm_mask
    if #fixed > 0 then
        table.sort(fixed)
        err('Fixed invalid settings (hand edit?): ' .. table.concat(fixed, ', ') .. '.')
        hpp.schedule_save()
    end
    return fixed
end

---------------------------------------------------------------------------
-- Per frame
---------------------------------------------------------------------------
-- Arrow images are released and re-read at the start of a frame, never while this frame's draw
-- lists still point at them (the config window's button runs after the arrows were queued).
function hpp.reload_arrows()
    local n = hpp.png:reload()
    msg(('Found %d arrow image%s in %s%s'):format(n, n == 1 and '' or 's', hpp.png.dir,
        n > 0 and (': ' .. table.concat(hpp.png.files, ', ')) or ''))
end

local function refresh_scale() hpp.sx, hpp.sy, hpp.scale_ok = Proj.ui_scale(mem) end

local function prepare_view(now, t)
    hpp.cam.capture('present', hpp.fno)
    hpp.cam.update(hpp.fno)
    display_scale(now)
    local e = get_entity()
    if t ~= nil and e ~= nil then learn_up(t, e, t:GetTargetIndex(0) or 0) end
end

-- Pointer trace (/pxi trace): records, frame by frame, what the pointers are doing around every target / sub-target /
-- party-cursor change, and writes it to trace.txt in the addon folder. Meant for finding a pointer that shows in the
-- wrong place for a frame or two.
local TR = { on = false, ring = {}, blocks = {}, cur = nil, tail = 0, key = '', stop = 0, n = 0 }
local TRN = { x = 0, y = 0 }
local function rd8(a) local ok, v = pcall(mem.read_u8, a); return ok and v or -1 end
local function xy(ok) if ok then return ('%.0f,%.0f'):format(TRN.x, TRN.y) end return '-' end
local trace_line_raw
local function trace_line(now)
    local line = trace_line_raw(now)
    local pre = hpp.wins.pre
    pre.early, pre.apply, pre.draw, pre.draws = -1, -1, -1, 0     -- fresh values next frame
    return line
end
trace_line_raw = function (now)
    local st = hpp.st
    local wins = hpp.wins
    local obj, mcd = wins:object('target')
    local fa, fb = -1, -1
    if mcd ~= nil then fa, fb = rd8(mcd + 0x69), rd8(mcd + 0x6A) end
    local nm = xy(obj ~= nil and Proj.native(mem, obj, 'main', hpp.sx, hpp.sy, TRN))
    local ns = xy(obj ~= nil and Proj.native(mem, obj, 'sub', hpp.sx, hpp.sy, TRN))
    local em = xy(st.main ~= 0 and entity_screen(st.main, TRN))
    local es = xy(st.sub ~= 0 and entity_screen(st.sub, TRN))
    local P = PList.PTR
    local pd = (PList.pdraw_t == now) and 'LIST-PTR' or '-'
    -- raw world data for the target: entity position + render flags, and the game's own 3D arrow position
    local wl, gl = '-', '-'
    local e, t = get_entity(), get_target()
    if e ~= nil and st.main ~= 0 then
        wl = ('%.2f,%.2f,%.2f rf=%x'):format(e:GetLocalPositionX(st.main) or 0, e:GetLocalPositionY(st.main) or 0,
            e:GetLocalPositionZ(st.main) or 0, e:GetRenderFlags0(st.main) or 0)
    end
    if t ~= nil then
        local gx, gy, gz = t:GetArrowPositionX(0) or 0, t:GetArrowPositionY(0) or 0, t:GetArrowPositionZ(0) or 0
        local scr = '-'
        if hpp.cam.ok and Proj.project(hpp.cam.v, hpp.cam.p, hpp.cam.vp, gx, gz, gy, TRN) then
            scr = ('%.0f,%.0f'):format(TRN.x * hpp.dsx, TRN.y * hpp.dsy)
        end
        gl = ('%.2f,%.2f,%.2f on=%s scr=%s'):format(gx, gy, gz, tostring(t:GetIsArrowActive(0)), scr)
    end
    local drawn = hpp.src.main ~= 'none' and ('%.0f,%.0f'):format(hpp.drawn_x or 0, hpp.drawn_y or 0) or '-'
    return ('f%d t=%.3f main=%d sub=%d slot=%d | win target flags=%d/%d hidden=%s | native main=%s sub=%s | entity main=%s sub=%s | arrows main=%s sub=%s settle=%d/%d | list ptr %s on=%s at=%.0f,%.0f slot=%s cn=%s | target flag before our write: beginscene %d, present %d, draw %d (%d draw calls) | cam %s | drawn main=%s | world main=%s | game arrow %s'):format(
        hpp.fno, now, st.main, st.sub, st.slot, fa, fb, tostring(wins.hidden.target == true), nm, ns, em, es,
        hpp.src.main, hpp.src.sub, SETTLE.main.n, SETTLE.sub.n, pd, tostring(P.on), P.x or 0, P.y or 0, tostring(P.cs), tostring(P.cn),
        wins.pre.early, wins.pre.apply, wins.pre.draw, wins.pre.draws,
        hpp.cam.ok and (tostring(hpp.cam.src) .. ' age ' .. (hpp.fno - (hpp.cam.good_f or 0))) or 'none', drawn, wl, gl)
end
local function trace_write()
    local lines = { 'PartyramaXI ' .. addon.version .. ' pointer trace; ' .. #TR.blocks .. ' events',
        'arrow mode: ' .. tostring(hpp.s.arrow.mode) .. ', list pointer: ' .. tostring(hpp.s.list.pointer.show) .. ', hide target window: ' .. tostring(hpp.s.windows.target) .. ', camera: ' .. tostring(hpp.cam.why), '' }
    for i, b in ipairs(TR.blocks) do
        lines[#lines + 1] = ('=== event %d (change of target / sub-target / cursor) ==='):format(i)
        for _, l in ipairs(b) do lines[#lines + 1] = l end
        lines[#lines + 1] = ''
    end
    local ok, f = pcall(io.open, addon.path .. 'trace.txt', 'w')
    if ok and f then f:write(table.concat(lines, '\n')); f:close(); return addon.path .. 'trace.txt' end
    return nil
end
function hpp.trace_toggle()
    if TR.on then
        TR.on = false
        local p = trace_write()
        msg(p and ('Trace written to ' .. p .. ' (' .. #TR.blocks .. ' events). Send me that file.') or 'Could not write trace.txt.')
        return
    end
    TR.on, TR.ring, TR.blocks, TR.cur, TR.tail, TR.key, TR.stop = true, {}, {}, nil, 0, '', hpp.clock() + 180
    msg('Pointer trace on for 3 minutes: change targets, tab through enemies, use the party cursor. /pxi trace again stops it and writes trace.txt.')
end
function hpp.trace_frame(now)
    if not TR.on then return end
    local line = trace_line(now)
    local st = hpp.st
    local key = st.main .. ',' .. st.sub .. ',' .. st.slot
    if key ~= TR.key and TR.key ~= '' and #TR.blocks < 40 then
        local b = {}
        for _, l in ipairs(TR.ring) do b[#b + 1] = l end
        TR.cur, TR.tail = b, 70
        TR.blocks[#TR.blocks + 1] = b
    end
    TR.key = key
    if TR.tail > 0 and TR.cur then TR.cur[#TR.cur + 1] = line; TR.tail = TR.tail - 1 end
    TR.ring[#TR.ring + 1] = line
    if #TR.ring > 15 then table.remove(TR.ring, 1) end
    if now > TR.stop or #TR.blocks >= 40 and TR.tail == 0 then hpp.trace_toggle() end
end

function hpp.frame()
    local now = hpp.clock()
    hpp.now = now
    hpp.fno = (hpp.fno or 0) + 1
    Draw.hl_begin(now)
    Draw.obst_swap()
    if hpp.save_at ~= nil and now >= hpp.save_at then hpp.flush_save() end
    guard('list keys', PList.pump, now)

    if hpp.zoning and now - hpp.zoning_at > ZONE_TIMEOUT then
        hpp.zoning, hpp.zone_ready_at = false, now + 1.0
    end
    if hpp.reload_pending then hpp.reload_pending = false; guard('arrow reload', hpp.reload_arrows) end
    if hpp.fx_rescan then hpp.fx_rescan = false; guard('effect icons', hpp.fx_sync, true)
    elseif hpp.s.info.enabled or (hpp.s.list.enabled and hpp.s.list.buffs.show) or hpp.list_test then guard('effect icons', hpp.fx_sync) end
    if Buffer.held ~= nil then hpp.buf_api.now = now; guard('action buffer', Buffer.tick, hpp.s.buffer, hpp.buf_api) end
    if now - hpp.probe_at >= 0.2 then hpp.probe_at = now; guard('state probe', probe_state); if not hpp.zoning then guard('death', probe_dead); guard('party timers', hpp.timers_tick, now) end end

    local t = get_target()
    -- Nothing is written to the game's window objects while zoning: they are being torn down.
    if not hpp.zoning then
        local has_target = t ~= nil and (t:GetTargetIndex(0) or 0) ~= 0
        local fight = guard('window hiding', hpp.wins.apply, hpp.wins, hpp.want, has_target, hpp.ui_hidden or hpp.in_event)
        guard('first-frame catch', hpp.update_catch)
        if fight ~= nil then
            err(('Something else keeps changing the %s. Is the original hideparty addon loaded too? '
                .. 'Unload it with /addon unload hideparty.'):format(Win.LABELS[fight]:lower()))
        end
    end

    local preview = now < hpp.preview_until or hpp.preview_hold == true
    if not hpp.zoning and now >= hpp.zone_ready_at then
        if hpp.rescale then hpp.rescale = false; guard('ui scale', refresh_scale) end
        guard('target', hpp.targets.resolve, hpp.targets, hpp.st)
        local need_arrows = hpp.arrows_wanted()
        local over = hpp.s.list.over
        if need_arrows or preview or hpp.s.list.enabled or hpp.s.info.enabled or over.enabled then guard('camera', prepare_view, now, t) end
        if need_arrows then guard('arrows', hpp.draw_arrows, now) end
        if hpp.s.info.enabled or hpp.s.list.enabled or hpp.list_test then guard('fonts', Fonts.update, hpp.s.info) end
        if hpp.s.info.enabled then guard('enemy info', hpp.draw_info, now); guard('auto check', hpp.auto_check, now) end
        if over.enabled and not (hpp.ui_hidden or hpp.in_event) and (hpp.list_test or hpp.party_in_battle(now)) then guard('health bars over members', hpp.draw_over, now) end
        if preview then guard('preview', hpp.draw_preview, now) end
        Fonts.unwind()      -- a draw error must not leave a font pushed
        if ui and ui.style_remove then pcall(ui.style_remove) end   -- 1.0.1: nor the settings window's widget styling
        PList.box_ok = false
        if hpp.s.list.enabled or preview or hpp.list_test then
            guard('party list', hpp.draw_list, now, hpp.list_test == true or (preview and PData.count_real() < 2), hpp.list_test_anim == true)
            guard('effect icons', Buffs.after, now)
        end
    end
    Rx.attach_box = PList.box_ok and PList.BOX or nil
    -- 2.12.0: the list's box for next frame's dock; RecastXI sits above the docked target bar
    if PList.box_ok then
        local L, B = DOCK.list or {}, PList.BOX
        L[1], L[2], L[3], L[4] = B.x0, B.y0, B.x1, B.y1
        DOCK.list = L
        -- 2.12.6: RecastXI moves up only when the docked card does not fit in its gap with DOCK_M px to spare;
        -- then its bottom sits DOCK_M px above the card
        local want = 0
        if DOCK.on and hpp.s.info.enabled then
            local rs = Rx.settings and Rx.settings() or nil
            local gap = rs and tonumber(rs.attach_gap) or 20
            want = math.max(0, B.y0 - DOCK.box[2] + DOCK_M - gap)
        end
        local lift = dock_slide(want, now)
        if lift > 0.5 then
            local S = DOCK.rxbox or {}
            S.x0, S.x1, S.y1, S.y0 = B.x0, B.x1, B.y1, B.y0 - lift
            DOCK.rxbox = S
            Rx.attach_box = S
        end
    else
        DOCK.list = nil
        local S = DOCK.slide
        S.from, S.to, S.cur = 0, 0, 0
    end
    if not hpp.rx_broken then
        local ok, e = pcall(Rx.present)
        if not ok then
            pcall(Rx.recover)
            hpp.rx_broken = true; err('The RecastXI module hit an error and was turned off until the addon is reloaded: ' .. tostring(e))
        end
    end
    if TR.on then guard('trace', hpp.trace_frame, now) end
    if Draw.HLR.n > 0 then guard('highlight', Draw.hl_draw, imgui.GetForegroundDrawList(), now) end
    if ui.is_open() and hpp.s.info.enabled and not hpp.zoning then guard('target bar spots', hpp.draw_abs, now) end
    guard('bars per job', hpp.over_job_sync, now)
    if Mob.pending() then guard('monster card', hpp.draw_card) end
    guard('settings window', ui.draw, hpp)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local WINDOW_ALIAS = {
    party = 'party', p = 'party', party0 = 'party',
    alliance1 = 'alliance1', a1 = 'alliance1', party1 = 'alliance1',
    alliance2 = 'alliance2', a2 = 'alliance2', party2 = 'alliance2',
    target = 'target', t = 'target',
    castinfo = 'castinfo', cast = 'castinfo', ci = 'castinfo',
}

local HELP = {
    { '/pxi', 'Toggle hiding the ticked windows on or off.' },
    { '/pxi hide | show', 'Hide / show the ticked windows (same as /hideparty hide | show).' },
    { '/pxi hide | show <party|alliance1|alliance2|target|castinfo|all>', 'Choose which windows get hidden.' },
    { '/pxi config', 'Open the settings window.' },
    { '/pxi trace', 'Record what the pointers do around target changes into trace.txt (run again to stop and save).' },
    { '/pxi arrow <auto|entity|native|off>', 'Where custom arrows get their position from.' },
    { '/pxi arrow when <hidden|always>', 'Draw custom arrows only while the target window is hidden, or always.' },
    { '/pxi arrow style <triangle|chevron|crystal>', 'Arrow shape.' },
    { '/pxi enemy [on|off]', 'Enemy info (name, health, level, check) next to the pointer.' },
    { '/pxi fx [on|off]', 'Status effects (icons and countdown) on the target.' },
    { '/pxi fx packs', 'Rescan icons\\packs and icons\\status and list what was found.' },
    { '/pxi fx pack|fallback <folder|none>', 'Choose the icon pack or the fallback pack by typing its folder name.' },
    { '/pxi checkdebug', 'Print what the check reply packets contain (for when a level or check does not show).' },
    { '/pxi list [on|off]', 'Party list with bars, job, current action and status effects.' },
    { '/pxi list next | prev | clear', 'Cycle the selected member (bind keys to these); selecting also targets them.' },
    { '/pxi list invite', 'Show a test party invite (banner, then the "!" badge).' },
    { '/pxi list leader|aleader|qm <name>', 'Mark a member by hand when the game flags are not read right (no name clears). /pxi list flags prints the raw flags.' },
    { '/pxi list theme [name]', 'List the party list themes or switch to one.' },
    { '/pxi recast [on|off|attach|detach|test|help]', 'The recast tracker (RecastXI built in). /pxi recast help lists all its commands (pin, theme, safe, debug...).' },
    { '/pxi test', 'Show sample arrows and the party list for 5 seconds.' },
    { '/pxi info', 'Show what was found and what is being drawn.' },
    { '/pxi alias <on|off>', 'Also answer /hideparty (only if the original hideparty is not loaded).' },
    { '/pxi reset', 'Reset this character\'s settings.' },
}

local function help()
    for _, v in ipairs(HELP) do
        print(chat.header(addon.name):append(chat.message(v[1])):append(' - '):append(chat.color1(6, v[2])))
    end
end

function hpp.info()
    local w = hpp.wins
    local parts = {}
    for i = 1, #Win.NAMES do
        local n = Win.NAMES[i]
        local state
        if not w:available(n) then state = 'not found'
        elseif w.hidden[n] then state = 'hidden'
        else local sh = w:shown(n); state = sh == nil and 'not loaded' or (sh and 'shown' or 'not drawn') end
        parts[#parts + 1] = ('%s: %s'):format(n, state)
    end
    msg('Windows - ' .. table.concat(parts, ', ') .. (hpp.s.enabled and '' or ' (hiding is off)'))
    if #w.errors > 0 then err('Not found: ' .. table.concat(w.errors, '; ')) end
    local st = hpp.st
    msg(('Target %d, sub-target %d%s; party cursor slot %s'):format(st.main, st.sub,
        st.sub_active and ' (choosing)' or '', st.slot >= 0 and tostring(st.slot) or 'none'))
    msg(('Arrows: %s, mode %s, drawn from: main %s, sub %s. Camera: %s. Up %s%s. UI scale %.2f x %.2f%s.'):format(
        hpp.arrows_wanted() and 'on' or 'off', hpp.s.arrow.mode, hpp.src.main, hpp.src.sub, hpp.cam.why,
        hpp.up_sign < 0 and '-' or '+', hpp.up_learned and ' (learned)' or ' (default)',
        hpp.sx, hpp.sy, hpp.scale_ok and '' or ' (not found, using 1)'))
    msg('Clock: ' .. hpp.clock_name .. (party_base == 0 and '. Party cursor pointer not found.' or '.'))
end

local function set_window(name, hide)
    local s = hpp.s
    if name == 'all' then
        for i = 1, #Win.NAMES do s.windows[Win.NAMES[i]] = hide end
        msg(('All windows will be %s.'):format(hide and 'hidden' or 'shown'))
    else
        local n = WINDOW_ALIAS[name]
        if n == nil then err('Unknown window: ' .. tostring(name) .. ' (party, alliance1, alliance2, target, castinfo, all)'); return end
        s.windows[n] = hide
        msg(('%s will be %s.'):format(Win.LABELS[n], hide and 'hidden' or 'shown'))
    end
    if hide and not s.enabled then msg('Hiding is off right now; /pxi hide turns it on.') end
    hpp.changed()
end

function hpp.command(args)
    local s = hpp.s
    local a1, a2, a3 = (args[2] or ''):lower(), (args[3] or ''):lower(), (args[4] or ''):lower()
    if a1 == '' or a1 == 'toggle' then
        s.enabled = not s.enabled; hpp.changed()
        msg(s.enabled and 'Hiding the ticked windows.' or 'Showing all windows.')
    elseif a1 == 'hide' or a1 == 'h' or a1 == 'show' or a1 == 's' then
        local hide = (a1 == 'hide' or a1 == 'h')
        if a2 ~= '' then set_window(a2, hide); return end
        s.enabled = hide; hpp.changed()
    elseif a1 == 'help' then help()
    elseif a1 == 'config' or a1 == 'cfg' or a1 == 'c' or a1 == 'settings' then ui.toggle()
    elseif a1 == 'trace' then hpp.trace_toggle()
    elseif a1 == 'recast' or a1 == 'recasts' or a1 == 'rx' then
        local ra = { '/pxi recast' }
        for i = 3, #args do ra[#ra + 1] = args[i] end
        Rx.command(ra)
    elseif a1 == 'info' then hpp.info()
    elseif a1 == 'test' or a1 == 'preview' then
        hpp.preview_until = hpp.clock() + 5
        msg('Showing sample arrows and the party list for 5 seconds. One should sit over your character.')
    elseif a1 == 'enemy' then
        if a2 == 'on' or a2 == 'off' then s.info.enabled = (a2 == 'on') else s.info.enabled = not s.info.enabled end
        hpp.changed(); msg('Enemy info ' .. (s.info.enabled and 'on. /check a monster to fill in its level and difficulty.' or 'off.'))
    elseif a1 == 'fx' or a1 == 'effects' then
        local F = s.info.fx
        if a2 == 'packs' or a2 == 'scan' then
            hpp.fx_rescan = true
            hpp.fx_report = true       -- printed after the next scan
            return
        end
        if (a2 == 'pack' or a2 == 'pack2' or a2 == 'fallback') then
            local k = (a2 == 'pack') and 'pack' or 'pack2'
            F[k] = (table.concat(args, ' ', 3 + 1)):gsub('^["\']', ''):gsub('["\']$', '')
            if a3 == 'none' or a3 == 'off' then F[k] = '' end
            hpp.changed(); msg(('Effect icon %s: %s'):format(k == 'pack' and 'pack' or 'fallback', F[k] == '' and '(none)' or F[k])); return
        end
        if a2 == 'on' or a2 == 'off' then F.enabled = (a2 == 'on') else F.enabled = not F.enabled end
        hpp.changed(); msg('Target effects ' .. (F.enabled and 'on. They are learned from spells you can see; icons go in addons\\partyramaxi\\icons\\.' or 'off.'))
    elseif a1 == 'buffs' or a1 == 'buff' then
        -- the retail-style cursor on your own effects: /pxi buffs [next|prev|ok|back], or /pxi buffs timers (debug)
        if a2 == 'timers' then hpp.dump_self_timers(); return end
        if a2 == 'pad' then Input.debug = not Input.debug; msg('Key and controller button lines ' .. (Input.debug and 'on: press keys / buttons and read the ids.' or 'off.')); return end
        -- 2.9.1: /pxi buffs again (the open key) = pick / confirm cancel
        if not Buffs.command(a2 == '' and (Buffs.cur.on and 'ok' or 'next') or a2, hpp.clock()) and a2 ~= 'back' then msg('You have no effects to pick from.') end
    elseif a1 == 'checkdebug' then
        hpp.check_dbg = not hpp.check_dbg
        msg('Check debug ' .. (hpp.check_dbg and 'on: /check a monster and read the lines.' or 'off.'))
    elseif a1 == 'list' and (a2 == 'invite' or a2 == 'leader' or a2 == 'qm' or a2 == 'aleader' or a2 == 'flags') then
        if a2 == 'invite' then PList.test_invite(hpp.clock()); msg('Test invite started.')
        elseif a2 == 'flags' then
            local any = false
            for i = 1, 18 do
                local r = PData.m[i]
                if r.active then any = true; msg(('%s: flags 0x%04X%s%s%s'):format(r.name, r.flags or 0, r.leader and ' leader' or '', r.aleader and ' alliance-leader' or '', r.qm and ' quartermaster' or '')) end
            end
            if not any then msg('No members to show.') end
        else
            PData.set_role(a2, a3); msg(a2 .. ' marker ' .. (a3 == '' and 'cleared.' or ('set to ' .. a3 .. '.')))
        end
    elseif a1 == 'list' and a2 == 'debug' then
        s.list.debug = not s.list.debug; msg('Party list debug messages ' .. (s.list.debug and 'on.' or 'off.'))
    elseif a1 == 'list' and (a2 == 'next' or a2 == 'prev' or a2 == 'previous' or a2 == 'clear' or a2 == 'reload' or a2 == 'theme') then
        if a2 == 'next' then if not PList.cycle(1) then msg('The party list is not showing anyone.') end
        elseif a2 == 'prev' or a2 == 'previous' then if not PList.cycle(-1) then msg('The party list is not showing anyone.') end
        elseif a2 == 'clear' then PList.clear()
        elseif a2 == 'reload' then
            if PList.png_bg then PList.png_bg:reload() end
            if PList.png_job then PList.png_job:reload() end
            msg('Party list images re-read: ' .. #(PList.png_bg and PList.png_bg.files or {}) .. ' backgrounds, ' .. #(PList.png_job and PList.png_job.files or {}) .. ' job icons.')
        else
            local want = table.concat(args, ' ', 4)
            if want == '' then msg('Themes: ' .. table.concat(PTheme.NAMES, ', ') .. '. Current: ' .. s.list.theme .. '.')
            else
                local found
                for _, nm in ipairs(PTheme.NAMES) do if nm:lower():gsub('[^%w]', '') == want:lower():gsub('[^%w]', '') then found = nm end end
                if found then PTheme.apply(s.list, found); hpp.changed(); msg('Party list theme: ' .. found .. '.')
                else err('No theme called "' .. want .. '". /pxi list theme shows them.') end
            end
        end
    elseif a1 == 'list' then
        if a2 == 'on' or a2 == 'off' then s.list.enabled = (a2 == 'on') else s.list.enabled = not s.list.enabled end
        if s.list.enabled then PList.broken = false end
        hpp.changed(); msg('Party list ' .. (s.list.enabled and 'on.' or 'off.'))
    elseif (a1 == 'arrow' or a1 == 'arrows') and a2 ~= 'reload' then
        if a2 == 'auto' or a2 == 'entity' or a2 == 'native' or a2 == 'off' then
            s.arrow.mode = a2
        elseif a2 == 'when' and (a3 == 'hidden' or a3 == 'always') then
            s.arrow.when = a3
        elseif a2 == 'style' and Draw.STYLE_LABELS[a3] then
            s.arrow.style = a3
        elseif a2 == 'style' and a3 ~= '' and hpp.find_png(args[4]) then
            s.arrow.style = Png.style_of(hpp.find_png(args[4]))
        elseif a2 == 'rotate' and (a3 == '0' or a3 == '90' or a3 == '180' or a3 == '270') then
            s.arrow.png_rotation = tonumber(a3)
        elseif a2 == 'size' and tonumber(a3) then
            s.arrow.size = math.max(6, math.min(64, tonumber(a3)))
        elseif a2 ~= '' then
            err('Usage: /pxi arrow <auto|entity|native|off> | when <hidden|always> | style <triangle|chevron|crystal|file.png> | size <n> | rotate <0|90|180|270>'); return
        end
        hpp.changed()
        msg(('Arrows: mode %s, drawn %s, style %s, size %d.'):format(s.arrow.mode,
            s.arrow.when == 'always' and 'always' or 'while the target window is hidden', s.arrow.style, s.arrow.size))
    elseif a1 == 'arrows' and a2 == 'reload' or a1 == 'pngs' then
        hpp.reload_pending = true      -- done at the start of the next frame (see hpp.frame)
    elseif a1 == 'alias' then
        if a2 == 'on' or a2 == 'off' then s.alias_hideparty = (a2 == 'on') else s.alias_hideparty = not s.alias_hideparty end
        hpp.changed()
        msg('/hideparty alias ' .. (s.alias_hideparty and 'on. Don\'t load the original hideparty at the same time.' or 'off.'))
    elseif a1 == 'reset' then
        -- 2.13.3: everything, RecastXI's own settings too; the positions are fitted to the screen again
        settings.reset(); hpp.rebuild(); hpp.layout_done = false
        if hpp.rx and hpp.rx.reset then pcall(hpp.rx.reset) end
        msg('Settings reset for this character.')  -- reset raises the settings event, which swaps hpp.s
    else
        err('Unknown command. /pxi help lists them.')
    end
end

-- Match a PNG in the arrows folder by name (any case, with or without .png / png: prefix).
function hpp.find_png(name)
    if type(name) ~= 'string' or name == '' then return nil end
    name = name:gsub('^[Pp][Nn][Gg]:', ''):lower()
    for _, f in ipairs(hpp.png.files) do
        local l = f:lower()
        if l == name or l == name .. '.png' then return f end
    end
    return nil
end

local function split(text)
    local out = {}
    for w in text:gmatch('%S+') do out[#out + 1] = w end
    return out
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- 1.0.0: the addon's working names were "hidepartyplus" and "listoramaxi". The saved settings of the newer one found
-- (config\addons\<old name>\<character>\) are copied once, the first time this name has no settings folder, and its data files (party effect timers, check
-- results) when this data folder lacks them, so nothing is lost by the rename.
local function copy_file(a, b)
    local f = io.open(a, 'rb')
    if f == nil then return false end
    local d = f:read('*a'); f:close()
    local o = io.open(b, 'wb')
    if o == nil then return false end
    o:write(d); o:close()
    return true
end
function hpp.migrate_old()
    local fs = ashita and ashita.fs
    if fs == nil or fs.get_directory == nil or fs.exists == nil then return 0 end
    local install = (AshitaCore:GetInstallPath() or ''):gsub('[\\/]+$', '')
    local n = 0
    local function folder(old, new, keep)
        local ok, files = pcall(fs.get_directory, old, '.*', false)
        if not ok or type(files) ~= 'table' then return end
        for _, f in pairs(files) do
            local name = type(f) == 'string' and f:gsub('^.*[\\/]', '') or ''
            if name ~= '' and keep(name:lower()) and not fs.exists(new .. '\\' .. name) then
                if not fs.exists(new) and fs.create_dir then pcall(fs.create_dir, new) end
                if copy_file(old .. '\\' .. name, new .. '\\' .. name) then n = n + 1 end
            end
        end
    end
    local function lua(l) return l:match('%.lua$') ~= nil end
    local OLD = { 'listoramaxi', 'hidepartyplus' }
    local cnew, cold = install .. '\\config\\addons\\' .. addon.name, nil
    for _, o in ipairs(OLD) do
        local c = install .. '\\config\\addons\\' .. o
        if cold == nil and fs.exists(c) then cold = c end
    end
    if cold ~= nil and not fs.exists(cnew) then
        folder(cold, cnew, lua)
        local ok, dirs = pcall(fs.get_dir or function () return nil end, cold)
        if ok and type(dirs) == 'table' then
            for _, d in pairs(dirs) do
                if type(d) == 'string' and d ~= '' then
                    d = d:gsub('^.*[\\/]', '')
                    folder(cold .. '\\' .. d, cnew .. '\\' .. d, lua)
                end
            end
        end
    end
    local base = ((rawget(_G, 'addon') and addon.path) or ''):gsub('[\\/]+$', '')
    for _, o in ipairs(OLD) do
        folder(install .. '\\addons\\' .. o .. '\\data', base .. '\\data', function (l) return l:match('%.txt$') ~= nil and l ~= 'readme.txt' end)
    end
    if n > 0 then msg(('Copied %d saved settings and data files over from the old addon folders.'):format(n)) end
    return n
end

ashita.events.register('load', 'partyramaxi_load', function ()
    pcall(hpp.migrate_old)
    hpp.s = settings.load(defaults)
    hpp.sanitize(hpp.s)
    hpp.rebuild()
    ui.init(hpp)
    if not hpp.wins:scan() then
        err('Could not find: ' .. table.concat(hpp.wins.errors, '; ') .. '. Those windows will be left alone.')
    end
    hpp.sx, hpp.sy, hpp.scale_ok = Proj.ui_scale(mem)
    hpp.png:scan()
    pcall(hpp.old_folders)
    PData.init({ party = get_party, player = function () return mm:GetPlayer() end, res = function () return AshitaCore:GetResourceManager() end, entity = function () return mm:GetEntity() end })
    PList.init(hpp)
    Buffs.init(hpp)
    do
        local base = ((rawget(_G, 'addon') and addon.path) or ''):gsub('[\\/]+$', '')
        PList.png_bg = Png.new(png_backend, base .. '\\backgrounds\\')
        PList.png_job = Png.new(png_backend, base .. '\\icons\\jobs\\')
        PList.png_bg:scan(); PList.png_job:scan()
    end
    local pf = Png.file_of(hpp.s.arrow.style)
    if pf ~= nil and not hpp.png:has(pf) then
        err(('Arrow image %s is not in the arrows folder; using the triangle until it is.'):format(pf))
    end
    if hpp.s.alias_hideparty then
        msg('/hideparty is handled by PartyramaXI. Don\'t load the original hideparty at the same time.')
    end
    do
        local ok, e = pcall(Rx.load, ((rawget(_G, 'addon') and addon.path) or ''))
        if not ok then hpp.rx_broken = true; err('The RecastXI module failed to start and is off: ' .. tostring(e)) end
    end
    Rx.list_panel = PList.panel
    PList.rx_panel = (not hpp.rx_broken) and Rx.theme_panel or nil     -- 2.13.1: the list can wear RecastXI's theme frame
    hpp.rx = Rx
    Rx.open_ui = function (sub) ui.open_tab('recast', sub) end
    settings.register('settings', 'partyramaxi_settings_update', function (s)
        if s ~= nil then hpp.s = s; hpp.sanitize(s); hpp.rebuild() end
    end)
    hpp.loaded = true
end)

ashita.events.register('unload', 'partyramaxi_unload', function ()
    if hpp.catch_events then pcall(hpp.catch_events, false) end
    pcall(hpp.timers_save)
    pcall(settings.save)
    pcall(hpp.flush_save)
    pcall(hpp.wins.restore, hpp.wins)       -- show everything we hid, whatever else fails
    pcall(Rx.unload)
    pcall(hpp.png.release_all, hpp.png)
    if PList.png_bg then pcall(PList.png_bg.release_all, PList.png_bg) end
    if PList.png_job then pcall(PList.png_job.release_all, PList.png_job) end
    pcall(hpp.fx_root_png.release_all, hpp.fx_root_png)
    for _, p in ipairs(hpp.fx_pack_pngs) do pcall(p.release_all, p) end
    pcall(Weak.png_elem.release_all, Weak.png_elem)
    for _, set in ipairs({ hpp.png_weak, hpp.png_mob, hpp.png_elem }) do
        for _, p in pairs(set) do pcall(p.release_all, p) end
    end
end)

-- Action buffer (pxibuffer.lua): what it needs from the game, built once.
local BUF_OUT = {}
hpp.buf_api = {
    res = function () return AshitaCore:GetResourceManager() end,
    recast = function () return mm:GetRecast() end,
    entity = function () return mm:GetEntity() end,
    target = function () local o = hpp.targets:resolve(BUF_OUT); return o.held ~= 0 and o.held or o.main end,
    units = require('pxirxdata').units,
    now = 0,
    msg = function (t) msg(t) end,
    send = function (c) AshitaCore:GetChatManager():QueueCommand(1, c) end,
    packet = function (b) AshitaCore:GetPacketManager():AddOutgoingPacket(0x1A, b) end,
    party_index = function (slot) local p = mm:GetParty(); return p and p:GetMemberTargetIndex(slot) or nil end,
    party_sid = function (slot) local p = mm:GetParty(); return p and p:GetMemberServerId(slot) or nil end,
    party_sid_of = function (idx)
        local p = mm:GetParty()
        if p == nil then return nil end
        for k = 0, 17 do if p:GetMemberTargetIndex(k) == idx then return p:GetMemberServerId(k) end end
        return nil
    end,
    cursor = function () local o = hpp.targets:resolve(BUF_OUT); return (o.sub ~= 0 and o.sub) or (o.held ~= 0 and o.held) or o.main end,
    index_of_sid = function (sid)
        local p = mm:GetParty()
        if p == nil then return nil end
        for k = 0, 17 do if p:GetMemberServerId(k) == sid then local i = p:GetMemberTargetIndex(k); return (i or 0) ~= 0 and i or nil end end
        return nil
    end,
}

-- Keyboard and controller for the effect cursor (pxiinput.lua)
Input.init(hpp, Buffs)
Input.on_escape = function (now) PList.escape(now) end
hpp.input = Input
ashita.events.register('key', 'partyramaxi_key', function (e) pcall(Input.key, e) end)
ashita.events.register('key_data', 'partyramaxi_keydata', function (e) pcall(Input.key_data, e) end)
ashita.events.register('xinput_button', 'partyramaxi_xbutton', function (e)
    local ok, block = pcall(Input.button, 'x', e.button, (tonumber(e.state) or 0) ~= 0)
    if ok and block then e.blocked = true end
end)
ashita.events.register('dinput_button', 'partyramaxi_dbutton', function (e)
    local ok, block = pcall(Input.button, 'd', e.button, (tonumber(e.state) or 0) ~= 0)
    if ok and block then e.blocked = true end
end)

ashita.events.register('command', 'partyramaxi_command', function (e)
    if hpp.s and hpp.s.buffer and not e.blocked then
        hpp.buf_api.now = hpp.clock()
        local ok, held = pcall(Buffer.command, hpp.s.buffer, hpp.buf_api, e.command)
        if ok and held then e.blocked = true; return end
    end
    local args = split(e.command)
    local c = (args[1] or ''):lower()
    -- remember a command that opens the game's target cursor (<st>, <stpc>, <stnpc>, <stpt>, <stal>): the party list
    -- can finish it for you when you select a member (see pxilist.lua)
    if hpp.s and hpp.s.list.enabled and hpp.s.list.select_action == 'auto' and c:sub(1, 1) == '/' and c ~= '/pxi' and c ~= '/partyramaxi' and c ~= '/hpp' and e.command:find('<st', 1, true)
        and e.command:find('<st%a*>') then
        hpp.pending = { cmd = e.command, at = hpp.clock() }
    end
    -- 2.13.2: a /check of yours (not one the target bar queued) shows its reply in the chat log as usual
    -- 1.0.2: Ashita marks commands sent by addons as injected. A typed /check is the only one not injected, so another
    -- addon's /check (or an old copy of this one still loaded) no longer counts as yours and shows its reply.
    if c == '/check' or c == '/c' then
        local inj = e.injected
        if hpp.check_dbg then msg(('Check debug: command "%s", injected %s, mode %s'):format(tostring(e.command), tostring(inj), tostring(e.mode))) end
        if (hpp.ac_queued or 0) > 0 and e.command:lower() == '/check <t>' then hpp.ac_queued = hpp.ac_queued - 1
        elseif inj ~= true then hpp.user_check_at = hpp.clock() end
    end
    if c == '/pxi' or c == '/partyramaxi' or c == '/hpp' then
        e.blocked = true
        hpp.command(args)
    elseif c == '/hideparty' and hpp.s and hpp.s.alias_hideparty then
        e.blocked = true
        hpp.command(args)
    end
end)

ashita.events.register('packet_in', 'partyramaxi_packet_in', function (e)
    if e.id == 0x000B then
        hpp.zoning = true
        hpp.zoning_at = hpp.clock()
    elseif e.id == 0x000A then
        hpp.zoning = false
        hpp.rescale = true            -- menu / window resolution may have changed
        hpp.zone_ready_at = hpp.clock() + 1.0
        hpp.up_learned = false
        local keep = hpp.timers and select(2, pcall(hpp.timers.snapshot, Fx, Buffs, PData, hpp.clock())) or nil   -- party timers survive the zone
        Fx.reset(); PData.reset(); Info.checks, Info.tried, Info.trail = {}, {}, {}
        if type(keep) == 'table' then pcall(hpp.timers.restore, keep, Fx, Buffs, hpp.clock()) end
        for k in pairs(ANCH) do ANCH[k] = nil end
        hpp.alive, hpp.dying, hpp.prev_main, hpp.ghost, hpp.focus = {}, {}, 0, 0, 0      -- entity indexes mean something else in the next zone
    end
end)

-- 1.0.4: true when a check reply for this monster answers one of the automatic checks (not a /check you typed):
-- its packet and, should a line still reach the chat, that line are kept out of the log.
function hpp.auto_reply(idx, now)
    local t = Info.tried[get_entity():GetServerId(idx) or 0]
    return type(t) == 'table' and t.n > 0 and now - t.t < 12 and now - (hpp.user_check_at or -100) > 3
end

-- Packet readers. Named functions (not closures made per packet): these run for every packet of the type.
local PBYTES
local function u16(o) return PBYTES[o] + PBYTES[o + 1] * 256 end

-- Check replies: packet 0x0029 (layout: +0x0C param1, +0x10 param2, +0x16 target index, +0x18 message).
local function read_check(e)
    local tidx, msgid = u16(0x16), u16(0x18) % 0x8000
    local p1, p2 = u16(0x0C) + u16(0x0E) * 65536, u16(0x10) + u16(0x12) * 65536
    if tidx == 0 then tidx = hpp.st.main end
    if hpp.check_dbg and (tidx == hpp.st.main or tidx == hpp.st.sub or (msgid >= 0x40 and msgid <= 0x47)) then
        msg(('Check debug: packet 0x0029 message %d (0x%X), param1 %d, param2 %d, target index %d'):format(msgid, msgid, p1, p2, tidx))
    end
    local level, diff, eva, def = Info.classify(msgid, p1, p2)
    if (diff == nil and eva == nil) or not is_monster(tidx) then return end
    local name = get_entity():GetName(tidx)
    local now = hpp.clock()
    Info.set(tidx, name, level, nil, nil, diff, now, eva, def)
    -- 2.13.2: the reply to an automatic /check stays out of the chat log; one you typed yourself still shows
    if hpp.auto_reply(tidx, now) then e.blocked = true end
    if hpp.check_dbg then
        local sid = get_entity():GetServerId(tidx) or 0
        local t = Info.tried[sid]
        msg(('Check debug: reply for %s: level %s, %s%s'):format(tostring(name), tostring(level), diff and Info.DIFF[diff].full or 'no difficulty',
            type(t) == 'table' and (' (after try ' .. t.n .. ')') or ' (your own /check)'))
    end
end

-- Status effects: wear-off / defeated messages (0x0029) and finished spells (0x0028).
local function read_fx_message()
    Fx.on_message(u16(0x08) + u16(0x0A) * 65536, u16(0x0C) + u16(0x0E) * 65536, u16(0x18) % 0x8000)
end

local FX_CATS = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [11] = true, [13] = true, [14] = true, [15] = true }
local function read_fx_action(e)
    local bits = ashita.bits.unpack_be
    local d = e.data_raw
    -- 2.7.3: 4 = a spell finished; also melee (1), ranged (2), weapon skills (3), abilities (6), monster / pet moves
    -- (11, 13, 14, 15) for their status messages and "Additional effect" statuses
    local cat = bits(d, 0, 82, 4)
    if not FX_CATS[cat] then return end
    local actor, count, spell = bits(d, 0, 40, 32), bits(d, 0, 72, 6), bits(d, 0, 86, 32)
    local mob = cat == 11 and spell % 65536 or nil   -- 2.7.5: a monster move's param is its mob skill id
    if cat ~= 4 then spell = -1 end
    if count > 16 then return end
    local limit = (tonumber(e.size) or 0) * 8
    local now, scale = hpp.clock(), (tonumber(hpp.s.info.fx.duration_pct) or 100) / 100
    local off = 150
    for _ = 1, count do
        if limit > 0 and off + 36 > limit then return end
        local target = bits(d, 0, off, 32); off = off + 32
        local acts = bits(d, 0, off, 4); off = off + 4
        for j = 1, acts do
            off = off + 27                                   -- reaction, animation, special effect, knockback
            local param = bits(d, 0, off, 17); off = off + 17
            local message = bits(d, 0, off, 10); off = off + 10
            off = off + 31                                   -- flags
            if j == 1 then
                if cat == 11 then Fx.on_mob_move(actor, mob, target, message, param, now, scale)
                else Fx.on_action(actor, spell, target, message, param, now, scale) end
            end
            if bits(d, 0, off, 1) == 1 then                  -- additional effect: animation 6, effect 4, param 17, message 10
                local ap, am = bits(d, 0, off + 11, 17), bits(d, 0, off + 28, 10)
                if Fx.ADD_STATUS[am] then Fx.on_status(actor, target, ap, now, scale) end
                off = off + 1 + 37
            else off = off + 1 end
            if bits(d, 0, off, 1) == 1 then off = off + 1 + 34 else off = off + 1 end   -- spikes
        end
    end
end

-- The focus enemy follows what you attack: an action of yours (melee, ranged, weapon skill, spell, ability) on a monster
-- makes that monster the focus; with no focus yet, a monster acting against you does.
local function track_focus(e)
    local bits = ashita.bits.unpack_be
    local d = e.data_raw
    local actor, count, cat = bits(d, 0, 40, 32), bits(d, 0, 72, 6), bits(d, 0, 82, 4)
    if count < 1 or cat == 0 then return end
    local party, ent = get_party(), get_entity()
    if party == nil or ent == nil then return end
    local me = party:GetMemberServerId(0) or 0
    local target = bits(d, 0, 150, 32)
    local ti = target % 0x1000
    if actor == me then
        if ti ~= 0 and ti < 2303 and is_monster(ti) and (ent:GetServerId(ti) or 0) == target and (ent:GetHPPercent(ti) or 0) > 0 then hpp.focus = ti end
    elseif target == me and (hpp.focus or 0) == 0 then
        local ai = actor % 0x1000
        if ai ~= 0 and ai < 2303 and is_monster(ai) and (ent:GetServerId(ai) or 0) == actor and (ent:GetHPPercent(ai) or 0) > 0 then hpp.focus = ai end
    end
end

-- 2.8.1: a monster's action on someone: remembered for the "enemy's target" mark on the bars over members
local function note_mob_target(e)
    local bits = ashita.bits.unpack_be
    local d = e.data_raw
    local actor, count, cat = bits(d, 0, 40, 32), bits(d, 0, 72, 6), bits(d, 0, 82, 4)
    if count < 1 or cat == 0 or actor < 0x1000000 then return end          -- players' server ids are below 0x1000000
    local target = bits(d, 0, 150, 32)
    if target == actor or target == 0 then return end                      -- buffs on itself
    local ai = actor % 0x1000
    if ai == 0 or ai >= 2304 or not is_monster(ai) then return end
    local v = hpp.mob_last[actor]
    if v == nil then v = {}; hpp.mob_last[actor] = v end
    v[1], v[2] = target, hpp.clock()
end

-- 1.0.7: the hate list: a monster acting on a party member, or a party member acting on a monster (first target)
local function note_hate(e)
    local bits = ashita.bits.unpack_be
    local d = e.data_raw
    local actor, count, cat = bits(d, 0, 40, 32), bits(d, 0, 72, 6), bits(d, 0, 82, 4)
    if count < 1 or cat == 0 then return end
    local target = bits(d, 0, 150, 32)
    if target == actor or target == 0 then return end
    local MS = hpp.hate.ms
    if actor >= 0x1000000 and MS[target] then hpp.hate.seen[actor] = hpp.clock()          -- a monster on a member
    elseif MS[actor] and target >= 0x1000000 then hpp.hate.seen[target] = hpp.clock() end -- a member on a monster
end

ashita.events.register('packet_in', 'partyramaxi_packets', function (e)
    local id = e.id
    if id ~= 0x0028 and id ~= 0x0029 then return end
    if id == 0x0028 and hpp.s and hpp.s.info.dock_hate == true then pcall(note_hate, e) end
    if id == 0x0028 and hpp.s and hpp.s.info.enabled then pcall(track_focus, e) end
    if id == 0x0028 and hpp.s and hpp.s.list.over.enabled then pcall(note_mob_target, e) end
    local s = hpp.s
    if not s or not (s.info.enabled or (s.list and s.list.enabled)) then return end
    local tfx = s.info.fx.enabled or (s.list and s.list.enabled and s.list.buffs and s.list.buffs.timers)
    if tfx and not s.info.fx.enabled then pcall(Fx.tick, hpp.clock()) end
    if id == 0x0029 then
        PBYTES = ffi.cast('uint8_t*', e.data_raw)
        pcall(read_check, e)
        if tfx then pcall(read_fx_message) end
    elseif tfx then
        pcall(read_fx_action, e)
    end
end)

-- Party list: status effects of party members (0x0076) and what members are doing (0x0028).
-- 2.13.4: the name icons of other players (seeking party, away, anon, bazaar, mentor, new adventurer, link dead, GM):
-- packet 0x000D (layout: +0x08 entity index, +0x0A send flags, bit 0x04 = general update, +0x20 Flags1, +0x28 Flags3;
-- see LandSandBoat char_update.cpp / XiPackets 0x000D). The linkshell color is read from the entity itself.
hpp.pc_flags = {}
local function u32at(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
-- 1.0.4: your own character's come in packet 0x0037 instead (layout: +0x24 server id, +0x28 Flags0, +0x2C Flags1,
-- +0x38 Flags3; LandSandBoat char_status.cpp / XiPackets 0x0037), with other bits: they are moved to 0x000D's places.
local function bitv(v, b) return math.floor(v / 2 ^ b) % 2 end
function hpp.own_flags(p)
    local f0, f1, f3 = u32at(p, 0x28), u32at(p, 0x2C), u32at(p, 0x38)
    local o1 = bitv(f0, 4) * 2 ^ 11 + bitv(f0, 5) * 2 ^ 12 + bitv(f0, 7) * 2 ^ 14 + bitv(f0, 25) * 2 ^ 17
             + bitv(f0, 26) * 2 ^ 18 + (math.floor(f0 / 2 ^ 29) % 8) * 2 ^ 24 + bitv(f1, 29) * 2 ^ 31
    local o3 = bitv(f3, 0) * 2 + bitv(f3, 3) * 2 ^ 23 + bitv(f3, 4) * 2 ^ 24
    return o1, o3, u32at(p, 0x24)
end
ashita.events.register('packet_in', 'partyramaxi_pc_flags', function (e)
    if e.id == 0x000A then hpp.pc_flags = {}; return end
    if e.id == 0x0037 then
        pcall(function ()
            local party = get_party()
            local idx = party and party:GetMemberTargetIndex(0) or 0
            if idx == 0 then return end
            local f = hpp.pc_flags[idx]
            if f == nil then f = {}; hpp.pc_flags[idx] = f end
            f.f1, f.f3, f.sid = hpp.own_flags(ffi.cast('uint8_t*', e.data_raw))
        end)
        return
    end
    if e.id ~= 0x000D then return end
    pcall(function ()
        local p = ffi.cast('uint8_t*', e.data_raw)
        if bit.band(p[0x0A], 0x04) == 0 then return end
        local idx = p[0x08] + p[0x09] * 256
        local f = hpp.pc_flags[idx]
        if f == nil then f = {}; hpp.pc_flags[idx] = f end
        f.f1, f.f3, f.sid = u32at(p, 0x20), u32at(p, 0x28), u32at(p, 0x04)
    end)
end)

ashita.events.register('packet_in', 'partyramaxi_list_packets', function (e)
    local id = e.id
    if id ~= 0x0028 and id ~= 0x0076 and id ~= 0x00DC and id ~= 0x00DD then return end
    local s = hpp.s
    if not s or not s.list.enabled then return end
    if id == 0x00DD then
        pcall(function () PData.on_member_update(ffi.cast('uint8_t*', e.data_raw)) end)
    elseif id == 0x00DC then
        if s.list.invite.mode ~= 'off' then pcall(function () PData.on_invite(ffi.cast('uint8_t*', e.data_raw), hpp.clock()) end) end
    elseif id == 0x0076 then
        pcall(function () PData.on_buffs(ffi.cast('uint8_t*', e.data_raw), e.size) end)
    elseif s.list.action.show then
        pcall(PData.on_action, ashita.bits.unpack_be, e.data_raw, hpp.clock())
    end
end)

-- Party list: what members just said, shown next to their name.
ashita.events.register('text_in', 'partyramaxi_list_chat', function (e)
    local s = hpp.s
    if not s or not s.list.enabled or type(e.message) ~= 'string' then return end
    pcall(PData.on_role_text, e.message)
    pcall(PData.on_invite_text, e.message, hpp.clock())
end)

-- Fallback: the chat line of the reply (also understands "Lv. 18-20" style ranges on servers that print them).
ashita.events.register('text_in', 'partyramaxi_check_text', function (e)
    if not hpp.s or not hpp.s.info.enabled or type(e.message) ~= 'string' then return end
    -- Runs for every chat line: skip at once unless the line has a word a check reply has.
    local m = e.message
    if m:find('Check debug', 1, true) then return end          -- 1.0.4: not our own debug lines
    if not (m:find('rey', 1, true) or m:find('ough', 1, true) or m:find('atch', 1, true) or m:find('eak', 1, true)
        or m:find('allenge', 1, true) or m:find('Lv', 1, true) or m:find('evel', 1, true)
        or m:find('vasion', 1, true) or m:find('efense', 1, true) or m:find('gauge', 1, true)) then return end
    pcall(function ()
        -- 1.0.6: the main target or the sub-target (whose check came last first, then the one named in the line)
        local idx = hpp.st.main ~= 0 and hpp.st.main or hpp.st.sub
        local last = hpp.check_last or 0
        if last ~= 0 and (last == hpp.st.main or last == hpp.st.sub) then idx = last end
        local ent = get_entity()
        if idx ~= 0 and hpp.st.sub ~= 0 and hpp.st.sub ~= idx and is_monster(hpp.st.sub) then
            local nm = ent:GetName(idx)
            local ns = ent:GetName(hpp.st.sub)
            local l = m:lower()
            if type(nm) == 'string' and type(ns) == 'string' and not l:find(nm:lower(), 1, true) and l:find(ns:lower(), 1, true) then idx = hpp.st.sub end
        end
        if idx == 0 or not is_monster(idx) then return end
        local name = ent:GetName(idx)
        local now = hpp.clock()
        local dv = Info.parse_defev(e.message, idx, name, now)
        if dv and hpp.check_dbg then
            local c = Info.get(idx, name)
            msg(('Check debug: chat line understood -> evasion %s, defense %s'):format(tostring(c and c.eva), tostring(c and c.def)))
        end
        local tx = Info.parse_text(e.message, name, idx, now)
        if tx and hpp.check_dbg then
            local c = Info.get(idx, name)
            msg(('Check debug: chat line understood -> level %s, range %s, difficulty %s'):format(
                tostring(c and c.level), c and c.lo and (c.lo .. '-' .. c.hi) or 'none', tostring(c and c.diff and Info.DIFF[c.diff].short)))
        end
        -- 1.0.4: a reply line to an automatic check that still reached the chat is hidden too
        if (dv or tx) and hpp.auto_reply(idx, now) then
            e.blocked = true
            if hpp.check_dbg then msg('Check debug: that chat line was hidden (automatic check)') end
        end
    end)
end)

-- Each part of the frame is guarded on its own (see guard); this is the last resort.
-- Hide again before the game draws: its target window (and the pointer arrows it owns) would otherwise show for a frame
-- every time it re-shows itself.
ashita.events.register('d3d_beginscene', 'partyramaxi_beginscene', function ()
    if not hpp.loaded or hpp.zoning then return end
    pcall(hpp.wins.early, hpp.wins, hpp.want)
    pcall(hpp.cam.capture, 'beginscene', hpp.fno)
end)

-- The 3D camera is on the device while the world is drawn, not by d3d_present (see pxiproj.lua): read it here too.
pcall(ashita.events.register, 'd3d_endscene', 'partyramaxi_endscene', function ()
    if not hpp.loaded or hpp.zoning then return end
    pcall(hpp.cam.capture, 'endscene', hpp.fno)
end)

-- First-frame catch (see pxiwin catch_target). The draw-call events are only registered while armed, i.e. while the target
-- window should be hidden but doesn't exist (nothing targeted), so they cost nothing the rest of the time.
local CATCH_EVENTS = { 'd3d_dp', 'd3d_dpup', 'd3d_dip', 'd3d_dipup' }
local function on_draw_call()
    if not hpp.catch_armed then return end
    local ok, done = pcall(hpp.wins.catch_target, hpp.wins)
    if not ok or done then hpp.catch_armed = false end     -- unregistered at the next present, not from inside the call
end
local function catch_events(on)
    if (hpp.catch_on == true) == on then return end
    hpp.catch_on = on
    for i = 1, #CATCH_EVENTS do
        local ev = CATCH_EVENTS[i]
        if on then pcall(ashita.events.register, ev, 'partyramaxi_catch_' .. ev, on_draw_call)
        else pcall(ashita.events.unregister, ev, 'partyramaxi_catch_' .. ev) end
    end
end
hpp.catch_events = catch_events
function hpp.update_catch()
    local want = hpp.s.catch_first == true and hpp.want.target == true and not hpp.zoning
    local _, mcd
    if want then _, mcd = hpp.wins:object('target') end
    hpp.catch_armed = want and mcd == nil
    catch_events(hpp.catch_armed)
end

ashita.events.register('d3d_present', 'partyramaxi_present', function ()
    if not hpp.loaded then return end
    guard('frame', hpp.frame)
end)

return hpp
