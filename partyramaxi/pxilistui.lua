--[[
* PartyramaXI - settings for the party list (the "Party list" tab).
* Built on the small widgets of pxiui.lua (passed in as w): sliders with - / + buttons, color pickers, combos.
--]]
local real_imgui = require('imgui')
local SEARCHING = false
local SEARCH = { '' }
local W_SKIP                                       -- pxiui's label filter (set in M.draw)
local NOP = function () end
-- While the settings search is on, headings, texts, buttons and notes are dropped and combos are filtered, so only matching settings remain.
local OVR = {
    Text = NOP, TextDisabled = NOP, TextWrapped = NOP, TextColored = NOP, Separator = NOP, SameLine = NOP,
    CollapsingHeader = function () return true end,
    Button = function () return false end, SmallButton = function () return false end, InputInt = function () return false end, TreeNode = function () return false end, InputText = function () return false end,
    BeginCombo = function (label, prev)
        if W_SKIP and W_SKIP(label) then return false end
        return real_imgui.BeginCombo(label, prev)
    end,
}
-- 2.9.0: inside a greyed-out block (pxiui's when) buttons and pickers draw but do nothing
local W_DIS = function () return 0 end
local DOV = {
    Button = function (...) real_imgui.Button(...); return false end,
    SmallButton = function (...) real_imgui.SmallButton(...); return false end,
    Selectable = function () return false end, InputText = function () return false end,
    BeginCombo = function (...) if real_imgui.BeginCombo(...) then real_imgui.EndCombo() end return false end,
}
local imgui = setmetatable({}, { __index = function (_, k)
    if SEARCHING and OVR[k] then return OVR[k] end
    if DOV[k] and W_DIS() > 0 then return DOV[k] end
    return real_imgui[k]
end })
local Theme = require('pxilisttheme')
local PL    = require('pxilist')
local Fonts = require('pxifonts')
local Data  = require('pxilistdata')
local Fx    = require('pxifx')
local Buffs = require('pxibuffs')
local Draw  = require('pxidraw')

local M = {}

local JOBF = { 'both', 'jobs', 'main', 'lv', 'none' }
local JOBF_LABELS = { both = 'WAR 75 / NIN 37', jobs = 'WAR/NIN', main = 'WAR 75', lv = 'Lv75', none = 'None' }
local GLOSS = { 'none', 'gradient', 'glossy', 'shine' }
local GLOSS_LABELS = { none = 'Flat', gradient = 'Gradient', glossy = 'Glossy', shine = 'Shine' }
local COMETS = { 'off', 'once' }
local COMET_LABELS = { off = 'Off', once = 'Play once' }
local ALIGNS = { 'left', 'center', 'right' }
local ALIGN_LABELS = { left = 'Left', center = 'Centre', right = 'Right' }
local STYLES = { 'line', 'tb', 'corners', 'gilded' }
local STYLE_LABELS = { line = 'Line', tb = 'Top / bottom line', corners = 'Corners', gilded = 'Gilded',
    double = 'Double (theme)', glow = 'Glow (theme)', bevel = 'Bevel (theme)' }
local TEXTS = { 'current', 'current_max', 'percent', 'both', 'none' }
local TP_TEXTS = { 'current', 'none' }
local TP_TEXT_LABELS = { current = '1234', none = 'None' }
local TEXT_LABELS = { current = '1234', current_max = '1234/1500', percent = '82%', both = '1234 (82%)', none = 'None' }
local POS = { 'center', 'left', 'right' }
local POS_LABELS = { center = 'Centre', left = 'Left', right = 'Right' }
local MODES = { 'color', 'png' }
local MODE_LABELS = { color = 'Colors', png = 'PNG image' }
local SCOPES = { 'window', 'row' }
local SCOPE_LABELS = { window = 'Whole list', row = 'Every card' }

local function theme_label(s) return s end

local PETMODES = { 'attached', 'section' }
local PETMODE_LABELS = { attached = 'Under owner', section = '"Pets" section' }
local TPOS = { 'inside', 'below', 'off' }
local TPOS_LABELS = { inside = 'On the icon', below = 'Under the icon', off = 'No number' }
local TUNK = { 'elapsed', 'none' }
local TUNK_LABELS = { elapsed = 'Count up (+12)', none = 'Show nothing' }

-- A font chooser. inherit = true adds "Same as the list" (stored as '').
local function font_combo(w, label, tbl, key, inherit)
    local cur = tbl[key]
    local shown = (cur == nil or cur == '') and (inherit and 'Same as the list' or Fonts.DEFAULT) or cur
    local UI = require('pxiui')
    local kk = (not SEARCHING) and UI.key_pre(label) or nil      -- 2.13.0: List font is a key setting
    local open = imgui.BeginCombo(label, shown)
    UI.key_post(kk)
    if open then
        if inherit and imgui.Selectable('Same as the list##inh' .. label, cur == '') then tbl[key] = ''; w.changed() end
        for _, f in ipairs(Fonts.names()) do
            if imgui.Selectable(f.name .. '##f' .. label, f.name == cur) then tbl[key] = f.name; w.changed() end
        end
        imgui.EndCombo()
    end
    w.mark()
end

local CUR_L
local PIN_Q = { '' }
local LAYER_ORDER = { 'icon', 'name', 'job', 'hp', 'mp', 'tp', 'action', 'buffs', 'hpnum', 'mpnum', 'tpnum' }

-- Font size in pixels (stored as a multiplier of the game's ImGui font).
local function font_px(w, tbl, key, id, smin, smax, label)
    local base = 14
    pcall(function () local f = imgui.GetFontSize(); if f and f > 4 then base = f end end)
    local cur = tonumber(tbl[key]) or 1
    local proxy = { px = math.floor(cur * base + 0.5) }
    local before = proxy.px
    w.slider_int((label or 'Font size') .. '##fs_' .. id, proxy, 'px', math.max(6, math.ceil(smin * base)), 50, '%d px')
    if proxy.px ~= before then tbl[key] = proxy.px / base end
end

-- Front / forward / backward / back buttons for one element. Renumbers the layers of all elements 1..n.
local function layer_row(w, key)
    local L = CUR_L
    if L == nil or PL.ZDEF == nil or PL.ZDEF[key] == nil or key == 'roles' or type(L[key]) ~= 'table' then return end
    local list = {}
    for i, k in ipairs(LAYER_ORDER) do list[#list + 1] = { k = k, z = tonumber(L[k] and L[k].z) or PL.ZDEF[k], i = i } end
    table.sort(list, function (a, b) if a.z ~= b.z then return a.z < b.z end return a.i < b.i end)
    local pos
    for i, e in ipairs(list) do if e.k == key then pos = i end end
    if pos == nil then return end
    local function move(to)
        local e = table.remove(list, pos)
        table.insert(list, math.max(1, math.min(#list + 1, to)), e)
        for i, x in ipairs(list) do L[x.k].z = i end
        w.changed()
    end
    imgui.Text('Layer ' .. pos .. ' of ' .. #list .. ' (higher = in front)')
    if imgui.Button('Backward##ly_bw_' .. key) then move(pos - 1) end
    imgui.SameLine()
    if imgui.Button('Forward##ly_fw_' .. key) then move(pos + 1) end
end

local function sub_tab(label, fn, ...)
    if require('pxiui').sub_tab_item(label) then
        local ok, e = pcall(fn, ...)
        imgui.EndTabItem()
        if not ok then error(e, 0) end
    end
end

-- Position rows used inside every element's section (the same values Edit positions drags).
local function offset_rows(w, t, id, defx, defy, lim)
    lim = lim or 600
    w.slider_int('Left / right##off_' .. id .. '_dx', t, 'dx', -lim, lim, '%d px', 'Left (-) / right (+). You can also drag the element with Edit positions.')
    w.slider_int('Down / up##off_' .. id .. '_dy', t, 'dy', -lim, lim, '%d px', 'Down (-) / up (+).', true)
    if imgui.Button('Reset position##off_' .. id .. '_r') then t.dx, t.dy = defx or 0, defy or 0; w.changed() end
    layer_row(w, (id:gsub('^pos_', '')))
end

local function bar_section(w, title, B, key, help)
    if not w.group(title .. '##plbar_' .. key, 'list', key, true) then return end
    local id = '_pl' .. key
    local when = w.when
    w.sub_head('plb_' .. key, 'Show the ' .. title, B, 'show', help, 'none')     -- 2.9.2: under its own header
    when(B.show ~= false, function ()
        w.slider_int('Height##h' .. id, B, 'height', 3, 40, '%d px')
        w.checkbox('Automatic length (fill the space)##alen' .. id, B, 'auto_len', 'On: the bar takes the space the layout gives it. Off: you set the length in pixels.')
        when(B.auto_len == false, w.slider_int, 'Length##len' .. id, B, 'length', 10, 500, '%d px', 'The bar keeps its left end; use the position offset to move it.')
        w.slider_int('Rounding##r' .. id, B, 'rounding', 0, 30, '%d px', 'Corner radius; half the height makes a pill.')
        w.color((key == 'tp' and B.rollover ~= false) and ('Color 0-999 TP##fill' .. id) or ('Fill color##fill' .. id), B, 'fill')
        if key == 'hp' then
            w.checkbox('Color by health##byhp', B, 'by_hp', 'The fill changes to the warning color, then the low color, as health drops. You choose where each change happens.')
            when(B.by_hp, function ()
                w.color('Warning color##warn', B, 'warn')
                w.slider_float('Turns to warning below##warnat', B, 'warn_at', 0.05, 0.95, '%.2f', 'Share of health (0.50 = half) under which the bar turns the warning color.')
                w.color('Low color##low', B, 'low')
                w.slider_float('Turns to low below##lowat', B, 'low_at', 0.02, 0.90, '%.2f', 'Share of health under which the bar turns the low color.')
                w.checkbox('Blend between colors##blend', B, 'blend', 'Off = the color switches the moment a threshold is crossed.')
            end)
            w.checkbox('Damage trail##trail', B, 'trail', 'Recent damage drains out slowly behind the bar.')
            when(B.trail, w.color, 'Trail color##trailc', B, 'trail_color')
        elseif key == 'tp' then
            w.checkbox('Roll over every 1000 TP##roll', B, 'rollover', 'The bar fills once per 1000 TP. Past 1000 the previous level stays behind it, full, and the next level fills over it in its own color.')
            when(B.rollover ~= false, function ()
                w.color('Color 1000-1999 TP##full', B, 'full')
                w.color('Color 2000-3000 TP##full3', B, 'full3')
            end)
            when(B.rollover == false, function ()
                w.color('Color at 1000+ TP##full_nr', B, 'full')
                w.checkbox('Pulse at 1000+ TP##pulse', B, 'pulse')
                w.checkbox('Marks at 1000 / 2000##ticks', B, 'ticks')
            end)
        end
        w.color('Background##back' .. id, B, 'back')
        w.checkbox('Border##bon' .. id, B, 'border_on')
        when(B.border_on, function ()
            w.color('Border color##bc' .. id, B, 'border')
            w.slider_int('Border width##bw' .. id, B, 'border_w', 1, 8, '%d px', 'The outermost edge of the bar.')
        end)
        w.radio('Finish##gl' .. id, B, 'gloss', GLOSS, GLOSS_LABELS)
        when(B.gloss ~= 'none', w.slider_float, 'Finish strength##gs' .. id, B, 'gloss_strength', 0, 1, '%.2f')
        w.heading('Effects')
        if key == 'tp' then
            w.checkbox('Glass sheen when TP fills to 3000 (100%)##sheen' .. id, B, 'sheen', 'One soft diagonal shine sweeps left to right when the TP bar becomes completely full (3000 TP), clipped inside the bar.')
            w.radio('Comet##cm' .. id, B, 'comet', COMETS, COMET_LABELS, 'A glowing head with a fading tail runs once along the bar when TP reaches 1000 (a weapon skill is ready).')
            w.checkbox('Glow at 1000+ TP##glow' .. id, B, 'glow', 'A soft pulsing halo around the bar while you have 1000 or more TP.')
        else
            local nm = key == 'hp' and 'HP' or 'MP'
            w.checkbox('Glass sheen when ' .. nm .. ' fills to 100%##sheen' .. id, B, 'sheen', 'One soft diagonal shine sweeps left to right when the bar reaches 100% of maximum ' .. nm .. ', clipped inside the bar.')
            w.radio('Comet##cm' .. id, B, 'comet', COMETS, COMET_LABELS, 'A glowing head with a fading tail runs once along the bar when ' .. nm .. ' reaches 100% of maximum.')
        end
        when(B.comet ~= 'off', function ()
            w.color('Comet color##cmc' .. id, B, 'comet_color')
            w.slider_float('Comet speed##cms' .. id, B, 'comet_speed', 0.3, 3, '%.2f', '1 = 1.3 seconds for the pass; higher is faster.')
        end)
        w.heading('Position')
        offset_rows(w, B, key, 0, 0)
    end)
end

-- The number on a bar: what it shows, its font and its own position / layer.
local function bar_number(w, title, B, key)
    if not w.group(title .. '##plnum_' .. key, 'list', key, true) then return end
    local id = '_pl' .. key
    local when = w.when
    if key == 'tp' then w.radio('Show##tx' .. id, B, 'text', TP_TEXTS, TP_TEXT_LABELS)
    else w.radio('Show##tx' .. id, B, 'text', TEXTS, TEXT_LABELS) end
    when(B.text ~= 'none', function ()
        w.radio('Position##tp' .. id, B, 'text_pos', POS, POS_LABELS)
        font_px(w, B, 'text_scale', id, 0.4, 1.6, 'Number font size')
        font_combo(w, 'Number font##nf' .. id, B, 'font', true)
        w.checkbox('Bold##nb' .. id, B, 'bold'); imgui.SameLine(); w.checkbox('Italic##nib' .. id, B, 'italic')
        if key == 'tp' then
            w.color('Color under 1000##tc' .. id, B, 'text_color')
            w.color('Color from 1000##tc2' .. id, B, 'num_color2', 'The number\'s color once TP reaches 1000 (a weapon skill is ready).')
            w.checkbox('Flash from 1000##tfl' .. id, B, 'num_flash', 'The number pulses while TP is 1000 or more.')
            when(B.num_flash, function ()
                w.slider_float('Flash speed##tfs' .. id, B, 'num_flash_speed', 0.3, 4, '%.1f /s', 'Pulses per second.')
                w.slider_float('Flash dims to##tfm' .. id, B, 'num_flash_min', 0, 1, '%.2f', 'Opacity at the dimmest point of the flash (1 = no dip).')
            end)
        else
            w.color('Number color##tc' .. id, B, 'text_color')
        end
        w.slider_int('Number left / right##tdx' .. id, B, 'text_dx', -300, 300, '%d px')
        w.slider_int('Number down / up##tdy' .. id, B, 'text_dy', -100, 100, '%d px', 'Down (-) / up (+).', true)
        if imgui.Button('Reset number position##tr' .. id) then B.text_dx, B.text_dy = 0, 0; w.changed() end
        layer_row(w, key .. 'num')
    end)
end

local tab_layout, tab_pets, tab_motion, tab_action
local function tab_general(L, w, hpp)
    if w.group('The list##g_pl_list', 'list', 'window', true) then
        w.when(not L.from_bottom, w.checkbox, 'Grow upward##pl_gu', L, 'grow_up', 'The list keeps its bottom edge: when members join it extends upward, and when they leave it shrinks back down. You stay at the top.')
        w.checkbox('You at the bottom##pl_fb', L, 'from_bottom', 'Your card is the last one and the list is held by its bottom edge: as your party grows, it extends upward (alliances above it).')
        w.slider_float('Out of zone opacity##pl_oz', L, 'out_alpha', 0.1, 1, '%.2f', 'Members in another zone are dimmed and show their zone.')
        if not SEARCHING then
            imgui.TextDisabled('Effects are shown for you and your own party only (the game does not send them for alliance members).')
            imgui.TextDisabled('Alliance: Alliance tab. Group titles: Text tab. Pets: Pets and summons below.')
        end
    end
    tab_layout(L, w)
    tab_pets(L, w)
    tab_motion(L, w, hpp)
end

local KINDS = { 'solid', 'png' }
local KIND_LABELS = { solid = 'Solid color', png = 'PNG, cut in nine' }

-- A drop-down of the PNG files in backgrounds\, with Rescan and Open folder buttons after it.
local function png_pick(w, label, tbl, key, id)
    local files = PL.png_bg and PL.png_bg.files or {}
    local cur = (tbl[key] or '') ~= '' and tbl[key] or '(choose a file)'
    if imgui.BeginCombo(label, cur) then
        for _, f in ipairs(files) do
            if imgui.Selectable(f .. '##' .. id .. f, f == tbl[key]) then tbl[key] = f; w.changed() end
        end
        imgui.EndCombo()
    end
    w.mark()
    if imgui.Button('Rescan##' .. id .. '_scan') then if PL.png_bg then PL.png_bg:reload() end end
    w.tip('Look for new PNG files in addons\\partyramaxi\\backgrounds\\.')
    imgui.SameLine()
    if imgui.Button('Open folder##' .. id .. '_open') then PL.open_folder(PL.png_bg and PL.png_bg.dir or ((addon and addon.path or '') .. 'backgrounds\\')) end
    w.tip('Opens addons\\partyramaxi\\backgrounds\\ in Explorer. Put PNG files there, then press Rescan.')
    if #files == 0 then imgui.TextDisabled('No PNG files found in backgrounds\\.') end
end

-- A square box in the settings window that shows a PNG cut in nine, the way the list draws it.
local PREV = { 0, 0 }
local function png_box(file, slice, tint, size, dark)
    local ok, x, y = pcall(imgui.GetCursorScreenPos)
    local dl = imgui.GetWindowDrawList()
    PREV[1], PREV[2] = 112, 112
    imgui.Dummy(PREV)
    if not ok or type(x) ~= 'number' or dl == nil then return end
    if dark then pcall(dl.AddRectFilled, dl, { x, y }, { x + 112, y + 112 }, Draw.u32({ 0.08, 0.09, 0.12, 1 }), 0) end
    pcall(dl.AddRect, dl, { x - 1, y - 1 }, { x + 113, y + 113 }, Draw.u32({ 1, 1, 1, 0.25 }), 0)
    if not PL.preview_panel(dl, file, x + 8, y + 8, x + 104, y + 104, slice, tint, size) then
        pcall(dl.AddText, dl, { x + 10, y + 48 }, Draw.u32({ 1, 1, 1, 0.5 }), '(no picture)')
    end
end

local function tab_style(L, w, hpp)
    local when = w.when
    if w.group('Theme##g_pl_theme', 'list', 'window', true) then
        local cur = L.theme
        local UI = require('pxiui')
        local kk = (not SEARCHING) and UI.key_pre('Theme##pl_theme') or nil
        local open = imgui.BeginCombo('Theme##pl_theme', cur)
        UI.key_post(kk)
        if open then
            for _, name in ipairs(Theme.NAMES) do
                if imgui.Selectable(name .. (name == Theme.CUSTOM and '  (keep my own settings)' or ''), name == cur) then
                    Theme.apply(L, name); w.changed()
                end
            end
            imgui.EndCombo()
        end
        w.mark()
        w.tip('A theme copies its colors, background, border and bar look into the settings below once. Everything stays yours to change; "Custom" changes nothing.')
        -- 2.13.1: the list's background and border can be RecastXI's theme frame
        w.checkbox('Assume RecastXI Theme##plw_rxth', L.bg, 'rx_theme', 'Draws the list\'s background and border with the theme chosen in RecastXI > Appearance > Theme (its colors, border, corner ornaments and outer glow), so the list and RecastXI match. The Background and Border settings below are not used while this is on.')
    end
    if w.group('Background##g_pl_win', 'list', 'window', true) then
        local kind = (L.bg.mode == 'png') and 'png' or 'solid'
        local KB = { k = kind }
        local rx = L.bg.rx_theme == true
        if rx and not SEARCHING then imgui.TextDisabled('Using the RecastXI theme (Theme, above).') end
        when(not rx, function ()
            w.radio('Background##plw_kind', KB, 'k', KINDS, KIND_LABELS)
            if KB.k ~= kind then L.bg.mode = (KB.k == 'png') and 'png' or 'color'; w.changed() end
        end)
        w.slider_int('Background height##plw_top', L.win, 'top_dy', -60, 60, '%d px', 'Where the top of the background and border begins. 0 = at the middle of the first group title (the title sits half over the top edge). + moves it up, - down.', true)
        when(KB.k == 'solid' and not rx, function ()
            if (L.win.bg[4] or 0) <= 0.01 then imgui.TextColored({ 1, 0.8, 0.3, 1 }, 'The color is fully transparent: raise the A bar in the picker.') end
            w.color('Color 1##plw_bg', L.win, 'bg')
            w.checkbox('Color 2 (makes a gradient)##plw_grad', L.win, 'grad', 'On: the background fades from Color 1 at the top to Color 2 at the bottom. Off: Color 1 only.')
            when(L.win.grad, w.color, 'Color 2##plw_bg2', L.win, 'bg2')
        end)
        when(KB.k == 'png' and not rx, function ()
            png_pick(w, 'Picture##plbg_file', L.bg, 'file', 'plbg')
            if KB.k == 'png' then png_box(L.bg.file, L.bg.slice, L.bg.tint, nil, false) end
            w.radio('Placed##plbg_scope', L.bg, 'scope', SCOPES, SCOPE_LABELS)
            w.slider_int('Border cut (9-slice)##plbg_slice', L.bg, 'slice', 0, 64, '%d px',
                '0 stretches the whole picture. Above 0 the corners keep their size and only the middle stretches: set it to the width of the picture\'s border.')
            w.color('Tint / opacity##plbg_tint', L.bg, 'tint')
        end)
    end
    if w.group('Border##g_pl_border', 'list', 'window', true) then
        when(L.bg.rx_theme ~= true, function ()
            w.slider_int('Thickness##plw_bw', L.win, 'border_w', 0, 3, '%d px', '0 = no border.')
            when((tonumber(L.win.border_w) or 0) > 0, function ()
                w.radio('Border##plw_style', L.win, 'style', STYLES, STYLE_LABELS, 'Line all round, a line along the top and bottom only, corner brackets, or gilded (double line with corner studs).')
                w.color('Color##plw_bd', L.win, 'border')
            end)
            w.slider_int('Rounding##plw_r', L.win, 'rounding', 0, 30, '%d px', 'How round the corners of the background and border are (0 = square). Every border style follows the curve. A PNG background keeps its own shape.')
        end)
    end
    if w.group('Cards##pl_cards', 'list', 'card') then
        w.checkbox('Card background##plc_show', L.card, 'show')
        when(L.card.show ~= false, function ()
            w.color('Card color##plc_bg', L.card, 'bg')
            w.color('Card border##plc_bd', L.card, 'border')
            w.slider_int('Border width##plc_bw', L.card, 'border_w', 0, 4, '%d px')
            w.slider_int('Rounding##plc_r', L.card, 'rounding', 0, 30, '%d px')
        end)
        w.checkbox('Highlight on mouse over##plc_hv', L.card, 'hover')
        w.heading('Sizes')
        local C = L.cards
        local was = C.link
        w.checkbox('Same width for all cards##plz_link', C, 'link', 'On: one width for party, alliance and pet cards (the pet card keeps its indent under its owner). Off: set each width on its own.')
        if C.link and not was then M.link_widths(C) end
        when(C.link, function ()
            local pw = C.party.w
            w.slider_int('Card width##plz_w', C.party, 'w', 60, 800, '%d px')
            if C.link and (C.party.w ~= pw or C.alliance.w ~= C.party.w) then M.link_widths(C, pw) end
        end)
        when(not C.link, function ()
            w.slider_int('Party width##plz_pw', C.party, 'w', 60, 800, '%d px')
            when(L.alliance, w.slider_int, 'Alliance width##plz_aw', C.alliance, 'w', 60, 800, '%d px')
            when(L.pets.show, w.slider_int, 'Pet width##plz_tw', C.pet, 'w', 60, 800, '%d px')
        end)
        w.slider_int('Party height##plz_ph', C.party, 'h', 10, 400, '%d px')
        when(L.alliance, w.slider_int, 'Alliance height##plz_ah', C.alliance, 'h', 10, 400, '%d px')
        when(L.pets.show, w.slider_int, 'Pet height##plz_th', C.pet, 'h', 10, 400, '%d px')
        w.slider_int('Selected: extra width##plz_sw', C.sel, 'dw', -100, 300, '%d px', 'The selected member\'s card is this much wider (or narrower).')
        w.slider_int('Selected: extra height##plz_sh', C.sel, 'dh', -100, 300, '%d px', 'The selected member\'s card is this much taller (or shorter); the cards around it move to make room.')
    end
    if w.group('Player Highlight##pl_sel', 'list', 'card') then
        w.color('Targeted##pls_t', L.sel, 'target')
        w.color('Game cursor (sub-target)##pls_c', L.sel, 'cursor')
        w.color('Selected (cycling / click)##pls_s', L.sel, 'select')
        w.color('Selected box color##pls_fill', L.sel, 'fill', 'The fill of the selected member\'s box; its A bar sets how strong it is.')
        w.slider_int('Height##pls_h', L.sel, 'height', -20, 40, '%d px', 'Added to the card\'s height (half above, half below); 0 = the card\'s height.')
        w.slider_int('Outline width##pls_bw', L.sel, 'border_w', 1, 5, '%d px')
        w.slider_int('Rounding##pls_r', L.sel, 'rounding', 0, 30, '%d px', 'Corners of the highlight, outline and flash.')
        w.checkbox('Flash when selected##pls_fl', L.sel, 'flash', 'A brief glow in the selection color when a card becomes targeted or selected.')
        w.checkbox('Repeat the border flash##pls_rf', L.sel, 'repeat_flash', 'The border of the member your cursor or selection is on flashes again every few seconds (not the plain main target).')
        when(L.sel.repeat_flash ~= false, w.slider_float, 'Repeat every##pls_re', L.sel, 'repeat_every', 1, 15, '%.1f s')
        w.checkbox('Sheen when selected##pls_sh', L.sel, 'sheen', 'A soft glass sheen sweeps across the card when it becomes targeted or selected, and again every 2-3 seconds while it stays highlighted.')
        w.checkbox('Move the selected card##pls_lift', L.sel, 'lift', 'The card of the member you select or target slides a few pixels off its place (and back when you move on), as well as the highlight.')
        when(L.sel.lift ~= false, function ()
            w.slider_int('Move left / right##pls_ldx', L.sel, 'move_dx', -16, 16, '%d px', 'Left (-) / right (+).')
            w.slider_int('Move down / up##pls_ldy', L.sel, 'move_dy', -16, 16, '%d px', 'Down (-) / up (+).', true)
        end)
    end
end

tab_layout = function (L, w)
    if w.group('Position and spacing##g_pl_gap', 'list', 'window', true) then
        w.checkbox('Lock position##pl_lock', L, 'locked', 'One lock for the list and its undocked windows. Untick to drag them somewhere else (clicking cards is off while unlocked). Edit positions (top) moves the parts inside the cards.')
        w.slider_int('Party: space between cards##pll_gap', L, 'gap', 0, 20, '%d px', 'Between party cards and before and after group titles. Everything inside a card is placed with the element\'s own position (Edit positions) and may overlap freely.')
        w.when(L.alliance, w.slider_int, 'Alliance: space between cards##pll_gapa', L, 'gap_ally', 0, 20, '%d px', 'Between the cards of alliance 1 and 2.')
        w.when(L.pets.show, w.slider_int, 'Pets: space around a pet card##pll_gapp', L, 'gap_pet', 0, 20, '%d px', 'Before and after each pet or summon card.')
    end
end
-- a window that was just undocked starts beside the list
local function undock_place(L, was_ally, was_pets)
    local B = PL.box_ok and PL.box and PL.box()
    if B == nil then return end
    if was_ally and L.ally_dock == false then L.ally_win.x, L.ally_win.y = math.floor(B.x1 + 20), math.floor(B.y0) end
    if was_pets and L.pets.dock == false then L.pets.win.x, L.pets.win.y = math.floor(B.x1 + 20), math.floor(B.y0 + 200) end
end

-- One text element: show, look, font and position.
local function text_el(w, title, T, key, id, smin, smax, extra, open)
    if not w.group(title .. '##plt_' .. id .. '_h', 'list', key, open) then return end
    w.checkbox('Show##plt_' .. id, T, 'show')
    w.when(T.show ~= false, function ()
        if extra then extra() end
        w.when(T.format ~= 'none', function ()      -- the job title with Format "None" draws nothing
            w.color('Color##plt_' .. id .. 'c', T, 'color')
            font_px(w, T, 'scale', key, smin, smax)
            font_combo(w, 'Font##plf_' .. id, T, 'font', true)
            w.checkbox('Bold##plf_' .. id .. 'b', T, 'bold'); imgui.SameLine(); w.checkbox('Italic##plf_' .. id .. 'i', T, 'italic')
            w.heading('Position')
            offset_rows(w, T, key, 0, 0)
        end)
    end)
end

-- Text: the list's shared text, the group titles, the name and the job title.
local function tab_text(L, w)
    if w.group('Shared text options##plt_shared', 'list', '*', true) then
        imgui.TextDisabled('Any Windows font found on this PC, or a .ttf / .otf in addons\\partyramaxi\\fonts\\.')
        font_combo(w, 'List font##plf_base', L, 'font', false)
        imgui.SameLine()
        if imgui.Button('Rescan fonts##plf_scan') then Fonts.rescan() end
        imgui.TextDisabled('Own fonts: put static .ttf / .otf files in addons\\partyramaxi\\fonts\\ (family files like Nunito-Regular / -Bold / -Italic / -BoldItalic are grouped into one entry), then Rescan.')
        w.checkbox('Bold##plf_bold', L, 'bold'); imgui.SameLine(); w.checkbox('Italic##plf_bold_it', L, 'italic')
        w.checkbox('Text shadow##plt_sh', L, 'shadow')
        w.checkbox('Text outline##plt_ol', L, 'outline', 'An outline around every letter of the list. Easiest to read on bright backgrounds.')
        w.when(L.outline, function ()
            w.slider_int('Outline thickness##plt_ow', L, 'outline_w', 1, 3, '%d px')
            w.color('Outline color##plt_oc', L, 'outline_color')
        end)
    end
    if w.group('Group titles##plt_hd_h', 'list', 'head') then
        local H = L.head
        w.checkbox('Show group titles##plt_hshow', L, 'headers', 'Party / Alliance 1 / Alliance 2, when more than one group is shown ')
        w.when(L.headers ~= false, function ()
            w.checkbox('Show "Solo" title when alone##plt_hsolo', H, 'show_solo', 'Normally the title only appears when more than one group is shown. A lone party is titled "Solo".')
            w.color('Color##plt_hc', H, 'color')
            font_px(w, H, 'scale', 'head', 0.5, 1.5)
            font_combo(w, 'Font##plf_hd', H, 'font', true)
            w.checkbox('Bold##plf_hb', H, 'bold'); imgui.SameLine(); w.checkbox('Italic##plf_hb_it', H, 'italic')
            w.radio('Align##plt_hal', H, 'align', ALIGNS, ALIGN_LABELS)
            w.heading('Position')
            offset_rows(w, H, 'head', 0, 0, 400)
        end)
    end
    text_el(w, 'Player Name', L.name, 'name', 'name', 0.6, 2, function () w.checkbox('ALL CAPS##plt_caps', L.name, 'caps') end, true)
    text_el(w, 'Job Title', L.job, 'job', 'job', 0.5, 1.6, function () w.combo('Format##plt_jf', L.job, 'format', JOBF, JOBF_LABELS) end)
    tab_action(L, w)
    if not SEARCHING then imgui.TextDisabled('HP / MP / TP numbers: Bars tab.') end
end

-- Bars: one sub-tab each for HP, MP, TP, the current action and the bars over members, with their text and bar.
local function list_test_head(w, hpp, id, label, tbl, key, help)
    local on = hpp.list_test == true
    if w.sub_head(id, label, tbl, key, help, 'none') == 'test' then      -- 2.9.1: the Party list's Test at the top is the only one
        hpp.list_test = not on; if hpp.list_test then PL.broken = false else hpp.list_test_anim, hpp.list_test_hl = false, false end
    end
end
local function bar_tab(L, w, hpp, key, title, num)
    local B = L[key]
    bar_section(w, title .. ' Bar', B, key, key == 'tp' and 'The TP bar. The TP number below is switched on its own (Show).' or ('The ' .. title .. ' bar on every card.'))
    -- the HP / MP number is drawn on its bar (no bar, no number); the TP number has its own Show
    if key == 'tp' then bar_number(w, num, B, key) else w.when(B.show ~= false, bar_number, w, num, B, key) end
end

-- 2.13.0: the current action is text (with a cast bar under it), so it lives in the Text tab, after Job Title
tab_action = function (L, w)
    local A = L.action
    if not w.group('Current Action##ple_act', 'list', 'action') then return end
    w.checkbox('Show the current action##plb_act', A, 'show', 'Spell, weapon skill, ability, item or ranged attack. Casts show a progress bar.')
    w.when(A.show ~= false, function ()
        font_px(w, A, 'scale', 'action', 0.5, 1.6)
        w.slider_float('Show finished for##ple_hold', A, 'hold', 0.5, 5, '%.1f s')
        w.color('Casting##ple_c', A, 'color')
        w.color('Finished##ple_d', A, 'done_color')
        w.color('Interrupted##ple_f', A, 'fail_color')
        font_combo(w, 'Font##plf_act', A, 'font', true)
        w.checkbox('Bold##plf_ab', A, 'bold'); imgui.SameLine(); w.checkbox('Italic##plf_ab_it', A, 'italic')
        w.heading('Position')
        offset_rows(w, A, 'action', 0, 0)
        w.heading('Cast progress bar')
        w.checkbox('Show under the current action##ple_bar', A, 'bar', 'A thin line that fills while a member casts.')
        w.when(A.bar, function ()
            w.color('Color##ple_bc', A, 'bar_color')
            w.slider_int('Thickness##ple_bh', A, 'bar_h', 1, 8, '%d px')
        end)
    end)
end

-- 2.7.6: health bars over members' heads
local function tab_over(L, w, hpp)
    local O = L.over
    list_test_head(w, hpp, 'plb_over', 'Show health bars over party members', O, 'enabled', 'A small health bar above each party member in your zone, sized by how far they are from the camera. Only in battle (someone in the party is engaged, or a monster acted on a member). Test shows one over you.')
    -- 2.10.0: per job, always: each job keeps what it last used; a job new to you starts with the last job's settings
    if not SEARCHING then
        local job = hpp.my_job and hpp.my_job() or nil
        imgui.TextDisabled('Saved per job' .. (job and (' (now: ' .. job .. ')') or '') .. ': a job you have not set up starts with the last job\'s settings.')
    end
    w.when(O.enabled, function ()
        if w.group('Display For##g_plo_who', 'list', 'window', true) then
            w.checkbox('Also over you##plo_self', O, 'self')
            w.checkbox('Also over alliance members##plo_ally', O, 'alliance')
            w.radio('Mark the enemy\'s target##plo_ag', O, 'aggro', { 'focus', 'any', 'off' }, { focus = 'Your enemy\'s', any = 'Any monster\'s', off = 'Off' }, 'Marks the member a monster is going after. Your enemy\'s = your enemy and every monster a party member is fighting. Any monster\'s = also everyone any other monster hit or cast on in the last 6 s, fainter.')
            w.when(O.aggro ~= 'off', function ()
                w.radio('Mark##plo_ags', O, 'aggro_style', { 'both', 'arrow', 'outline' }, { both = 'Arrow and outline', arrow = 'Arrow', outline = 'Outline' })
                w.color('Mark color##plo_agc', O, 'aggro_color')
            end)
        end
        if w.group('Bar##g_plo_bar', 'list', 'window', true) then
            w.heading('Look')
            w.checkbox('Look like the HP bar##plo_look', O, 'hp_look', 'Uses the HP tab\'s bar look: finish, border, rounding, damage trail, sheen and comet. Off: a plain bar in the HP colors.')
            w.heading('HP number')
            w.checkbox('HP number on the bar##plo_num', O, 'hp_num', 'The member\'s HP in the HP tab\'s number format and color, scaled with the bar.')
            w.when(O.hp_num, function ()
                w.radio('Shows##plo_nf', O, 'num_fmt', { 'list', 'current', 'percent', 'both' }, { list = 'Like the HP tab', current = '1234', percent = '82%', both = '1234 (82%)' })
                w.slider_float('Number size##plo_ns', O, 'num_scale', 0.3, 3, '%.2fx', 'Times the HP tab\'s number size (and the bar\'s distance scale).')
                w.slider_int('Number left / right##plo_ndx', O, 'num_dx', -100, 100, '%d px', 'From the middle of the bar.')
                w.slider_int('Number down / up##plo_ndy', O, 'num_dy', -100, 100, '%d px', 'Down (-) / up (+).', true)
            end)
            w.heading('Size and position')
            w.checkbox('Mana bar under it##plo_mp', O, 'mp', 'Only for members with a mana pool.')
            w.slider_int('Width##plo_w', O, 'width', 20, 200, '%d px', 'At the "Scales smaller when beyond" distance (Bar Scaling).')
            w.slider_int('Height##plo_h', O, 'height', 2, 20, '%d px')
            w.slider_int('Bar left / right##plo_dx', O, 'dx', -200, 200, '%d px', 'Moves the bar from its spot over the member (at full size; scaled with distance).')
            w.slider_int('Bar down / up##plo_dy', O, 'dy', -200, 200, '%d px', 'Down (-) / up (+).', true)
            w.when(O.mp, w.slider_int, 'Mana bar height##plo_mh', O, 'mp_height', 1, 10, '%d px')
            w.when(not O.hp_look, function ()
                w.slider_int('Rounding##plo_r', O, 'rounding', 0, 10, '%d px')
                w.color('Background##plo_bg', O, 'back')
            end)
            w.slider_float('Opacity##plo_a', O, 'alpha', 0.1, 1, '%.2f')
        end
        if w.group('Bar Scaling##g_plo_where', 'list', 'window', true) then
            -- 2.10.1: always over the head (the fixed height from the feet is gone); clearer size settings
            w.slider_float('Above the head##plo_gap', O, 'head_gap', -1, 3, '%.2f yalms', 'How far above the top of the head the bar sits. It follows each character\'s own height (Taru, Galka, sitting, mounted).')
            w.slider_int('Full size##plo_maxpx', O, 'max_px', 20, 600, '%d px', 'The widest the bar gets, when the member is close to the camera. Never less than the bar\'s Width.')
            w.slider_float('Scales smaller when beyond##plo_ref', O, 'ref', 2, 30, '%.0f yalms', 'Up to this distance from the camera the bar is at least its Width (growing up to Full size when nearer); beyond it the bar shrinks.')
            w.slider_float('Minimum size##plo_min', O, 'min_scale', 0.1, 1, '%.2fx', 'The smallest the bar shrinks to far away, times its Width.')
            w.slider_float('Hide beyond##plo_far', O, 'max_dist', 5, 60, '%.0f yalms', 'Fades out as it gets near this distance from the camera.')
        end
    end)
end

local function tab_bars(L, w, hpp)
    w.sub_tabs('##pl_bar_tabs', {
        { 'HP##plb_t1', function () bar_tab(L, w, hpp, 'hp', 'HP', 'HP Number') end },
        { 'MP##plb_t2', function () bar_tab(L, w, hpp, 'mp', 'MP', 'MP Number') end },
        { 'TP##plb_t3', function () bar_tab(L, w, hpp, 'tp', 'TP', 'TP Number') end },
    })
    if not SEARCHING then imgui.TextDisabled('Current action: Text tab. Health bars over members\' heads: Overhead bars tab.') end
end

-- Images and marks: status effects, job icon, leader / quartermaster marks, list cursor.
local tab_roles
-- Sub-tabs inside a group (all of them while the settings search runs).
local function icon_tabs(list)
    if SEARCHING then for _, t in ipairs(list) do t[2]() end; return end
    if not imgui.BeginTabBar('##pli_stabs') then return end
    local failed
    for _, t in ipairs(list) do
        if require('pxiui').sub_tab_item(t[1]) then
            local ok, e = pcall(t[2])
            imgui.EndTabItem()
            if not ok and failed == nil then failed = e end
        end
    end
    imgui.EndTabBar()
    if failed ~= nil then error(failed, 0) end
end

-- 2.10.1: "By type" order: drag a row (or use the arrows); the top group's effects come first.
local TO = { drag = nil, ys = {} }
local function type_order_list(w, B)
    if SEARCHING then return end
    if type(B.type_order) ~= 'table' then B.type_order = Buffs.fix_order(nil) end
    local order = B.type_order
    if type(B.type_hide) ~= 'table' then B.type_hide = {} end
    imgui.TextDisabled('Drag a type up or down (or use the arrows). Effects of the top type come first. Hide leaves a whole type off the cards.')
    local okm, _, my = pcall(imgui.GetMousePos)
    local okd, down = pcall(imgui.IsMouseDown, 0)
    if not (okd and down) then TO.drag = nil end
    local moved = false
    for i, g in ipairs(order) do
        local okc, _, cy = pcall(imgui.GetCursorScreenPos)
        TO.ys[i] = okc and cy or nil
        if imgui.SmallButton('^##plb_tu' .. i) and i > 1 then order[i], order[i - 1] = order[i - 1], order[i]; moved = true end
        imgui.SameLine()
        if imgui.SmallButton('v##plb_td' .. i) and i < #order then order[i], order[i + 1] = order[i + 1], order[i]; moved = true end
        imgui.SameLine()
        -- 2.10.2: Hide / Show a whole type (only while sorted By type)
        local hid = B.type_hide[g] == true
        if imgui.SmallButton((hid and 'Show' or 'Hide') .. '##plb_th' .. g) then B.type_hide[g] = (not hid) or nil; w.changed() end
        imgui.SameLine()
        imgui.Selectable(('%d. %s%s##plb_to_%s'):format(i, Buffs.GROUP_LABELS[g] or g, hid and '  (hidden)' or '', g), TO.drag == i)
        if TO.drag == nil and imgui.IsItemActive() then TO.drag = i end
    end
    for i = #order + 1, #TO.ys do TO.ys[i] = nil end
    if TO.drag ~= nil and okm and type(my) == 'number' then
        local tgt
        for i = 1, #order do
            local y0 = TO.ys[i]
            local y1 = TO.ys[i + 1] or (y0 and y0 + 22)
            if y0 and my >= y0 and my < y1 then tgt = i end
        end
        if tgt ~= nil and tgt ~= TO.drag then
            local g = table.remove(order, TO.drag)
            table.insert(order, tgt, g)
            TO.drag, moved = tgt, true
        end
    end
    if moved then Buffs.rank_dirty(); w.changed() end
    if imgui.SmallButton('Reset to the default order##plb_tr') then B.type_order = Buffs.fix_order(nil); Buffs.rank_dirty(); w.changed() end
end

local function tab_images(L, w, hpp)
    local B = L.buffs
    local when = w.when
    -- 2.10.1: the status icons' switch and the Test sit at the top; Icon Pack holds every picture (status icons, job icon,
    -- leader marks, pointer), each with its own size and position under its header
    list_test_head(w, hpp, 'plb_buffs', 'Status icons on / off (not the job icon, leader marks or pointer)', B, 'show', 'Your party\'s status effects on their cards. Icons come from the icon pack (shared with the target bar).')
    icon_tabs({
        { 'Icon Pack##pli_s1', function ()
            when(B.show ~= false, function ()
                if w.group('Status Icons##pli_buffs', 'list', 'buffs', true) then
                    if hpp and hpp.ui_fx_packs then hpp.ui_fx_packs(hpp.s.info.fx) end
                    if not SEARCHING then imgui.TextDisabled('Icon pack: shared with Target bar > Icons (changing one changes both).') end
                    w.heading('Icons##pli_s1h', 'list', 'buffs')
                    w.slider_int('Icon size##plb_sz', B, 'size', 15, 72, '%d px')
                    w.slider_int('Per row##plb_pr', B, 'per_row', 1, 32, '%d')
                    w.slider_int('Most shown##plb_max', B, 'max', 1, 32, '%d')
                    w.slider_int('Spacing##plb_gap', B, 'gap', 0, 10, '%d px')
                    w.checkbox('Slide into place##plb_slide', B, 'slide', 'When an effect ends, is replaced or the order changes, the icons glide to their new places and new ones fade in.')
                    w.checkbox('Note when the mouse is on an icon##plb_tip', B, 'tooltip', 'The effect\'s name, its type (enhancing, enfeebling...), and the time left or how long it has been on.')
                    w.checkbox('Flash on beneficial effects##plb_fl', B, 'flash', 'A soft light sweeps across each beneficial effect every 5-10 minutes, every icon on its own random clock (never all at once). Harmful effects do not flash.')
                    w.heading('Position##pli_s3h', 'list', 'buffs')
                    w.checkbox('Fit to the card##plb_fit', B, 'fit', 'The icons sit inside the card under its lowest element and wrap at the card\'s width; the card grows upward smoothly (0.5 s) when another row is needed and shrinks back when effects end. Off: place the icons anywhere (offsets below or drag them with Edit positions).')
                    when(B.fit == true, w.slider_int, 'Space above the icons##plb_fpad', B, 'fit_pad', 0, 25, '%d px', 'The icons start this far under the lowest element of the card (icon, name, job, bars or action, wherever their offsets put them). The card grows upward when another row is needed, so the cards under it stay where they are.')
                    when(B.fit ~= true, offset_rows, w, B, 'buffs', 0, 0)
                end
            end)
            if w.group('Job Icon##pli_icon', 'list', 'icon', true) then
                w.checkbox('Show##plt_icon', L.icon, 'show', 'PNG files named by job (WAR.png, WHM.png...) in addons\\partyramaxi\\icons\\jobs\\. Without one, a colored tile with the job letters is drawn.')
                when(L.icon.show ~= false, function ()
                    w.slider_int('Size##plt_is', L.icon, 'size', 10, 50, '%d px')
                    w.slider_int('Rounding##plt_ir', L.icon, 'rounding', 0, 30, '%d px')
                    w.heading('Position')
                    offset_rows(w, L.icon, 'icon', 0, 0)
                end)
            end
            if w.group('Leader marks##pli_roles', 'list', 'card') then tab_roles(L, w) end
            if w.group('Pointer (list cursor)##pli_ptr', 'list', 'pointer') then
                local P = L.pointer
                w.checkbox('Show the pointer##plp_show', P, 'show', 'The arrow from the Pointer tab, beside the name of the selected / targeted member. It glides between members.')
                when(P.show ~= false, function ()
                    w.slider_int('Size##plp_size', P, 'size', 16, 60, '%d px')
                    w.checkbox('Glide between members##plp_gl', P, 'glide')
                    when(P.glide, w.slider_float, 'Glide speed##plp_gs', P, 'glide_speed', 2, 40, '%.0f')
                    imgui.TextDisabled('Shape and colors: Pointer tab.')
                    w.heading('Position')
                    offset_rows(w, P, 'ptr', -2, 0, 400)
                end)
            end
        end },
        { 'Countdown##pli_s2', function ()
            when(B.show ~= false, function ()
                w.checkbox('Countdown on each icon##plb_tm', B, 'timers', 'Your own effects use the game\'s timers; others\' are known only from spells the addon saw land. Effects with no known duration show no countdown.')
                when(B.timers, function ()
                    w.heading('Graphic')
                    w.radio('Countdown graphic##plb_ring', B, 'ring', Fx.RINGS, Fx.RING_LABELS, 'The same graphics as the target bar\'s effect icons. A ring or bar starts full when the effect lands (or when the addon first sees it) and drains as it runs out.')
                    when(B.ring ~= nil and B.ring ~= 'none', function ()
                        w.color('Color##plb_rcol', B, 'ring_color')
                        when(B.ring == 'ring', function ()
                            w.radio('Ring shape##plb_rshape', B, 'ring_shape', Fx.SHAPES, Fx.SHAPE_LABELS)
                            w.slider_int('Ring width##plb_rw', B, 'ring_width', 1, 6, '%d px')
                            w.slider_int('Gap to the icon##plb_rpad', B, 'ring_pad', 0, 10, '%d px', 'How much larger than the icon the ring is. The icons move apart to make room for it.')
                        end)
                    end)
                    w.heading('Number')
                    w.radio('Number##plb_tp', B, 'timer_pos', TPOS, TPOS_LABELS)
                    when(B.timer_pos ~= 'off', function ()
                        w.radio('Unknown duration##plb_tu', B, 'timer_unknown', TUNK, TUNK_LABELS, 'Effects the addon did not see land (or without a known duration) count UP from when they were first seen, shown as +12, in grey.')
                        font_px(w, B, 'timer_scale', 'btimer', 0.3, 1.2, 'Timer font size')
                        w.color('Number color##plb_tc', B, 'timer_color')
                    end)
                    w.heading('Warning')
                    w.slider_float('Warning at##plb_warn', B, 'warn_secs', 0, 30, '%.0f s', 'When this little time is left the number and ring change color and the icon fades in and out.')
                    when((tonumber(B.warn_secs) or 0) > 0, function ()      -- 0 s = no warning
                        imgui.SameLine(); w.color('##plb_wcol', B, 'warn_color')
                        w.checkbox('Fade the icon in and out during the warning##plb_wfl', B, 'warn_flash')
                    end)
                end)
            end)
        end },
        { 'Sort and pin##pli_s4', function ()
            when(B.show ~= false, function ()
                -- 2.10.1: sort, pins and type order are kept per job, like the bars over members
                if not SEARCHING then
                    local job = hpp.my_job and hpp.my_job() or nil
                    imgui.TextDisabled('Saved per job' .. (job and (' (now: ' .. job .. ')') or '') .. ': sort, pins and type order. A job you have not set up starts with the last job\'s.')
                end
                w.heading('Sort')
                w.combo('Sort##plb_sort', B, 'sort', Buffs.SORTS, Buffs.SORT_LABELS, 'Game order; last applied first; time left (unknown durations last); or by type of magic in your own order (below).')
                when(B.sort == 'type', type_order_list, w, B)
                if type(B.pins) ~= 'table' then B.pins = {} end
                if type(B.pin_mode) ~= 'table' then B.pin_mode = {} end
                w.heading('Pin an effect')
                imgui.TextDisabled('1. Type part of a spell or effect name (e.g. haste, protect, sleep).')
                imgui.TextDisabled('2. Press Pin beside the one you want. It joins Pinned effects below, set to Show.')
                imgui.TextDisabled('3. Below, switch it to Hide or Hide on party only if you would rather not see it.')
                imgui.PushItemWidth(200)
                imgui.InputText('Search spells / effects##plb_pq', PIN_Q, 40)
                imgui.PopItemWidth()
                local q = (PIN_Q[1] or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
                if q ~= '' then
                    local shown, done = 0, {}
                    local function offer(label, id)
                        if shown >= 14 or done[id] then return end
                        for _, pid in ipairs(B.pins) do if pid == id then return end end
                        done[id] = true
                        shown = shown + 1
                        if imgui.SmallButton('Pin##plb_pn' .. shown) then B.pins[#B.pins + 1] = id; w.changed() end
                        imgui.SameLine()
                        imgui.Text(label)
                    end
                    local okn, SN = pcall(require, 'pxispellnames')
                    if okn and SN and SN.list then
                        for _, e in ipairs(SN.list) do
                            if e[1]:lower():find(q, 1, true) then offer(e[1] .. '  (' .. (Fx.name_of and Fx.name_of(e[2]) or e[2]) .. ')', e[2]) end
                        end
                    end
                    local okd, FD = pcall(require, 'pxifxdata')
                    if okd and FD and FD.names then
                        for id, nm in pairs(FD.names) do
                            if type(nm) == 'string' and nm:lower():find(q, 1, true) then offer(nm .. '  #' .. id, id) end
                        end
                    end
                    if shown == 0 then imgui.TextDisabled('(nothing found, or already pinned)') end
                end
                w.heading('Pinned effects')
                imgui.TextDisabled('For each pinned effect pick what it does:')
                imgui.TextDisabled('   Show: drawn first, in this list\'s order, whenever it is on someone.')
                imgui.TextDisabled('   Hide: never drawn on any card.')
                imgui.TextDisabled('   Hide on party only: drawn on your own card, not on the other members\'.')
                imgui.TextDisabled('Up moves it one place, Top makes it first, Remove unpins it.')
                if #B.pins == 0 then imgui.TextDisabled('(nothing pinned yet: search for an effect above and press Pin)') end
                local drop, top
                for i, pid in ipairs(B.pins) do
                    imgui.Text(('%d. %s  #%d'):format(i, Fx.name_of and Fx.name_of(pid) or tostring(pid), pid))
                    local cur = Buffs.pin_mode(B, pid)
                    for _, m in ipairs(Buffs.PIN_MODES) do
                        imgui.SameLine()
                        if imgui.RadioButton(Buffs.PIN_LABELS[m] .. '##plb_pm' .. i .. m, cur == m) and cur ~= m then
                            B.pin_mode['s' .. pid] = (m ~= 'top') and m or nil; w.changed()
                        end
                    end
                    -- 2.10.2: Up, Top (to the head of the list), Remove
                    imgui.SameLine()
                    if imgui.SmallButton('Up##plb_u' .. i) and i > 1 then B.pins[i], B.pins[i - 1] = B.pins[i - 1], B.pins[i]; w.changed() end
                    imgui.SameLine()
                    if imgui.SmallButton('Top##plb_t' .. i) and i > 1 then top = i end
                    imgui.SameLine()
                    if imgui.SmallButton('Remove##plb_x' .. i) then drop = i end
                end
                if top then table.insert(B.pins, 1, table.remove(B.pins, top)); w.changed() end
                if drop then B.pin_mode['s' .. B.pins[drop]] = nil; table.remove(B.pins, drop); w.changed() end
            end)
        end },
        { 'Canceling Effects##pli_s5', function ()
            when(B.show ~= false, function ()
                w.heading('Mouse')
                w.radio('Clicking your effect##plb_cancel', B, 'cancel', Buffs.CANCELS, Buffs.CANCEL_LABELS, 'Like the game: click one of your own effect icons and confirm to cancel it. Some effects cannot be cancelled; the game then ignores it.')
                local In = hpp.input
                when(B.cancel ~= 'off', function ()
                w.heading('Keyboard and controller')
                imgui.TextDisabled('Keyboard: open the cursor with a bound key (e.g. /bind F10 /pxi buffs). Arrow keys move.')
                imgui.TextDisabled('The same key (or Enter) picks the effect; press it again to cancel it. Esc goes back.')
                if In ~= nil and type(B.pad) == 'table' then
                    imgui.TextDisabled('Your own keys or controller buttons: press Learn, then the key or button.')
                    for _, act in ipairs(In.ACTIONS) do
                        local cur = B.pad[act]
                        imgui.Text(('%s: %s'):format(In.LABELS[act], In.label and In.label(cur) or tostring(cur)))
                        imgui.SameLine()
                        if imgui.SmallButton((In.learn == act and 'Press a key or button...' or 'Learn') .. '##plb_pl_' .. act) then In.learn = (In.learn == act) and nil or act end
                        imgui.SameLine()
                        if imgui.SmallButton('Clear##plb_pc_' .. act) then B.pad[act] = ''; w.changed() end
                    end
                    imgui.TextDisabled('Nothing happens on Learn? Type /pxi buffs pad and press it: no chat line = the addon does not see it.')
                end
                end)
            end)
        end },
    })
end

local RSTYLES = { 'crown', 'star', 'coin', 'badge', 'dot', 'strip', 'name', 'none' }
local RSTYLE_LABELS = { crown = 'Crown', star = 'Star', coin = 'Round coin with letter', badge = 'Square badge with letter', dot = 'Plain dot',
                        strip = 'Colored strip on the card edge', name = 'Color the name', none = 'Off' }
local RPLACES = { 'icon', 'name', 'card' }
local RPLACE_LABELS = { icon = 'Icon corner', name = 'After name', card = 'Card corner' }
local ROLES = { { 'Party leader', 'leader' }, { 'Alliance leader', 'aleader' }, { 'Quartermaster', 'qm' } }
tab_roles = function (L, w)
    if not SEARCHING then imgui.TextDisabled('Marks the party leader, alliance leader and quartermaster.') end
    local R = L.roles
    for _, p in ipairs(ROLES) do
        local k, t = p[2], R[p[2]]
        w.heading(p[1] .. '##plr_' .. k)
        do
            w.combo('Style##plr_st' .. k, t, 'style', RSTYLES, RSTYLE_LABELS)
            w.when(t.style ~= 'none', function ()
                w.color('Color##plr_c' .. k, t, 'color')
                w.when(t.style ~= 'strip' and t.style ~= 'name', function ()
                    w.radio('Where##plr_pl' .. k, t, 'place', RPLACES, RPLACE_LABELS)
                    w.slider_int('Size##plr_sz' .. k, t, 'size', 6, 32, '%d px')
                    w.slider_int('Left / right##plr_dx' .. k, t, 'dx', -100, 100, '%d px')
                    w.slider_int('Down / up##plr_dy' .. k, t, 'dy', -100, 100, '%d px', 'Down (-) / up (+).', true)
                end)
            end)
        end
    end
end

local PETSCOPES = { 'me', 'party', 'all' }
local PETSCOPE_LABELS = { me = 'Only mine', party = 'Party', all = 'Party and alliance' }
tab_pets = function (L, w)
    local P = L.pets
    if not w.group('Pets and summons##g_pl_pets', 'list', 'pet', true) then return end
    w.checkbox('Show pets and summons##plpt_show', P, 'show', 'Avatars, wyverns, automatons, jug pets, charmed mobs: a small panel with the owner.')
    w.when(P.show, function ()
        w.radio('Which members##plpt_scope', P, 'scope', PETSCOPES, PETSCOPE_LABELS)
        local wp = P.dock ~= false
        w.checkbox('Pets docked to the party list##plpt_dock', P, 'dock', 'Off: pets and summons get their own window ("Pets" section style). Untick Lock position to drag it.')
        undock_place(L, false, wp)
        w.when(P.dock ~= false, w.radio, 'Pets are placed##plpt_mode', P, 'mode', PETMODES, PETMODE_LABELS, 'Under their owner\'s card, or together in a "Pets" section at the end of the list.')
        font_px(w, P, 'scale', 'pets', 0.5, 1.5)
        w.slider_int('Bar height##plpt_bh', P, 'bar_h', 3, 20, '%d px')
        w.when(P.mode == 'attached' and P.dock ~= false, function ()
            w.slider_int('Indent##plpt_in', P, 'indent', 0, 60, '%d px')
            w.checkbox('Connector line##plpt_cn', P, 'connector')
            w.checkbox('Show the owner\'s name##plpt_so', P, 'show_owner')
        end)
        w.checkbox('Pet icon before the name##plpt_gl', P, 'glyph')
        w.checkbox('Mana and TP lines (your own pet)##plpt_mt', P, 'mptp', 'The game only reports these for your own pet.')
    end)
end

local IMODES = { 'banner', 'icon', 'off' }
local IMODE_LABELS = { banner = 'Banner, then "!"', icon = '"!" only', off = 'Off' }
tab_motion = function (L, w, hpp)
    if w.group('Party Invite Flag##plm_i', 'list', 'window', true) then
        local I = L.invite
        if not SEARCHING and imgui.Button('Test invite##plm_ti') then
            PL.broken = false
            if not L.enabled then hpp.list_test = true end
            PL.test_invite(hpp.clock())
        end
        w.tip('Shows an invite from "Altair"; it ends by itself after a few seconds.')
        w.radio('Style##plm_im', I, 'mode', IMODES, IMODE_LABELS)
        w.when(I.mode ~= 'off', function ()
            w.when(I.mode == 'banner', function ()
                w.slider_int('Banner stays for##plm_ib', I, 'banner', 5, 120, '%d s', 'Then it shrinks into the badge.')
                font_px(w, I, 'text_scale', 'plm_ifs', 0.4, 3, 'Banner font size')
            end)
            w.slider_int('Size##plm_is', I, 'size', 12, 48, '%d px')
            w.color('Color##plm_ic', I, 'color')
            w.color('Text / "!" color##plm_it', I, 'text_color')
            w.checkbox('Pulse ring##plm_ip', I, 'pulse')
            w.slider_int('Badge left / right##plm_dx', I, 'dx', -200, 200, '%d px')
            w.slider_int('Badge down / up##plm_dy', I, 'dy', -200, 200, '%d px', 'Down (-) / up (+).', true)
            local TO = { m = math.max(1, math.min(30, math.floor((tonumber(I.timeout) or 120) / 60 + 0.5))) }
            local was = TO.m
            w.slider_int('"!" gives up after##plm_to', TO, 'm', 1, 30, '%d min', 'Hides the badge if nothing tells us the invite ended.')
            if TO.m ~= was then I.timeout = TO.m * 60 end
        end)
    end
end

-- 2.7.0: Alliance: the alliance cards' own font sizes, icon and bar sizes and offsets.
local tab_ally_body
local function tab_ally(L, w)
    -- 2.13.0: everything about the alliance in one place; the switch first
    if w.group('Show the alliance##pla_show', 'list', 'window', true) then
        w.checkbox('Show alliance members##pl_ally', L, 'alliance', 'Alliance 1 and 2, under the party.')
        w.when(L.alliance, function ()
            w.checkbox('Alliance as one-line cards##pl_ac', L, 'alliance_compact', 'Name and a health bar only.')
            local wa = L.ally_dock ~= false
            w.checkbox('Alliance docked to the party list##pl_adock', L, 'ally_dock', 'Off: the alliance cards get their own window. Untick General > Lock position to drag it.')
            undock_place(L, wa, false)
        end)
    end
    w.when(L.alliance, tab_ally_body, L, w)
end
tab_ally_body = function (L, w)
    local AL = L.ally_look
    if w.group('Alliance cards##pla_g', 'list', 'card', true) then
        local was = AL.on
        w.checkbox('Alliance cards have their own sizes and offsets##pla_on', AL, 'on', 'Off: alliance cards use the party\'s settings. On: everything below applies to alliance cards only (starting from the party\'s values). Card width and height: Appearance > Cards.')
        if AL.on and not was and not AL.copied then PL.ally_copy(L); AL.copied = true; w.changed() end
        if AL.on and not SEARCHING and imgui.Button('Copy the party\'s values again##pla_copy') then PL.ally_copy(L); w.changed() end
        if L.alliance_compact and not SEARCHING then imgui.TextDisabled('Alliance as one-line cards is on (above): only the name and health bar are shown.') end
    end
    local compact = L.alliance_compact == true
    local function el_rows(id, t, lim)
        w.slider_int('Left / right##pla_' .. id .. '_dx', t, 'dx', -lim, lim, '%d px', 'Left (-) / right (+).')
        w.slider_int('Down / up##pla_' .. id .. '_dy', t, 'dy', -lim, lim, '%d px', 'Down (-) / up (+).', true)
    end
    w.when(AL.on, function ()
        w.when(L.name.show ~= false, function ()
            if w.group('Player Name##pla_name', 'list', 'name') then
                font_px(w, AL.name, 'scale', 'pla_name', 0.6, 2)
                el_rows('name', AL.name, 600)
            end
        end)
        w.when(not compact, function ()
            w.when(L.job.show ~= false and L.job.format ~= 'none', function ()
                if w.group('Job Title##pla_job', 'list', 'job') then
                    font_px(w, AL.job, 'scale', 'pla_job', 0.5, 1.6)
                    el_rows('job', AL.job, 600)
                end
            end)
            w.when(L.icon.show ~= false, function ()
                if w.group('Job icon##pla_icon', 'list', 'icon') then
                    w.slider_int('Size##pla_is', AL.icon, 'size', 10, 50, '%d px')
                    el_rows('icon', AL.icon, 600)
                end
            end)
        end)
        for _, k in ipairs({ { 'hp', 'HP Bar' }, { 'mp', 'MP Bar' }, { 'tp', 'TP Bar' } }) do
            local key, B = k[1], AL[k[1]]
            local PB = L[key]
            w.when((key == 'hp' or not compact) and (PB.show ~= false or (key == 'tp' and PB.text ~= 'none')), function ()
                if w.group(k[2] .. '##pla_' .. key, 'list', key) then
                    w.when(PB.show ~= false, function ()
                        w.slider_int('Height##pla_h' .. key, B, 'height', 3, 40, '%d px')
                        w.when(PB.auto_len == false, w.slider_int, 'Length##pla_len' .. key, B, 'length', 10, 500, '%d px')
                        el_rows(key, B, 600)
                    end)
                    w.when(PB.text ~= 'none', function ()
                        font_px(w, B, 'text_scale', 'pla_n' .. key, 0.4, 1.6, 'Number font size')
                        w.slider_int('Number left / right##pla_tdx' .. key, B, 'text_dx', -300, 300, '%d px')
                        w.slider_int('Number down / up##pla_tdy' .. key, B, 'text_dy', -100, 100, '%d px', 'Down (-) / up (+).', true)
                    end)
                end
            end)
        end
        w.when(not compact and L.action.show ~= false, function ()
            if w.group('Current Action##pla_act', 'list', 'action') then
                font_px(w, AL.action, 'scale', 'pla_act', 0.5, 1.6)
                el_rows('act', AL.action, 600)
            end
        end)
    end)
end

-- Called by the settings window's search: draws every matching setting of the party list tabs.
-- Linked card widths: alliance follows the party width; the pet card keeps its offset (its indent under the owner).
function M.link_widths(C, old)
    local pw = tonumber(C.party.w) or 248
    local d = (tonumber(C.pet.w) or pw) - (old or pw)
    C.alliance.w = pw
    C.pet.w = math.max(60, math.min(800, pw + d))
end

function M.search_all(s, w, hpp)
    local L = s.list
    CUR_L = L
    W_SKIP = w.skip
    W_DIS = w.dis
    w.tab_head('Party list', 'pl')         -- names the search headings "Party list > ..."
    SEARCHING = true
    local fails
    local list = {
        { tab_general, L, w, hpp }, { tab_style, L, w, hpp }, { tab_text, L, w }, { tab_bars, L, w, hpp }, { tab_over, L, w, hpp }, { tab_images, L, w, hpp }, { tab_ally, L, w },
    }
    for _, e in ipairs(list) do
        local okc, err = pcall(unpack(e))
        if not okc and not fails then fails = err end
    end
    SEARCHING = false
    if fails then error(fails, 0) end
end

function M.draw(s, w, hpp)
    local L = s.list
    CUR_L = L
    W_DIS = w.dis
    local on = hpp.list_test == true
    local act = w.tab_head('Party list', 'pl', L.enabled == true, 'Show the party list.',
        on, 'Shows a sample party and alliance until you press this again or close this window.')
    if act == 'enable' then
        L.enabled = not L.enabled
        if L.enabled then PL.broken = false end
        w.changed()
    elseif act == 'test' then
        hpp.list_test = not on; if hpp.list_test then PL.broken = false else hpp.list_test_anim, hpp.list_test_hl = false, false end
    end
    imgui.SameLine()
    local ed = hpp.list_edit == true
    -- 2.9.0: amber-yellow (deep orange while editing) with black text, so it stands apart from the blue Test buttons
    imgui.PushStyleColor(ImGuiCol_Button, ed and { 0.96, 0.42, 0.04, 1 } or { 0.98, 0.76, 0.08, 1 })
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, ed and { 1.00, 0.55, 0.15, 1 } or { 1.00, 0.85, 0.30, 1 })
    imgui.PushStyleColor(ImGuiCol_ButtonActive, ed and { 0.85, 0.36, 0.02, 1 } or { 0.90, 0.66, 0.04, 1 })
    local tc = rawget(_G, 'ImGuiCol_Text')
    if tc ~= nil then imgui.PushStyleColor(tc, { 0, 0, 0, 1 }) end
    if imgui.Button((ed and 'Done editing##pl_edit' or 'Edit positions##pl_edit')) then
        hpp.list_edit = not ed
        if hpp.list_edit then PL.broken = false; if not L.enabled then hpp.list_test = true end end
    end
    imgui.PopStyleColor(tc ~= nil and 4 or 3)
    w.tip('Move elements with the mouse: drag any name, bar, icon, effect row or title in the list. A mark shows the point it is aligned to.')
    if hpp.list_edit then
        PL.edit_until = hpp.clock() + 0.3
        -- 2.13.2: how editing works, right under the button
        imgui.TextColored({ 1, 0.8, 0.3, 1 }, 'Drag any name, bar, icon, effect row or title on the list to move it.')
        imgui.TextColored({ 1, 0.8, 0.3, 1 }, 'To fine-tune, use the Left / right and Down / up settings under Position in its group.')
    end
    if PL.broken then imgui.TextColored({ 1, 0.4, 0.4, 1 }, 'The list turned itself off after an error. Press Enabled twice to retry.') end

    if not imgui.BeginTabBar('##pl_tabs') then return end
    local failed
    local function tab(label, fn, ...)
        if require('pxiui').sub_tab_item(label) then
            local ok, e = pcall(fn, ...)
            imgui.EndTabItem()
            if not ok and failed == nil then failed = e end
        end
    end
    tab('General##pl_t1', tab_general, L, w, hpp)
    tab('Appearance##pl_t2', tab_style, L, w, hpp)
    tab('Text##pl_t4', tab_text, L, w)
    tab('Bars##pl_t5', tab_bars, L, w, hpp)
    tab('Overhead bars##pl_t7', tab_over, L, w, hpp)
    tab('Icons##pl_t6', tab_images, L, w, hpp)
    tab('Alliance##pl_t8', tab_ally, L, w)
    imgui.EndTabBar()
    if failed ~= nil then error(failed, 0) end
end

return M
