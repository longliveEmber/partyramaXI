--[[
* PartyramaXI - in-game settings window (/pxi config).
* Every change applies at once and is saved for this character half a second later.
--]]
local real_imgui = require('imgui')
local M                      -- the module table (below); declared here so the search helpers below can see it
local SEARCHING = false
local SEARCH = { '' }
local NOP = function () end
-- While the settings search is on, headings, texts, buttons are dropped and combos are filtered: only matching settings remain.
local OVR = {
    Text = NOP, TextDisabled = NOP, TextWrapped = NOP, TextColored = NOP, Separator = NOP, SameLine = NOP,
    CollapsingHeader = function () return true end,
    Button = function () return false end, SmallButton = function () return false end, TreeNode = function () return false end,
    BeginCombo = function (label, prev)
        if M.skip and M.skip(label) then return false end
        return real_imgui.BeginCombo(label, prev)
    end,
}
-- 2.9.0: settings that do not apply with the current choices are drawn greyed out (when(cond, fn)). DIS counts the
-- open greyed blocks; while it is above 0 no widget changes a setting, also on an Ashita without BeginDisabled.
local DIS = 0
local function no(...) return false end
local DOV = {
    Button = function (...) real_imgui.Button(...); return false end,
    SmallButton = function (...) real_imgui.SmallButton(...); return false end,
    Selectable = no, InputText = no, RadioButton = function (...) real_imgui.RadioButton(...); return false end,
    BeginCombo = function (...) if real_imgui.BeginCombo(...) then real_imgui.EndCombo() end return false end,
}
local imgui = setmetatable({}, { __index = function (_, k)
    if SEARCHING and OVR[k] then return OVR[k] end
    if DIS > 0 and DOV[k] then return DOV[k] end
    return real_imgui[k]
end })
local function dis_begin()
    DIS = DIS + 1
    local f = real_imgui.BeginDisabled
    if type(f) == 'function' and pcall(f, true) then return 'bd' end
    local sv = rawget(_G, 'ImGuiStyleVar_Alpha')
    if sv ~= nil and type(real_imgui.PushStyleVar) == 'function' and pcall(real_imgui.PushStyleVar, sv, 0.45) then return 'sv' end
    return nil
end
local function dis_end(k)
    DIS = DIS - 1
    if k == 'bd' then real_imgui.EndDisabled() elseif k == 'sv' then real_imgui.PopStyleVar() end
end
-- Draws fn's settings, greyed out and locked when on is false.
local function when(on, fn, ...)
    if on then return fn(...) end
    local k = dis_begin()
    local ok, e = pcall(fn, ...)
    dis_end(k)
    if not ok then error(e, 0) end
end
local Win   = require('pxiwin')
local Draw  = require('pxidraw')
local Png   = require('pxipng')
local Info  = require('pxiinfo')
local Fonts = require('pxifonts')
local Fx    = require('pxifx')
local Weak  = require('pxiweak')
local Mob   = require('pximob')

M = { open = { false }, reset_armed_until = 0 }
local hpp

function M.init(h) hpp = h; h.ui_fx_packs = function (F) M.fx_packs(F) end end
function M.toggle() M.open[1] = not M.open[1] end
function M.is_open() return M.open[1] end

local function tip(text) if real_imgui.IsItemHovered() then real_imgui.SetTooltip(text) end end
local function changed() hpp.changed() end

-- Groups: every setting sits in a colored group named after the screen element it changes (mod = 'arrow' | 'info' |
-- 'list', el = element key, '*' = the whole module, nil = nothing of ours on screen). Hovering a setting or its group
-- header frames that element on screen (pxidraw.lua hl_*). During a search the group header becomes a colored
-- "Tab > Group" heading above the group's first match.
local GCOLS = {}
for i, c in ipairs({ { 0.22, 0.40, 0.66 }, { 0.16, 0.50, 0.42 }, { 0.58, 0.40, 0.14 }, { 0.46, 0.28, 0.58 }, { 0.60, 0.24, 0.28 }, { 0.26, 0.48, 0.22 } }) do
    GCOLS[i] = {
        h  = { c[1], c[2], c[3], 0.80 },
        hh = { c[1] * 1.25, c[2] * 1.25, c[3] * 1.25, 0.90 },
        ha = { c[1] * 1.40, c[2] * 1.40, c[3] * 1.40, 1.00 },
        text = { math.min(1, c[1] + 0.45), math.min(1, c[2] + 0.45), math.min(1, c[3] + 0.45), 1 },
    }
end
local HOT = { h = { 0.78, 0.55, 0.10, 0.85 }, hh = { 0.88, 0.62, 0.12, 0.95 }, ha = { 0.92, 0.66, 0.14, 1 }, text = { 1, 0.8, 0.3, 1 } }
local G = { tab = '', title = nil, mod = nil, el = nil, n = 0, ng = 0, shown = false, col = GCOLS[1] }
-- 2.10.1: Expand all / Collapse all: true / false opens / closes every collapsing header drawn for the rest of the frame
local FOLD = nil
local function fold_next()
    local fn = FOLD ~= nil and (real_imgui.SetNextItemOpen or real_imgui.SetNextTreeNodeOpen)
    if fn then pcall(fn, FOLD) end
end
M.fold_next = fold_next

-- The last widget is hovered: point at its element on screen.
local function mark()
    if G.el ~= nil and real_imgui.IsItemHovered() then Draw.hl_set(G.mod, G.el, hpp.now or 0) end
end

-- Settings search: while FILTER is set, widgets whose label / help text do not contain it draw nothing.
local FILTER, HITS = '', 0
function M.set_filter(q) FILTER = (q or ''):lower(); HITS = 0 end
function M.hits() return HITS end
local function skip(label, help)
    if FILTER == '' then return false end
    local hay = (tostring(label):gsub('##.*$', '') .. ' ' .. tostring(help or '') .. ' ' .. (G.title or '')):lower()
    if hay:find(FILTER, 1, true) then
        HITS = HITS + 1
        if G.title ~= nil and not G.shown then
            G.shown = true
            real_imgui.TextColored(G.col.text, G.tab .. '  >  ' .. G.title)
        end
        return false
    end
    return true
end
M.skip = skip

-- 2.13.0: key settings. The few settings a module depends on get a gold star and gold text (a key group: a gold
-- header); the module's box lists them with buttons that open their tab, scroll to them and frame them for a moment.
local GOLD = { 1, 0.80, 0.28, 1 }
local KEY = {}          -- label id (the part after ##), or a plain text / header label -> true
M.KEY = KEY
-- per module: { shown name, tab path (visible tab names, outer first), widget id, group id }
M.KEYS = {
    hide    = { { 'Game windows', {}, 'win_party', 'g_hide_win' } },
    pointer = { { 'Position', {}, 'arrow_mode', 'g_ar_where' }, { 'Shape', {}, 'arrow_style', 'g_ar_shape' }, { 'Size', {}, 'arrow_size', 'g_ar_shape' } },
    list    = { { 'Theme', { 'Appearance' }, 'pl_theme', 'g_pl_theme' }, { 'Card width', { 'Appearance' }, 'plz_w', 'pl_cards' },
                { 'List font', { 'Text' }, 'plf_base', 'plt_shared' }, { 'Lock position', { 'General' }, 'pl_lock', 'g_pl_gap' },
                { 'Show alliance', { 'Alliance' }, 'pl_ally', 'pla_show' } },
    enemy   = { { 'Show bar for', { 'General' }, 'info_k_mob', 'g_inf_who' }, { 'Docked', { 'General' }, 'info_dock', 'g_inf_dock' },
                { 'Fade in', { 'General' }, 'info_fade_in', 'g_inf_fade' } },
    recast  = { { 'Where', { 'General' }, 'rx_attach', 'g_rx_place' }, { 'Hide when not in battle', { 'General' }, 'hide_no_combat', 'sec_show' },
                { 'When nothing is on recast', { 'General' }, 'When nothing is on recast:', 'sec_show' },
                { 'Theme', { 'Appearance' }, 'sec_theme', 'sec_theme' }, { 'Show icons', { 'Icons' }, 'rx_show_icons', 'sec_icons' } },
}
for _, list in pairs(M.KEYS) do for _, k in ipairs(list) do KEY[k[3]] = true; KEY[k[4]] = true end end
for _, n in ipairs({ 'win_alliance1', 'win_alliance2', 'win_target', 'win_castinfo', 'info_k_pc', 'info_k_npc', 'arrow_size' }) do KEY[n] = true end
KEY['g_ar_shape'], KEY['plt_shared'], KEY['pl_cards'], KEY['g_pl_gap'] = nil, nil, nil, nil     -- only the setting there is key
-- a jump in progress: { mod, path, id, group, idx (tab path step this frame), sel (frames left to force the tabs),
-- scrolled, flash (until) }
local JUMP = nil
local function now() return (hpp and hpp.now) or 0 end
local function cursor()
    local ok, x, y = pcall(real_imgui.GetCursorScreenPos)
    if not ok then return nil end
    if type(x) == 'table' then x, y = x.x or x[1], x.y or x[2] end
    return tonumber(x), tonumber(y)
end
local function star(dl, cx, cy, R, col)
    local o, i = {}, {}
    for k = 0, 4 do
        local a = -math.pi / 2 + k * 2 * math.pi / 5
        o[k] = { cx + R * math.cos(a), cy + R * math.sin(a) }
        local b = a + math.pi / 5
        i[k] = { cx + R * 0.45 * math.cos(b), cy + R * 0.45 * math.sin(b) }
    end
    local c = { cx, cy }
    for k = 0, 4 do
        local pk = i[(k + 4) % 5]
        pcall(dl.AddTriangleFilled, dl, pk, o[k], i[k], col)      -- the point
        pcall(dl.AddTriangleFilled, dl, c, pk, i[k], col)         -- the middle
    end
end
local function key_id(label)
    label = tostring(label)
    return label:match('##(.*)$') or label
end
-- Before a key widget: its star (a fixed-width gap so the column stays aligned) and gold text. Returns a token or nil.
local function key_pre(label)
    local id = key_id(label)
    if not KEY[id] then return nil end
    local imgui = real_imgui
    local x, y = cursor()
    local okf, fh = pcall(imgui.GetFontSize); fh = (okf and tonumber(fh)) or 13
    local okw, ww = pcall(imgui.GetContentRegionAvail)
    if okw and type(ww) == 'table' then ww = ww.x or ww[1] end
    imgui.Dummy({ 13, fh })
    imgui.SameLine(0, 3)
    if x ~= nil then star(imgui.GetWindowDrawList(), x + 6, y + fh / 2 + 3, 6, Draw.u32(GOLD)) end
    local okc = pcall(imgui.PushStyleColor, ImGuiCol_Text, GOLD)
    return { id = id, x = x, y = y, h = fh, w = tonumber(ww) or 300, pop = okc }
end
-- After it: the gold text ends; the target of a jump is scrolled to and framed.
local function key_post(k)
    if k == nil then return end
    if k.pop then real_imgui.PopStyleColor(1) end
    local J = JUMP
    if J ~= nil and J.id == k.id then
        if not J.scrolled and real_imgui.SetScrollHereY then pcall(real_imgui.SetScrollHereY, 0.3); J.scrolled = true end
        if now() < (J.flash or 0) and k.x ~= nil then
            local a = 0.5 + 0.5 * math.abs(math.sin(now() * 6))
            pcall(function ()
                real_imgui.GetWindowDrawList():AddRect({ k.x - 3, k.y - 3 }, { k.x + k.w, k.y + k.h + 9 }, Draw.u32({ 1, 0.8, 0.28, a }), 4, 0, 2)
            end)
        end
    end
end
M.key_pre, M.key_post = key_pre, key_post
-- A tab item on a jump's path is forced open for a few frames (outer tabs first).
local function jump_tab(label)
    local J = JUMP
    if J == nil or (J.sel or 0) <= 0 then return false end
    local name = tostring(label):gsub('##.*$', '')
    if J.path[J.idx] == name then J.idx = J.idx + 1; return true end
    return false
end
local SEL_OPEN = { true }
local function tab_item_sel(label)
    local f = rawget(_G, 'ImGuiTabItemFlags_SetSelected') or 2
    local ok, r = pcall(real_imgui.BeginTabItem, label, nil, f)
    if ok then return r end
    SEL_OPEN[1] = true
    return real_imgui.BeginTabItem(label, SEL_OPEN, f)
end
function M.jump(mod, k)
    M.mod = mod
    JUMP = { mod = mod, path = k[2], id = k[3], group = k[4], idx = 1, sel = 4, scrolled = false, flash = now() + 2.0 }
end

-- A group: a colored collapsing header. Neighbouring groups get different colors. col = HOT forces amber.
local function group(label, mod, el, open, col)
    G.n = G.n + 1
    local gid = key_id(label)
    local c = col or (KEY[gid] and HOT) or GCOLS[(G.n - 1) % #GCOLS + 1]      -- 2.13.0: a key group's header is gold
    G.title, G.mod, G.el, G.shown, G.col = (label:gsub('##.*$', '')), mod, el, false, c
    G.gtitle = G.title
    if SEARCHING then return true end
    local imgui = real_imgui
    G.ng = G.ng + 1
    if G.ng == 1 and DIS == 0 then
        -- 2.10.1: the tab's first collapsing header gets the Expand / Collapse all buttons above it, with room under
        -- the Enabled / Test buttons
        imgui.Dummy({ 0, 8 })
        if imgui.SmallButton('Expand all##hpp_fold_o') then FOLD = true end
        imgui.SameLine()
        if imgui.SmallButton('Collapse all##hpp_fold_c') then FOLD = false end
    end
    imgui.Dummy({ 0, 6 })        -- 2.10.1: more room between headers
    imgui.PushStyleColor(ImGuiCol_Header, c.h)
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, c.hh)
    imgui.PushStyleColor(ImGuiCol_HeaderActive, c.ha)
    fold_next()
    if JUMP ~= nil and JUMP.group == gid and not JUMP.opened then      -- a jump opens the group it goes to
        local fn = real_imgui.SetNextItemOpen or real_imgui.SetNextTreeNodeOpen
        if fn then pcall(fn, true) end
        JUMP.opened = true
    end
    local o = imgui.CollapsingHeader(label, open and ImGuiTreeNodeFlags_DefaultOpen or 0)
    imgui.PopStyleColor(3)
    mark()
    if JUMP ~= nil and JUMP.id == gid and not JUMP.scrolled and real_imgui.SetScrollHereY then pcall(real_imgui.SetScrollHereY, 0.2); JUMP.scrolled = true end
    return o
end

-- 2.9.0: a plain colored heading (no collapsing): the settings under it are always open. 2.10.2: with a line in its
-- color under it, used throughout to name the settings that follow (Icon Pack, Icon, Position...). mod / el: what it
-- frames on screen (default: the group's).
local function heading(label, mod, el)
    G.n = G.n + 1
    local c = GCOLS[(G.n - 1) % #GCOLS + 1]
    local name = label:gsub('##.*$', '')
    G.title = (G.gtitle and G.gtitle ~= name) and (G.gtitle .. '  >  ' .. name) or name
    G.mod, G.el, G.shown, G.col = mod or G.mod, el or G.el, false, c
    if SEARCHING then return end
    local imgui = real_imgui
    imgui.Dummy({ 0, 4 })
    imgui.TextColored(c.text, name)
    local sep = rawget(_G, 'ImGuiCol_Separator')
    local ok = type(sep) == 'number' and pcall(imgui.PushStyleColor, sep, { c.text[1], c.text[2], c.text[3], 0.55 })
    imgui.Separator()
    if ok then imgui.PopStyleColor() end
    mark()
end

-- Colored buttons at the top of every tab: Enable (green on / red off) and Test (blue, amber while running,
-- grey when the tab has nothing to preview).
local OWN_COLORS = false          -- 1.0.1: set while a button with its own colors is drawn (no styling by kind)
local BTN = {
    on      = { { 0.18, 0.42, 0.25, 1 }, { 0.23, 0.52, 0.31, 1 }, { 0.15, 0.36, 0.21, 1 } },     -- 1.0.1: mockup colors
    off     = { { 0.48, 0.18, 0.20, 1 }, { 0.59, 0.23, 0.25, 1 }, { 0.39, 0.14, 0.16, 1 } },
    test    = { { 0.18, 0.30, 0.50, 1 }, { 0.24, 0.39, 0.65, 1 }, { 0.15, 0.24, 0.41, 1 } },
    testing = { { 0.78, 0.55, 0.10, 1 }, { 0.88, 0.62, 0.12, 1 }, { 0.70, 0.48, 0.08, 1 } },
    none    = { { 0.30, 0.30, 0.32, 1 }, { 0.30, 0.30, 0.32, 1 }, { 0.30, 0.30, 0.32, 1 } },
}
local BTN_SIZE = { 96, 0 }
local BTN_MOD = { 132, 28 }      -- 2.13.0: the module's own switch is bigger than a tab's
local function colored_button(label, set, size)
    local imgui = real_imgui
    imgui.PushStyleColor(ImGuiCol_Button, set[1])
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, set[2])
    imgui.PushStyleColor(ImGuiCol_ButtonActive, set[3])
    OWN_COLORS = true
    local ok, r = pcall(imgui.Button, label, size or BTN_SIZE)
    OWN_COLORS = false
    imgui.PopStyleColor(3)
    if not ok then error(r, 0) end
    return r
end
-- Returns 'enable' or 'test' when one was pressed. test_on = nil: the tab has no test (grey button, tooltip says why).
function M.tab_head(name, id, on, en_help, test_on, test_help)
    G.tab, G.n, G.ng, G.title, G.mod, G.el = name, 0, 0, nil, nil, nil
    G.gtitle = nil
    if SEARCHING then return nil end
    local imgui = real_imgui
    local act = nil
    if colored_button((on and 'Module: Enabled' or 'Module: Disabled') .. '##hpp_en_' .. id, on and BTN.on or BTN.off, BTN_MOD) then act = 'enable' end
    tip(en_help)
    if test_on == 'none' then return act end            -- 2.6: this tab has no Test button at all
    imgui.SameLine()
    if test_on == nil then
        colored_button('Test##hpp_ts_' .. id, BTN.none, BTN_MOD)
    elseif colored_button((test_on and 'Stop test' or 'Test') .. '##hpp_ts_' .. id, test_on and BTN.testing or BTN.test, BTN_MOD) then
        act = 'test'
    end
    tip(test_help)
    return act
end

local function checkbox(label, tbl, key, help)
    local imgui = real_imgui
    if skip(label, help) then return end
    local v = { tbl[key] == true }
    local k = key_pre(label)
    if imgui.Checkbox(label, v) and DIS == 0 then tbl[key] = v[1]; changed() end
    key_post(k)
    mark()
    if help then tip(help) end
end

-- A slider with a - and a + button after it. The label's visible part goes after the buttons.
local function stepper_layout(label)
    local imgui = real_imgui
    local shown, id = label:match('^(.-)##(.*)$')
    if shown == nil then shown, id = label, label end
    local ok, w = pcall(imgui.CalcItemWidth)
    w = (ok and tonumber(w)) or 200
    return shown, id, math.max(60, w - 52)
end

-- up = true: a vertical offset shown the way the screen reads it (+ moves up, - moves down); the setting itself keeps
-- screen coordinates (+ = down), so nothing saved changes meaning.
local function slider_int(label, tbl, key, lo, hi, fmt, help, up)
    local imgui = real_imgui
    if skip(label, help) then return end
    local shown, id, w = stepper_layout(label)
    local kk = key_pre(label)
    local cur = math.floor(tonumber(tbl[key]) or lo)
    local sg = up and -1 or 1
    local v = { cur * sg }
    imgui.PushItemWidth(w)
    local used = imgui.SliderInt('##' .. id, v, up and -hi or lo, up and -lo or hi, fmt or '%d')
    imgui.PopItemWidth()
    if used and DIS == 0 then tbl[key] = math.max(lo, math.min(hi, v[1] * sg)); changed() end
    mark()
    if help then tip(help) end
    imgui.SameLine(0, 4)
    if imgui.SmallButton('-##m_' .. id) and DIS == 0 then tbl[key] = math.max(lo, math.min(hi, cur - sg)); changed() end
    imgui.SameLine(0, 2)
    if imgui.SmallButton('+##p_' .. id) and DIS == 0 then tbl[key] = math.max(lo, math.min(hi, cur + sg)); changed() end
    if shown ~= '' then imgui.SameLine(0, 6); imgui.Text(shown) end
    key_post(kk)
end

local function slider_float(label, tbl, key, lo, hi, fmt, help)
    local imgui = real_imgui
    if skip(label, help) then return end
    local shown, id, w = stepper_layout(label)
    local kk = key_pre(label)
    local cur = tonumber(tbl[key]) or lo
    local v = { cur }
    imgui.PushItemWidth(w)
    local used = imgui.SliderFloat('##' .. id, v, lo, hi, fmt or '%.2f')
    imgui.PopItemWidth()
    if used and DIS == 0 then tbl[key] = math.max(lo, math.min(hi, v[1])); changed() end
    mark()
    if help then tip(help) end
    -- one step = the last digit shown: %.0f -> 1, %.1f -> 0.1, %.2f -> 0.01
    local dec = tonumber((fmt or '%.2f'):match('%%%.(%d)f')) or 2
    local scale = 10 ^ dec
    local step = 1 / scale
    imgui.SameLine(0, 4)
    if imgui.SmallButton('-##m_' .. id) and DIS == 0 then tbl[key] = math.max(lo, math.floor((cur - step) * scale + 0.5) / scale); changed() end
    imgui.SameLine(0, 2)
    if imgui.SmallButton('+##p_' .. id) and DIS == 0 then tbl[key] = math.min(hi, math.floor((cur + step) * scale + 0.5) / scale); changed() end
    if shown ~= '' then imgui.SameLine(0, 6); imgui.Text(shown) end
    key_post(kk)
end

local function color(label, tbl, key, help)
    local imgui = real_imgui
    if skip(label, help) then return end
    local c = tbl[key]
    local v = { c[1], c[2], c[3], c[4] }
    if imgui.ColorEdit4(label, v, bit.bor(ImGuiColorEditFlags_NoInputs, ImGuiColorEditFlags_AlphaBar)) and DIS == 0 then
        c[1], c[2], c[3], c[4] = v[1], v[2], v[3], v[4]; changed()
    end
    mark()
    if help then tip(help) end
end

local function dropdown(label, tbl, key, values, labels, help)
    local imgui = real_imgui
    if skip(label, help) then return end
    local cur = tbl[key]
    local kk = key_pre(label)
    local open = imgui.BeginCombo(label, labels[cur] or tostring(cur))
    key_post(kk)
    if open then
        for _, v in ipairs(values) do
            if imgui.Selectable(labels[v], v == cur) and DIS == 0 then tbl[key] = v; changed() end
        end
        imgui.EndCombo()
    end
    mark()
    if help then tip(help) end
end

-- Radio buttons: the caption, then one button per value. Short labels share one row; long ones get a row each.
local function radio(label, tbl, key, values, labels, help)
    local imgui = real_imgui
    if skip(label, help) then return end
    local cur = tbl[key]
    local cap = label:gsub('##.*$', '')
    local len = 0
    for _, v in ipairs(values) do len = len + #tostring(labels[v] or v) end
    local rows = len > 44
    local kk = key_pre(label)
    imgui.Text(cap)
    mark()
    if help then tip(help) end
    if rows and imgui.Indent then imgui.Indent(14) end
    for _, v in ipairs(values) do
        if not rows then imgui.SameLine() end
        if imgui.RadioButton((labels[v] or tostring(v)) .. '##r_' .. label .. '_' .. tostring(v), cur == v) then
            if cur ~= v and DIS == 0 then tbl[key] = v; changed() end
        end
        mark()
        if help then tip(help) end
    end
    if rows and imgui.Unindent then imgui.Unindent(14) end
    key_post(kk)
end

-- A fixed choice: radio buttons for up to four options, a drop-down for more.
local function combo(label, tbl, key, values, labels, help)
    if #values <= 4 then return radio(label, tbl, key, values, labels, help) end
    return dropdown(label, tbl, key, values, labels, help)
end

local MODE_LABELS = {
    auto = 'Auto (over the character, else game position)',
    entity = 'Over the character',
    native = 'Where the game puts its arrow',
    off = 'Off',
}
local ROTATIONS = { 0, 90, 180, 270 }
local ROT_LABELS = { [0] = 'As drawn', [90] = '90 degrees', [180] = '180 degrees', [270] = '270 degrees' }

-- Built-in shapes plus every PNG in the arrows folder.
function M.style_combo(a)
    local cur = a.style
    local f = Png.file_of(cur)
    local preview = f and ('Image: ' .. f) or (Draw.STYLE_LABELS[cur] or tostring(cur))
    local kk = (not SEARCHING) and key_pre('Shape##arrow_style') or nil
    local open = imgui.BeginCombo('Shape##arrow_style', preview)
    key_post(kk)
    if open then
        for _, v in ipairs(Draw.STYLES) do
            if imgui.Selectable(Draw.STYLE_LABELS[v], v == cur) then a.style = v; changed() end
        end
        for _, file in ipairs(hpp.png.files) do
            local st = Png.style_of(file)
            if imgui.Selectable('Image: ' .. file, st == cur) then a.style = st; changed() end
        end
        imgui.EndCombo()
    end
    mark()
    tip('Images come from addons\\partyramaxi\\icons\\arrows\\ (PNG, pointing down, transparent background).')
end


-- Default offsets, for the per-element reset buttons.
local INFO_POS = { name = { 0, -66 }, bar = { 0, -52 }, level = { -4, -38 }, check = { 18, -38 }, defev = { 0, -24 }, dist = { 56, -52 }, weak = { 0, -126 }, mob = { 0, -146 } }

local function offsets(el, key)
    heading('Position')
    slider_int('Left / right##info_' .. key .. '_dx', el, 'dx', -2000, 2000, '%d px', 'Left (-) / right (+) of the pointer.')
    slider_int('Down / up##info_' .. key .. '_dy', el, 'dy', -2000, 2000, '%d px', 'Below (-) / above (+) the pointer tip.', true)
    if imgui.Button('Reset position##info_' .. key .. '_rp') then
        el.dx, el.dy = INFO_POS[key][1], INFO_POS[key][2]; changed()
    end
end

-- Sample enemy info / effects: stays on until switched off, or until this window is closed.
function M.test_toggle(id)
    local on = hpp.preview_hold == true
    if imgui.Button((on and 'Stop test##' or 'Test##') .. id) then hpp.preview_hold = not on end
    tip('Shows a sample over your character (or the middle of the screen) until you press this again or close this window.')
end

local function font_controls(I)
    local names = Fonts.names()
    local cur = I.font or Fonts.DEFAULT
    if imgui.BeginCombo('Font##info_font', cur) then
        for _, f in ipairs(names) do
            if imgui.Selectable(f.name .. '##infof_' .. f.name, f.name == cur) then I.font = f.name; changed() end
        end
        imgui.EndCombo()
    end
    mark()
    tip('Windows fonts found on this PC, plus any .ttf / .otf you put in addons\\partyramaxi\\fonts\\.')
    imgui.SameLine()
    if imgui.Button('Rescan##info_fontscan') then Fonts.rescan() end
    tip('Look for new files in the fonts folder.')
    checkbox('Bold##info_bold', I, 'bold', 'Uses the font\'s bold file when it has one, otherwise thickens the letters.')
    imgui.SameLine(); checkbox('Italic##info_italic', I, 'italic', 'Needs an italic file for the chosen font (Arial, Segoe UI, Candara... have one; for your own fonts add the -Italic file to the fonts folder).')
    if not Fonts.supported() then
        imgui.TextDisabled('(Fonts need a newer Ashita v4: imgui.AddFontFromFileTTF is missing. Size still works.)')
    elseif Fonts.status ~= '' then
        imgui.TextColored({ 1, 0.5, 0.4, 1 }, Fonts.status)
    end
end

-- Per-element battle fade.
local function el_fade(el, key)
    heading('In battle')
    checkbox('Fade out in battle##info_' .. key .. '_fade', el, 'fade', 'This one fades while you or the target are engaged (General tab: In battle when).')
    when(el.fade, slider_float, 'Fade to (opacity)##info_' .. key .. '_fa', el, 'fade_alpha', 0, 1, '%.1f', '0 = disappears completely, 1 = no fade.')
end

local function el_scale(el, key)
    slider_float('Size (x)##info_' .. key .. '_sc', el, 'scale', 0.5, 3, '%.1f', 'Multiplies the overall text size, for this line only.')
end

-- Layer (front / back) of one enemy-info element. Renumbers the layers of all of them 1..n; higher = in front.
local function info_layer(key)
    local imgui = real_imgui
    local I = hpp.s.info
    local list = {}
    for i, k in ipairs(Info.LAYER_KEYS) do
        local el = I[k]
        list[#list + 1] = { k = k, z = tonumber(el and el.z) or Info.LAYER_DEF[k], i = i }
    end
    table.sort(list, function (a, b) if a.z ~= b.z then return a.z < b.z end return a.i < b.i end)
    local pos
    for i, e in ipairs(list) do if e.k == key then pos = i end end
    if pos == nil or skip('Layer##info_ly_' .. key, 'layer front back order') then return end
    heading('Layer')
    local function move(to)
        local e = table.remove(list, pos)
        table.insert(list, math.max(1, math.min(#list + 1, to)), e)
        for i, x in ipairs(list) do if type(I[x.k]) == 'table' then I[x.k].z = i end end
        changed()
    end
    imgui.Text('Layer ' .. pos .. ' of ' .. #list .. ' (higher = in front)')
    if imgui.Button('Backward##info_ly_bw_' .. key) then move(pos - 1) end
    imgui.SameLine()
    if imgui.Button('Forward##info_ly_fw_' .. key) then move(pos + 1) end
end

-- Sub-tabs inside a module's tab. While the settings search runs, every sub-tab is searched (no tab bar drawn).
-- 2.9.2: clearer tabs and buttons. The window's own tabs are blue, sub-tabs teal; plain buttons get a lighter fill
-- and a thin border so they stand apart from the background. Constants missing in this ImGui are skipped.
-- 1.0.1: the window's look follows the GitHub page mockup: dark slate panels, blue frames and buttons, rounded corners,
-- teal sub-tabs, the Inter font. Constants missing in this ImGui are skipped.
local function rgb(r, g, b, a) return { r / 255, g / 255, b / 255, a or 1 } end
local WIN_COLS = {
    { 'ImGuiCol_WindowBg', rgb(18, 20, 27, 0.97) }, { 'ImGuiCol_ChildBg', { 0, 0, 0, 0 } }, { 'ImGuiCol_PopupBg', rgb(16, 20, 29, 0.98) },
    { 'ImGuiCol_Border', rgb(58, 66, 88) }, { 'ImGuiCol_BorderShadow', { 0, 0, 0, 0 } },
    { 'ImGuiCol_TitleBg', rgb(34, 53, 92) }, { 'ImGuiCol_TitleBgActive', rgb(34, 53, 92) }, { 'ImGuiCol_TitleBgCollapsed', rgb(26, 40, 70) },
    { 'ImGuiCol_Text', rgb(227, 231, 239) }, { 'ImGuiCol_TextDisabled', rgb(141, 151, 171) },
    { 'ImGuiCol_FrameBg', rgb(35, 42, 58) }, { 'ImGuiCol_FrameBgHovered', rgb(45, 55, 76) }, { 'ImGuiCol_FrameBgActive', rgb(52, 64, 90) },
    { 'ImGuiCol_CheckMark', { 1, 1, 1, 1 } },
    { 'ImGuiCol_SliderGrab', rgb(93, 142, 232) }, { 'ImGuiCol_SliderGrabActive', rgb(130, 170, 245) },
    { 'ImGuiCol_Button', rgb(47, 77, 128) }, { 'ImGuiCol_ButtonHovered', rgb(62, 100, 165) }, { 'ImGuiCol_ButtonActive', rgb(38, 62, 104) },
    { 'ImGuiCol_Header', rgb(47, 77, 128, 0.70) }, { 'ImGuiCol_HeaderHovered', rgb(62, 100, 165, 0.80) }, { 'ImGuiCol_HeaderActive', rgb(56, 120, 217) },
    { 'ImGuiCol_Separator', rgb(52, 61, 82) }, { 'ImGuiCol_SeparatorHovered', rgb(93, 142, 232) }, { 'ImGuiCol_SeparatorActive', rgb(93, 142, 232) },
    { 'ImGuiCol_ScrollbarBg', rgb(18, 20, 27, 0.6) }, { 'ImGuiCol_ScrollbarGrab', rgb(52, 61, 82) },
    { 'ImGuiCol_ScrollbarGrabHovered', rgb(68, 80, 108) }, { 'ImGuiCol_ScrollbarGrabActive', rgb(93, 142, 232) },
    { 'ImGuiCol_ResizeGrip', rgb(56, 120, 217, 0.25) }, { 'ImGuiCol_ResizeGripHovered', rgb(56, 120, 217, 0.6) }, { 'ImGuiCol_ResizeGripActive', rgb(56, 120, 217) },
    { 'ImGuiCol_Tab', rgb(33, 47, 51) }, { 'ImGuiCol_TabHovered', rgb(36, 120, 115) },
    { 'ImGuiCol_TabActive', rgb(33, 148, 140) }, { 'ImGuiCol_TabSelected', rgb(33, 148, 140) },
    { 'ImGuiCol_TextSelectedBg', rgb(56, 120, 217, 0.45) },
}
local SUB_COLS = {
    { 'ImGuiCol_Tab', rgb(33, 47, 51) }, { 'ImGuiCol_TabHovered', rgb(36, 120, 115) },
    { 'ImGuiCol_TabActive', rgb(33, 148, 140) }, { 'ImGuiCol_TabSelected', rgb(33, 148, 140) },
}
local function push_cols(list)
    local n = 0
    for _, c in ipairs(list) do
        local k = rawget(_G, c[1])
        if type(k) == 'number' and pcall(real_imgui.PushStyleColor, k, c[2]) then n = n + 1 end
    end
    return n
end
local function pop_cols(n) if n > 0 then pcall(real_imgui.PopStyleColor, n) end end
local WIN_VARS = {
    { 'ImGuiStyleVar_WindowRounding', 6 }, { 'ImGuiStyleVar_ChildRounding', 4 }, { 'ImGuiStyleVar_PopupRounding', 4 },
    { 'ImGuiStyleVar_FrameRounding', 3 }, { 'ImGuiStyleVar_GrabRounding', 2 }, { 'ImGuiStyleVar_ScrollbarRounding', 4 },
    { 'ImGuiStyleVar_TabRounding', 4 }, { 'ImGuiStyleVar_FrameBorderSize', 1 }, { 'ImGuiStyleVar_WindowBorderSize', 1 },
    { 'ImGuiStyleVar_FramePadding', { 8, 4 } }, { 'ImGuiStyleVar_ItemSpacing', { 8, 6 } }, { 'ImGuiStyleVar_WindowPadding', { 10, 10 } },
    { 'ImGuiStyleVar_GrabMinSize', 10 },
}
local function push_vars()
    local n = 0
    for _, v in ipairs(WIN_VARS) do
        local k = rawget(_G, v[1])
        if type(k) == 'number' and pcall(real_imgui.PushStyleVar, k, v[2]) then n = n + 1 end
    end
    return n
end

--[[
* 1.0.1: buttons and tick boxes styled by what they do, in every module's settings (RecastXI too). While the window
* draws, the imgui module's Button / SmallButton / ArrowButton / Checkbox / BeginCombo are wrapped (and put back right
* after End, also after an error): red = takes something away, grey = moves or refreshes, gold = jumps to a key
* setting, a ticked box is filled blue, a combo's arrow sits in the field's color. Buttons that set their own colors
* (Enabled / Test, Edit positions, the sidebar) are left alone. Radio buttons keep ImGui's own look.
--]]
local BTN_KIND = {
    red  = { rgb(122, 46, 51), rgb(150, 58, 64), rgb(100, 36, 40) },
    grey = { rgb(57, 64, 79), rgb(74, 83, 102), rgb(46, 52, 64) },
    gold = { rgb(107, 81, 21), rgb(134, 102, 28), rgb(90, 68, 16), rgb(255, 224, 138) },
}
local RED_WORDS = { 'remove', 'unpin', 'reset', 'delete', 'clear', 'click again', 'forget' }
local GREY_EXACT = {}
for _, w in ipairs({ 'up', 'top', 'down', 'bottom', 'show all', 'hide all', 'refresh', 'refresh list', 'rescan', 'backward', 'forward',
    'expand all', 'collapse all', 'dn', '<', '>', '-', '+', '^', 'v', '<<', '>>', 'move up', 'move down', 'first', 'last' }) do GREY_EXACT[w] = true end
local function button_kind(label)
    if OWN_COLORS or type(label) ~= 'string' then return nil end
    if label:find('##hpp_key_', 1, true) then return 'gold' end
    if label:find('##hpp_mod_', 1, true) then return nil end
    local vis = label:gsub('##.*$', ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
    if vis == '' then return nil end
    if GREY_EXACT[vis] or vis:match('^[%^v<>%-%+]+$') or vis:find('\226\150\178', 1, true) or vis:find('\226\150\188', 1, true) then return 'grey' end
    if vis:sub(1, 6) == 'rescan' or vis:sub(1, 7) == 'refresh' then return 'grey' end
    for _, w in ipairs(RED_WORDS) do if vis:sub(1, #w) == w then return 'red' end end
    return nil
end
local function push_kind(kind)
    local set = BTN_KIND[kind]
    local list = { { 'ImGuiCol_Button', set[1] }, { 'ImGuiCol_ButtonHovered', set[2] }, { 'ImGuiCol_ButtonActive', set[3] } }
    if set[4] then list[4] = { 'ImGuiCol_Text', set[4] } end
    return push_cols(list)
end
local CHECK_ON = { { 'ImGuiCol_FrameBg', rgb(56, 120, 217) }, { 'ImGuiCol_FrameBgHovered', rgb(76, 140, 235) },
    { 'ImGuiCol_FrameBgActive', rgb(46, 100, 190) }, { 'ImGuiCol_Border', rgb(56, 120, 217) } }
local CHECK_OFF = { { 'ImGuiCol_FrameBg', rgb(42, 53, 80) }, { 'ImGuiCol_Border', rgb(68, 80, 122) } }
local COMBO_ARROW = { { 'ImGuiCol_Button', rgb(35, 42, 58) }, { 'ImGuiCol_ButtonHovered', rgb(45, 55, 76) }, { 'ImGuiCol_ButtonActive', rgb(52, 64, 90) } }
local WRAP_ORIG = nil
local function finish(n, ok, ...)
    pop_cols(n or 0)
    if not ok then error((...), 0) end
    return ...
end
local function wrap(orig, before)
    return function (...)
        local n = before(...)
        return finish(n, pcall(orig, ...))
    end
end
local function style_install()
    if WRAP_ORIG ~= nil then return end
    local im = real_imgui
    local orig = {}
    for _, k in ipairs({ 'Button', 'SmallButton', 'ArrowButton', 'Checkbox', 'BeginCombo' }) do orig[k] = rawget(im, k) or im[k] end
    if type(orig.Button) ~= 'function' then return end
    local raw = {}
    for k in pairs(orig) do raw[k] = rawget(im, k) end
    local btn = function (label) local kd = button_kind(label); return kd and push_kind(kd) or 0 end
    local ok = pcall(function ()
        im.Button = wrap(orig.Button, btn)
        if type(orig.SmallButton) == 'function' then im.SmallButton = wrap(orig.SmallButton, btn) end
        if type(orig.ArrowButton) == 'function' then im.ArrowButton = wrap(orig.ArrowButton, function () return OWN_COLORS and 0 or push_kind('grey') end) end
        if type(orig.Checkbox) == 'function' then
            im.Checkbox = wrap(orig.Checkbox, function (_, v) return push_cols((type(v) == 'table' and v[1] == true) and CHECK_ON or CHECK_OFF) end)
        end
        if type(orig.BeginCombo) == 'function' then im.BeginCombo = wrap(orig.BeginCombo, function () return push_cols(COMBO_ARROW) end) end
    end)
    WRAP_ORIG = raw
    if not ok then M.style_remove() end
end
function M.style_remove()
    if WRAP_ORIG == nil then return end
    local im = real_imgui
    for k, f in pairs({ Button = 1, SmallButton = 1, ArrowButton = 1, Checkbox = 1, BeginCombo = 1 }) do pcall(function () im[k] = WRAP_ORIG[k] end) end
    WRAP_ORIG = nil
end
local INTER = nil                 -- the Inter font for this window (false = not available)
local function ui_font()
    if INTER == nil then
        local ok, f = pcall(Fonts.fetch, 'Inter', false, false)
        INTER = (ok and f) or false
    end
    return INTER or nil
end
M.push_cols, M.pop_cols, M.SUB_COLS = push_cols, pop_cols, SUB_COLS
-- a sub-tab's button in the teal sub-tab colors (its contents keep the window's colors)
function M.sub_tab_item(label, ...)
    local nc = push_cols(SUB_COLS)
    local ok, r
    if jump_tab(label) then ok, r = pcall(tab_item_sel, label)       -- 2.13.0: a key setting's jump opens its tab
    else ok, r = pcall(real_imgui.BeginTabItem, label, ...) end
    pop_cols(nc)
    if not ok then error(r, 0) end
    return r
end
local function sub_tabs(id, list)
    if SEARCHING then
        for _, t in ipairs(list) do t[2]() end
        return
    end
    if not real_imgui.BeginTabBar(id) then return end
    local failed
    for _, t in ipairs(list) do
        local nc = push_cols(SUB_COLS)       -- only while the tab button is drawn, not its contents
        local open
        if jump_tab(t[1]) then open = tab_item_sel(t[1]) else open = real_imgui.BeginTabItem(t[1]) end
        pop_cols(nc)
        if open then
            G.n = 0
            local ok, e = pcall(t[2])
            real_imgui.EndTabItem()
            if not ok and failed == nil then failed = e end
        end
    end
    real_imgui.EndTabBar()
    if failed ~= nil then error(failed, 0) end
end
M.sub_tabs = sub_tabs

-- 2.9.0: the Enabled / Test pair at the top of a sub-tab that has its own switch (tbl[key]). While the settings
-- search runs it is a checkbox, so the switch can still be found. Returns 'test' when Test was pressed.
function M.sub_head(id, label, tbl, key, en_help, test_on, test_help)
    if SEARCHING then checkbox(label .. '##hpp_sck_' .. id, tbl, key, en_help); return nil end
    local on = tbl[key] == true
    if colored_button((on and 'Enabled' or 'Disabled') .. '##hpp_sen_' .. id, on and BTN.on or BTN.off) then tbl[key] = not on; changed() end
    tip(en_help)
    local act = nil
    if test_on ~= 'none' then
        real_imgui.SameLine()
        if colored_button((test_on and 'Stop test' or 'Test') .. '##hpp_sts_' .. id, test_on and BTN.testing or BTN.test) then act = 'test' end
        tip(test_help)
    end
    real_imgui.SameLine(); real_imgui.TextDisabled(label)      -- 2.9.1: says what the Enabled button switches
    return act
end
local sub_head = M.sub_head

-- Target bar tests: a sample of one kind of target until pressed again (or the window closes).
local SAMPLE_HELP = 'Shows a sample over your character (or the middle of the screen, or at its pinned spot) until you press this again or close this window.'
local function testing(kind) return hpp.preview_hold == true and (hpp.preview_kind or 'mob') == kind end
local function test_toggle(kind)
    if testing(kind) then hpp.preview_hold = false else hpp.preview_hold, hpp.preview_kind = true, kind end
end

local KIND_NAME = { mob = 'enemies', pc = 'other players', npc = 'NPCs and objects' }
-- 2.9.1: does any kind of target that is shown use this element (name / hp / dist / icons)?
local function any_kind(I, el)
    for _, k in ipairs({ 'mob', 'pc', 'npc' }) do
        local K = I.kinds[k]
        if K.enabled and K[el] then return true end
    end
    return false
end
-- 1.0.6: a group's own description, wrapped, in the quiet text color
local function explain(text)
    if SEARCHING then return end
    local imgui = real_imgui
    if imgui.PushTextWrapPos then imgui.PushTextWrapPos(0) end
    imgui.PushStyleColor(ImGuiCol_Text, { 0.62, 0.66, 0.75, 1 })
    imgui.TextWrapped(text)
    imgui.PopStyleColor()
    if imgui.PopTextWrapPos then imgui.PopTextWrapPos() end
end
-- 1.0.6 (Joshua): Pinned = a kind's bar moved off the target to a spot of the screen you choose (draggable)
local function pinned_spot(I, kind, label)
    local K = I.kinds[kind]
    checkbox(label .. '##info_k_abs_' .. kind, K, 'abs', 'The bar for ' .. KIND_NAME[kind] .. ' leaves the target and stays at one spot on the screen. This turns Floating off for them (no bar over the target, no glide in battle). While this window is open a sample shows at the spot with a handle under it: drag the handle to move it.')
    if K.abs and (tonumber(K.ax) or 0) == 0 and (tonumber(K.ay) or 0) == 0 then
        K.ax = math.floor((hpp.disp_w and hpp.disp_w > 0 and hpp.disp_w or 1280) * (kind == 'mob' and 0.5 or (kind == 'pc' and 0.3 or 0.7)))
        K.ay = math.floor((hpp.disp_h and hpp.disp_h > 0 and hpp.disp_h or 720) * 0.25)
        changed()
    end
    if K.abs and not SEARCHING then
        real_imgui.TextColored({ 1.00, 0.78, 0.35, 1 }, 'Floating is off for ' .. KIND_NAME[kind] .. ': their bar sits at this spot.')
    end
    if real_imgui.Indent and not SEARCHING then real_imgui.Indent(18) end
    when(K.abs, function ()
        slider_int('Spot: left / right##info_k_ax_' .. kind, K, 'ax', 0, math.max(1, math.floor(hpp.disp_w or 0) > 0 and math.floor(hpp.disp_w) or 4000), '%d px', 'Pixels from the left edge of the screen. Or drag the handle under the sample while this window is open.')
        slider_int('Spot: top / bottom##info_k_ay_' .. kind, K, 'ay', 0, math.max(1, math.floor(hpp.disp_h or 0) > 0 and math.floor(hpp.disp_h) or 3000), '%d px', 'Pixels from the top edge of the screen.')
    end)
    if real_imgui.Unindent and not SEARCHING then real_imgui.Unindent(18) end
end
local HEV = { v = true }
local function info_general(I)
    local K = I.kinds
    if group('Show bar for##g_inf_who', 'info', '*', true) then
        imgui.Text('Show it for:')
        imgui.SameLine(); checkbox('Enemies##info_k_mob', K.mob, 'enabled', 'Monsters (and anything you can fight). Same switch as the Enabled button in the Enemies tab, where its settings are.')
        imgui.SameLine(); checkbox('Other players##info_k_pc', K.pc, 'enabled', 'Player characters other than you. Same switch as the Enabled button in the Players tab, where its settings are.')
        imgui.SameLine(); checkbox('NPCs##info_k_npc', K.npc, 'enabled', 'Anything else you can target: NPCs, doors, ??? points, trusts... Same switch as the Enabled button in the NPCs tab, where its settings are.')
        checkbox('Also for the sub-target cursor##info_sub', I, 'show_sub', 'A card for the monster, player or NPC the sub-target cursor is on (spells, abilities, /check <st>...). A monster there is /checked too.')
        -- 2.13.0: one switch for every kind; each kind's tab keeps its own for exceptions
        local all = K.mob.hide_events ~= false and K.pc.hide_events ~= false and K.npc.hide_events ~= false
        HEV.v = all
        checkbox('Hide in cutscenes and when the UI is hidden (all kinds)##info_hev_all', HEV, 'v', 'Sets the same switch in the Enemies, Players and NPCs tabs at once. Ticked only when all three are on; change one kind there for an exception.')
        if HEV.v ~= all then K.mob.hide_events, K.pc.hide_events, K.npc.hide_events = HEV.v, HEV.v, HEV.v; changed() end
    end
    if group('Appear and fade##g_inf_fade', 'info', '*', true) then
        slider_float('Fade in##info_fade_in', I, 'fade_in', 0, 1, '%.2f s', 'How long the info takes to appear when you pick a target. 0 pops in.')
        slider_float('Fade out (target dies)##info_fade_out', I, 'fade_out', 0.05, 1, '%.2f s', 'How long the info takes to disappear when its target dies.')
        combo('In battle when##info_fade_when', I, 'fade_when', { 'either', 'me', 'target' }, {
            either = 'Either of us is engaged', me = 'I am engaged', target = 'The target is engaged' },
            'Which one being in battle starts the battle fade and glide. Each element has its own "Fade out in battle" switch.')
        slider_float('Start after##info_fade_delay', I, 'fade_delay', 0, 30, '%.1f s', 'Seconds in battle before the fade and glide start. The way back waits the same time after the fight ends.')
    end
    -- 1.0.6 (Joshua): where the bar shows, in three groups: Floating (over the target), Pinned, Docked (above the list)
    if group('Floating: over the target##g_inf_float', 'info', '*', true) then
        explain('The bar by your target\'s pointer, following it on the screen. Where each part sits is set per kind in the Enemies, Players and NPCs tabs (Where each part sits). A kind that is Pinned (below) does not float.')
        when(I.show_sub ~= false, function ()
            slider_int('Space between target cards##info_apart', I, 'apart', 0, 100, '%d px', 'When the sub-target\'s card would overlap your target\'s card, it moves up or down out of the way, keeping this much space between them.')
        end)
        heading('Glide in battle##h_inf_glide')
        slider_int('In battle: left / right##info_glide_x', I, 'glide_x', -2000, 2000, '%d px', 'In battle every element of the main target eases this far left (-) / right (+), and back when the battle ends. 0 = no glide. Not for a pinned kind, nor on the docked card.')
        slider_int('In battle: down / up##info_glide_y', I, 'glide_y', -2000, 2000, '%d px', 'Same, down (-) / up (+). The sub-target never glides.', true)
        when((tonumber(I.glide_x) or 0) ~= 0 or (tonumber(I.glide_y) or 0) ~= 0, function ()
            slider_float('Glide takes##info_fade_time', I, 'fade_time', 0.1, 2.5, '%.1f s', 'How long the glide to the battle spot (and back) takes.')
            dropdown('Glide motion##info_glide_ease', I, 'glide_ease', Info.EASE_LIST, Info.EASE_LABELS, 'How the glide moves. The way back uses the same motion.')
        end)
    end
    if group('Pinned: a spot on the screen##g_inf_pin', 'info', '*', true) then
        explain('Moves the bar off the target to a spot on the screen you choose, for each kind of target. Pinning turns Floating off for that kind: its bar stays at the spot instead of over the target. When the target is off the screen it still docks above the party list (Docked). While this window is open a sample shows at each pinned spot with a handle under it: drag it to move the spot.')
        pinned_spot(I, 'mob', 'Pin enemies\' bar')
        pinned_spot(I, 'pc', 'Pin other players\' bar')
        pinned_spot(I, 'npc', 'Pin NPCs\' bar')
    end
    if group('Docked: above the party list##g_inf_dock', 'info', '*', true) then
        explain('When your target is off the screen (or always, if you choose), its card sits above the party list in a panel as wide as the list, with its background and border; RecastXI, when attached, slides up above it. The card stays in one place and size whatever the target is, and its parts, places and effects are its own, set here.')
        checkbox('Dock when the target is off the screen##info_dock', I, 'dock', 'When your target is off the screen (enemy, player or NPC), its bar fades in above the party list, 20 px above it. Off: nothing shows for a target off the screen.')
        when(I.dock ~= false, function ()
            checkbox('Always dock the current target##info_dock_pin', I, 'dock_pin', 'Your current target always shows on the docked card, on the screen or not, instead of floating over its head. The sub-target is not docked this way. A pinned kind docks too; "Keep the floating bar too" then keeps it at its spot as well.')
            when(I.dock_pin == true, checkbox, 'Keep the floating bar too##info_dock_float', I, 'dock_float', 'With "Always dock the current target" on, the bar still floats over your target as well, so you see both. Off: the docked card replaces it.')
            -- 1.0.5 (Joshua): the docked card's own switch for each part, apart from the Enemies / Players / NPCs tabs
            heading('Shown on the docked card##h_dock_show')
            local DOCK_HELP = 'On the docked card only. The Enemies / Players / NPCs tabs decide the bar over the target.'
            local P = I.dock_pos or {}
            -- 1.0.5 (Joshua): each part switched on shows its own position sliders under it
            local function part(label, key, pos, help)
                checkbox(label .. '##info_dock_' .. key, I, 'dock_' .. key, (help and (help .. ' ') or '') .. DOCK_HELP)
                local t = P[pos]
                if I['dock_' .. key] == true or SEARCHING then
                    if t then
                        if imgui.Indent and not SEARCHING then imgui.Indent(18) end
                        slider_int('Left / right##info_dp_' .. pos .. '_dx', t, 'dx', -2000, 2000, '%d px', 'Left (-) / right (+) on the docked card.' .. (pos == 'pct' and ' From the middle of the bar.' or ''))
                        slider_int('Down / up##info_dp_' .. pos .. '_dy', t, 'dy', -2000, 2000, '%d px', 'Down (-) / up (+) on the docked card.', true)
                        -- 1.0.6: text parts can be justified from their point
                        if hpp.DOCK_ALIGN and hpp.DOCK_ALIGN[pos] then
                            radio('Justify##info_dp_' .. pos .. '_al', t, 'align', { 'left', 'center', 'right' }, { left = 'Left', center = 'Center', right = 'Right' },
                                'Which end of the text sits on its point: Left = it starts there and grows right, Center = centred on it, Right = it ends there. Left or Right keeps one edge still when the text changes length (a long or short name).')
                        end
                        if imgui.Unindent and not SEARCHING then imgui.Unindent(18) end
                    end
                end
            end
            part('Name', 'name', 'name')
            when(I.dock_name ~= false, checkbox, 'Linkshell and name icons##info_dock_badges', I, 'dock_badges', 'Players: the linkshell pearl and the game\'s name icons left of the name (they move with the name; their look is set in Target bar > Players). ' .. DOCK_HELP)
            part('Health bar', 'bar', 'bar')
            when(I.dock_bar ~= false, part, 'Health %', 'pct', 'pct', 'The percent number on the health bar.')
            part('Distance', 'dist', 'dist')
            part('Level', 'level', 'level', 'Enemies: the level from /check (or the monster data).')
            part('Check', 'check', 'check', 'Enemies: how tough it is (Easy prey, Tough...).')
            part('Defense / evasion', 'defev', 'defev', 'Enemies: high / low defense and evasion from /check.')
            part('Weaknesses', 'weak', 'weak', 'Enemies: the weakness icons (their look is set in Target bar > Enemies > Weaknesses).')
            part('Monster info', 'mob', 'mob', 'Enemies: aggro, links, detection and the rest of the monster data (set in Target bar > Enemies > Monster info).')
            checkbox('Effects##info_dock_fx', I, 'dock_fx', 'The effects on the docked target, drawn like the party list\'s status icons: the same countdown look, sort, pins (Show / Hide) and flash, set in Party List > Icons. Off: no effects on the docked card.')
            when(I.dock_fx ~= false, function ()
                if imgui.Indent and not SEARCHING then imgui.Indent(18) end
                checkbox('Same settings as party members##info_dock_fx_list', I, 'dock_fx_list', 'On: the icons use the party list\'s own settings and place (Party List > Icons): its size, countdown, rows, and its position, so with "Fit to the card" off they sit off the card where the party members\' do. Off: they sit in the card under its content, wrapped to stay inside it, at the card\'s own size and countdown below.')
                if imgui.Unindent and not SEARCHING then imgui.Unindent(18) end
            end)
            when(I.dock_fx ~= false and I.dock_fx_list ~= true, function ()
                slider_int('Card icon size##info_dock_fx_size', I, 'dock_fx_size', 12, 72, '%d px', 'The size of the effect icons on the docked card, apart from the party list\'s. More fit in a row when smaller.')
                checkbox('Countdown on the card icons##info_dock_fx_timers', I, 'dock_fx_timers', 'A countdown on each effect icon of the docked card, apart from the party list\'s switch. Its look (ring, bar or number) follows Party List > Icons.')
            end)
            -- 1.0.7 (Joshua): the party's hate list
            heading('Hate list##h_dock_hate')
            checkbox('Enemies fighting the party##info_dock_hate', I, 'dock_hate', 'Every monster with hate on your party or alliance gets a row on the docked card (name, distance, health): claimed by a member, fought by one, targeting one, or trading blows with one in the last 30 s, within 50 yalms. Rows keep the order they joined in. Your current target is on the card above, so it leaves the list while it is your target and comes back in its place when you target something else. Click a row to target that monster. With no docked card, the list shows above the party list on its own.')
            when(I.dock_hate == true, function ()
                slider_int('Rows at most##info_dock_hate_max', I, 'dock_hate_max', 1, 20, '%d', 'More monsters than this are left out (the newest ones).')
            end)
        end)
    end
end

local function info_text(I)
    if group('Shared Text##g_inf_text', 'info', '*', true) then
        slider_float('Text size##info_ts', I, 'text_size', 0.6, 3.5, '%.1f', 'Size of all the text. Every line below can be made larger or smaller on its own.')
        if hpp.font_method == 'none' then imgui.TextDisabled('(Text size is not supported by this Ashita version.)') end
        font_controls(I)
        checkbox('Text shadow##info_shadow', I, 'shadow')
        imgui.SameLine()
        checkbox('Outline##info_outline', I, 'outline', 'A thin dark outline around every letter. Easiest to read on bright backgrounds.')
        when(I.outline, function ()
            slider_int('Outline thickness##info_ow', I, 'outline_w', 1, 3, '%d px')
            color('Outline color##info_oc', I, 'outline_color')
        end)
    end
    if group('Name##g_inf_name', 'info', 'name') then when(any_kind(I, 'name'), function ()
        color('Color##info_name_col', I.name, 'color', 'NPCs use their own color (NPCs tab).')
        el_scale(I.name, 'name')
        el_fade(I.name, 'name')
        info_layer('name')
    end) if not SEARCHING then imgui.TextDisabled('Shown or not, and where: Enemies / Players / NPCs tabs.') end
    end
    if group('Distance##g_inf_dist', 'info', 'dist') then when(any_kind(I, 'dist'), function ()
        local D = I.dist
        combo('Format##info_ds_fmt', D, 'format', Info.DIST_FORMATS, Info.DIST_LABELS)
        color('Color##info_ds_col', D, 'color')
        checkbox('Fixed width##info_ds_pad', D, 'pad', 'The number sits in a slot as wide as "88.8y", right-aligned, so its digits and unit stay put as it changes and nothing next to it moves.')
        checkbox('Another color when far##info_ds_far', D, 'far', 'Beyond the distance below the number turns the far color (about 21 yalms is the usual spell range).')
        when(D.far, function ()
            imgui.SameLine(); color('##info_ds_fcol', D, 'far_color')
            slider_float('Far from##info_ds_fat', D, 'far_at', 1, 60, '%.1f y')
        end)
        el_scale(D, 'dist')
        el_fade(D, 'dist')
        info_layer('dist')
    end) if not SEARCHING then imgui.TextDisabled('Shown or not, and where: Enemies / Players / NPCs tabs.') end
    end
end

local function info_bar_body(I)
    local b = I.bar
    if group('Health bar##g_inf_bar', 'info', 'bar', true) then
        el_fade(b, 'bar')
        heading('Bar')
        slider_int('Width##info_bar_w', b, 'width', 20, 300, '%d px')
        slider_int('Height##info_bar_h', b, 'height', 3, 30, '%d px')
        checkbox('Color by health (green > red)##info_bar_byhp', b, 'by_hp')
        when(not b.by_hp, color, 'Bar color##info_bar_fill', b, 'fill')
        color('Background##info_bar_back', b, 'back')
        info_layer('bar')
        if not SEARCHING then imgui.TextDisabled('Shown or not, and where: Enemies / Players / NPCs tabs.') end
    end
    if group('Border and finish##g_inf_bar_look', 'info', 'bar') then
        checkbox('Border##info_bar_border', b, 'border')
        when(b.border, function ()
            imgui.SameLine(); color('##info_bar_bcol', b, 'border_color')
            slider_int('Border width##info_bar_bw', b, 'border_width', 1, 8, '%d px', 'The outermost edge of the bar.')
        end)
        slider_int('Rounding##info_bar_round', b, 'rounding', 0, 30, '%d px', '0 = square corners. Half the height or more = pill shape.')
        combo('Finish##info_bar_gloss', b, 'gloss', Info.GLOSS, Info.GLOSS_LABELS,
            'Flat: plain color.\nGradient: lighter on top, darker below.\nGlossy: a glass-like top half with a highlight line.\nShine: only the thin highlight line.')
        when(b.gloss ~= 'none', slider_float, 'Finish strength##info_bar_gs', b, 'gloss_strength', 0, 1, '%.1f')
        checkbox('Marks at 25 / 50 / 75 %##info_bar_ticks', b, 'ticks')
        when(b.ticks, slider_int, 'Mark length##info_bar_tl', b, 'tick_len', 1, 30, '%d px')
    end
    if group('Effects##g_inf_bar_fx', 'info', 'bar') then
        checkbox('Glass sheen when the bar refills to 100%##info_bar_sheen', b, 'sheen')
        radio('Comet##info_bar_comet', b, 'comet', { 'off', 'once' }, { off = 'Off', once = 'Once' }, 'A glowing head with a fading tail runs once along the bar when health is back to 100%.')
        when(b.comet == 'once', function ()
            color('Comet color##info_bar_cc', b, 'comet_color')
            slider_float('Comet speed##info_bar_cs', b, 'comet_speed', 0.3, 3, '%.2f', '1 = 1.3 seconds for the pass; higher is faster.')
        end)
        checkbox('Damage trail##info_bar_trail', b, 'trail', 'Recent damage stays on the bar for a moment and then drains out.')
        when(b.trail, function () imgui.SameLine(); color('##info_bar_tcol', b, 'trail_color') end)
    end
    if group('HP Number##g_inf_bar_num', 'info', 'bar') then
        checkbox('Health number in the bar##info_bar_pct', b, 'percent')
        when(b.percent, function ()
            imgui.Text('Show it for:'); imgui.SameLine()
            when(I.kinds.mob.enabled and I.kinds.mob.hp, checkbox, 'Enemies##info_pct_mob', b, 'pct_mob'); imgui.SameLine()
            when(I.kinds.pc.enabled and I.kinds.pc.hp, checkbox, 'Players##info_pct_pc', b, 'pct_pc'); imgui.SameLine()
            when(I.kinds.npc.enabled and I.kinds.npc.hp, checkbox, 'NPCs##info_pct_npc', b, 'pct_npc')
            slider_float('Number size (x)##info_bar_ps', b, 'percent_scale', 0.4, 2, '%.1f')
            if not SEARCHING then imgui.TextDisabled('Its position: Enemies / Players / NPCs tab, Position.') end
        end)
    end
end
-- 2.9.1: greyed when no kind of target that is shown has a health bar
local function info_bar(I)
    if not SEARCHING and not any_kind(I, 'hp') then imgui.TextDisabled('No kind of target shows a health bar (Enemies / Players / NPCs tabs).') end
    when(any_kind(I, 'hp'), info_bar_body, I)
end

-- One element's offsets from the tip (or from the pinned spot), with a reset.
local function el_offsets(t, id, label, dx, dy)
    heading(label)
    slider_int('Left / right##info_o_' .. id .. '_dx', t, 'dx', -2000, 2000, '%d px', 'Left (-) / right (+) of the pointer tip (or the pinned spot).')
    slider_int('Down / up##info_o_' .. id .. '_dy', t, 'dy', -2000, 2000, '%d px', 'Below (-) / above (+) the pointer tip (or the pinned spot).', true)
    if imgui.Button('Reset position##info_o_' .. id .. '_r') then t.dx, t.dy = dx, dy; changed() end
end

-- What one kind of target shows, and where (Enemies / Players / NPCs tabs).
local function kind_general(I, kind)
    local K = I.kinds[kind]
    local mob = kind == 'mob'
    if group('What it shows (on / off)##g_k_show_' .. kind, 'info', '*', true) then
        checkbox('Hide in cutscenes and when the UI is hidden##info_k_ev_' .. kind, K, 'hide_events')
        checkbox('Name##info_k_nm_' .. kind, K, 'name'); imgui.SameLine()
        checkbox('Health bar##info_k_hp_' .. kind, K, 'hp'); imgui.SameLine()
        checkbox('Distance##info_k_ds_' .. kind, K, 'dist'); imgui.SameLine()
        checkbox('Effect icons##info_k_fx_' .. kind, K, 'icons', mob and 'Spell effects on the monster, with a countdown (Icons tab).' or 'Effects the addon saw land on them (Icons tab).')
        if kind == 'npc' then color('Name color##info_npc_col', I, 'npc_color') end
        if kind == 'pc' then checkbox('Also your own character##info_k_self', K, 'self', 'Shows the target bar when you target yourself.') end
        -- 2.13.4: the linkshell pearl and the game's name icons over the player's name
        if kind == 'pc' then
            when(K.name, checkbox, 'Linkshell and name icons##info_k_badges', K, 'badges', 'Left of the name (the name stays centred): the game\'s name icons (link dead, away, GM, seeking a party, level sync, new adventurer, mentor, bazaar, /anon), then a pearl in the player\'s linkshell color nearest the name. Also on your own character. The pictures are in icons\\badges\\ (a missing one shows as a short label). Players in view before the addon loaded show their icons after their next update.')
            when(K.name and K.badges ~= false, function ()
                slider_int('Icon size##info_k_badge_sz', K, 'badge_size', 10, 40, '%d px', 'The size of the linkshell pearl. The other icons are drawn 50% larger.')
                checkbox('Only the most important icon, like the game##info_k_badge_one', K, 'badge_one', 'The game shows one name icon: link dead, then away, GM, seeking a party / level sync, new adventurer / mentor, bazaar. On: only that one (the linkshell pearl still shows). Off: every icon the player has.')
                slider_int('Space before the name##info_k_badge_gap', K, 'badge_gap', 0, 40, '%d px', 'Between the last icon and the name.')
                checkbox('Also the new adventurer label##info_k_badge_new', K, 'badge_new', 'Some servers mark every player who has not turned the new adventurer icon off.')
            end)
        end
        if not mob and not SEARCHING then imgui.TextDisabled('Level, check and the monster data are for enemies only.') end
    end
    if group('Where each part sits##g_k_pos_' .. kind, 'info', '*', true) then
        -- 1.0.6: the fixed spot moved to Target bar > General > Pinned
        if K.abs and not SEARCHING then imgui.TextDisabled('Pinned to a spot on the screen (General > Pinned): these places are from that spot.') end
        local O = K.off
        el_offsets(mob and I.name or O.name, kind .. '_name', 'Name', INFO_POS.name[1], INFO_POS.name[2])
        el_offsets(mob and I.bar or O.bar, kind .. '_bar', 'Health bar', INFO_POS.bar[1], INFO_POS.bar[2])
        -- 2.9.1: the HP number inside the bar, per kind (enemies keep the bar's own pct_dx / pct_dy)
        local b = I.bar
        when(K.hp and b.percent and b['pct_' .. kind] ~= false, function ()
            heading('HP number (from the middle of the bar)')
            local t, kx, ky = O and O.pct, 'dx', 'dy'
            if mob then t, kx, ky = b, 'pct_dx', 'pct_dy' end
            slider_int('Left / right##info_o_' .. kind .. '_pct_dx', t, kx, -200, 200, '%d px')
            slider_int('Down / up##info_o_' .. kind .. '_pct_dy', t, ky, -100, 100, '%d px', 'Down (-) / up (+).', true)
            if imgui.Button('Reset position##info_o_' .. kind .. '_pct_r') then t[kx], t[ky] = 0, 0; changed() end
        end)
        el_offsets(mob and I.dist or O.dist, kind .. '_dist', 'Distance', INFO_POS.dist[1], INFO_POS.dist[2])
        el_offsets(mob and I.fx or O.fx, kind .. '_fx', 'Effect icons (centre of the first row)', 0, -98)
    end
end

local function level_tab(I)
    local L = I.level
    sub_head('lv', 'Show the level', L, 'show', 'The enemy\'s level (range), from the monster database or your checks.', 'none')
    when(L.show, function ()
        if group('Level##g_inf_level', 'info', 'level', true) then
            checkbox('Show "Lv ?" until known##info_lv_unk', L, 'unknown')
            checkbox('Level from the monster database##info_lv_db', L, 'db', 'LandSandBoat\'s exact level range for this spawn. Replaces the estimate from /check.')
            color('Color##info_lv_col', L, 'color')
            el_scale(L, 'level')
            el_fade(L, 'level')
            offsets(L, 'level')
            info_layer('level')
        end
    end)
end

local function check_tab(I)
    local c = I.check
    sub_head('ck', 'Show the check', c, 'show', 'What the enemy checks as (EP, DC, VT...). /check is sent once per new monster name.', 'none')
    when(c.show, function ()
        if group('Check (EP, DC, VT...)##g_inf_check', 'info', 'check', true) then
            combo('Format##info_ck_style', c, 'style', Info.CHECK_STYLES, Info.CHECK_LABELS)
            checkbox('Show "?" until known##info_ck_unk', c, 'unknown')
            checkbox('Color by difficulty##info_ck_bydiff', c, 'by_diff', 'Grey = too weak, blues = easy, green = decent, white = even, yellow / orange / red = tough.')
            when(not c.by_diff, color, 'Color##info_ck_col', c, 'color')
            el_scale(c, 'check')
            el_fade(c, 'check')
            offsets(c, 'check')
            info_layer('check')
        end
    end)
end

local function defev_tab(I)
    local v = I.defev
    sub_head('dv', 'Show evasion / defense', v, 'show', 'From the check reply: how the monster\'s evasion and defense compare. Appears after it was checked.', 'none')
    when(v.show, function ()
        if group('Evasion / Defense##g_inf_defev', 'info', 'defev', true) then
            checkbox('Use arrows (off = words)##info_dv_arrows', v, 'arrows', 'Red arrow up = high, green arrow down = low (like the weakness marks). Words: High / Low.')
            checkbox('Also show "normal"##info_dv_norm', v, 'show_normal')
            color('High##info_dv_high', v, 'color_high', 'High evasion or defense (harder to hit / hurt).')
            imgui.SameLine(); color('Low##info_dv_low', v, 'color_low', 'Low evasion or defense (easier to hit / hurt).')
            imgui.SameLine(); color('Labels##info_dv_lab', v, 'color_label')
            el_scale(v, 'defev')
            el_fade(v, 'defev')
            offsets(v, 'defev')
            info_layer('defev')
        end
    end)
end

-- Enemies / Players / NPCs: the kind's own Enabled and Test buttons on top.
local function kind_tab(I, kind, title, help)
    local K = I.kinds[kind]
    -- 2.9.1: no Test on Enemies (the Target bar's Test at the top shows the enemy sample)
    if sub_head('k_' .. kind, 'Show the target bar for ' .. KIND_NAME[kind], K, 'enabled', help, kind == 'mob' and 'none' or testing(kind), SAMPLE_HELP) == 'test' then test_toggle(kind) end
    when(K.enabled, function ()
        if kind ~= 'mob' then kind_general(I, kind); return end
        sub_tabs('##inf_mob_tabs', {
            { 'General##inf_m1', function () kind_general(I, 'mob') end },
            { 'Level##inf_m2', function () level_tab(I) end },
            { 'Check##inf_m3', function () check_tab(I) end },
            { 'Evasion / Defense##inf_m4', function () defev_tab(I) end },
            { 'Weaknesses##inf_m5', function () M.weak_section(I.weak) end },
            { 'Monster info##inf_m6', function () M.mob_section(I.mob) end },
        })
    end)
end

local function info_section()
    local I = hpp.s.info
    local act = M.tab_head('Target bar', 'info', I.enabled == true,
        'When you target a monster, a player or an NPC, shows its name, health and more next to the pointer (each kind has its own tab).',
        hpp.preview_hold == true, SAMPLE_HELP)
    if act == 'enable' then I.enabled = not I.enabled; changed()
    elseif act == 'test' then if hpp.preview_hold then hpp.preview_hold = false else hpp.preview_hold, hpp.preview_kind = true, 'mob' end end
    sub_tabs('##inf_tabs', {
        { 'General##inf_t1', function () info_general(I) end },
        { 'Text##inf_t2', function () info_text(I) end },
        { 'Bar##inf_t3', function () info_bar(I) end },
        { 'Icons##inf_t4', function () M.fx_section(I.fx) end },
        { 'Enemies##inf_t5', function () kind_tab(I, 'mob', 'Enemies', 'Monsters: name, health, level, check, evasion / defense, effect icons, weaknesses and monster data.') end },
        { 'Players##inf_t6', function () kind_tab(I, 'pc', 'Players', 'Other player characters: name, health bar, distance and effect icons.') end },
        { 'NPCs##inf_t7', function () kind_tab(I, 'npc', 'NPCs', 'NPCs, doors, ??? points, trusts...: name, distance, and a health bar if you want one.') end },
    })
end

-- 2.8.0: the rest of MobDB (aggro, links, detection, jobs, respawn; the hover card adds drops, steal and spells).
local STYLE_HELP = 'For the monster info badges and RecastXI\'s element and magic type icons (the weaknesses have their own Icon style). Painted changes the element icons only (icons\\elements\\painted). Glyph, High contrast and Glass are symbol-only sets (Glass: a white symbol on tinted glass); RecastXI\'s magic type icons stay Glossy with them. Your own pictures go in icons\\mob, icons\\weak, icons\\elements and icons\\categories (Glossy) or their jewel\\ / flat\\ / painted\\ / glyph\\ / contrast\\ / glass\\ folders. A folder of your own there (e.g. icons\\mob\\default) shows up in this list after Rescan.'
M.STYLES = { 'glossy', 'jewel', 'painted', 'flat', 'glyph', 'contrast', 'glass' }
M.STYLE_LABELS = { glossy = 'Glossy', jewel = 'Jewel', painted = 'Painted elements', flat = 'Flat', glyph = 'Glyph',
    contrast = 'High contrast', glass = 'Glass' }
M.STYLE_HELP = STYLE_HELP
-- 2.12.1: the built-in styles plus every folder found in icons\\elements, icons\\weak and icons\\mob (your own packs)
local SL = { src = nil, list = {}, labels = {} }
function M.style_list()
    local found = hpp.icon_styles or {}
    if SL.src ~= found then
        SL.src = found
        local list, labels = {}, {}
        for _, v in ipairs(M.STYLES) do list[#list + 1] = v; labels[v] = M.STYLE_LABELS[v] end
        for _, v in ipairs(found) do
            if labels[v] == nil then list[#list + 1] = v; labels[v] = v:sub(1, 1):upper() .. v:sub(2) end
        end
        SL.list, SL.labels = list, labels
    end
    return SL.list, SL.labels
end
local function pack_combo(label, tbl, help)
    local list, labels = M.style_list()
    combo(label, tbl, 'icon_style', list, labels, help)
    if not SEARCHING then
        imgui.SameLine()
        if imgui.SmallButton('Rescan##' .. label:gsub('^.-##', '')) then hpp.fx_rescan = true end
    end
end
function M.mob_section(B)
    sub_head('mb', 'Show monster info', B, 'show', 'Badges for what the monster does, from LandSandBoat\'s monster data. Monsters only. Your server may differ.', 'none')
    when(B.show, function ()
        if group('Monster info##g_mb_which', 'info', 'mob', true) then
            -- 2.10.2: the picture style first, under the Icon Pack heading (was its own Pictures group)
            heading('Icon Pack')
            pack_combo('Icon Pack##info_icon_style', hpp.s.info, STYLE_HELP)
            el_fade(B, 'mob')
            heading('Show')
            checkbox('Notorious Monster##info_mb_nm', B, 'nm', 'A crown on NMs.')
            imgui.SameLine(); checkbox('Aggressive##info_mb_ag', B, 'aggro', 'It attacks you on sight / sound / scent.')
            imgui.SameLine(); checkbox('Links##info_mb_ln', B, 'link', 'Others of its kind nearby join the fight.')
            checkbox('True sight / sound##info_mb_ts', B, 'truesight', 'Sees through Sneak and Invisible.')
            imgui.SameLine(); checkbox('How it detects you##info_mb_sn', B, 'senses', 'Sight, sound, scent (tracks you), magic, low health, job abilities.')
            imgui.SameLine(); checkbox('Charmable##info_mb_ch', B, 'charm')
            heading('Text')
            checkbox('Text after the badges##info_mb_tx', B, 'text')
            when(B.text, function ()
                imgui.SameLine(); checkbox('Jobs##info_mb_tj', B, 'show_jobs')
                imgui.SameLine(); checkbox('Level##info_mb_tl', B, 'show_level', 'The level is also the target bar\'s level (Level tab), so it is off here by default.')
                imgui.SameLine(); checkbox('Respawn##info_mb_tr', B, 'show_respawn')
                slider_float('Text size (x)##info_mb_ts2', B, 'text_scale', 0.4, 2, '%.1f')
                color('Text color##info_mb_tc', B, 'text_color')
            end)
            heading('Hover card')
            checkbox('Whole card when hovered##info_mb_tip', B, 'tooltip', 'Point at this row (or the weakness icons) for everything: family, level, job, element, aggro, links, detection, respawn, weaknesses, drops, steal and spells. The card is drawn in front of everything.')
            when(B.tooltip ~= false, slider_float, 'Card text size##info_mb_cs', B, 'card_scale', 0.6, 2, '%.2fx', 'The size of the card\'s text (also the weakness card).')
            if not Mob.load() then imgui.TextColored({ 1, 0.5, 0.4, 1 }, 'pximobdata.lua could not be read: ' .. tostring(Mob.load_error)) end
        end
    end)
    when(B.show, function ()
        if group('Layout##g_mb_layout', 'info', 'mob') then
            heading('Icon')
            slider_int('Icon size##info_mb_size', B, 'size', 10, 48, '%d px')
            slider_int('Spacing##info_mb_gap', B, 'spacing', 0, 12, '%d px')
            combo('Row alignment##info_mb_align', B, 'align', Fx.ALIGNS, Fx.ALIGN_LABELS)
            offsets(B, 'mob')
            info_layer('mob')
        end
    end)
end

-- 2.7.7: weaknesses / resistances / immunities (MobDB style) from LandSandBoat's monster data.
local WK_SRC, WK_SRC_LABELS = { 'auto', 'lsb' }, { auto = 'MobDB if installed', lsb = 'LandSandBoat' }
local WK_MARKS, WK_MARK_LABELS = { 'arrows', 'percent' }, { arrows = 'Arrows', percent = '+/- %' }
function M.weak_section(W)
    sub_head('wk', 'Show weakness icons', W, 'show', 'What the monster is weak to, resists and is immune to, from LandSandBoat\'s monster data (species, plus the monster\'s own changes). Monsters only. Your server may differ.', 'none')
    when(W.show, function ()
        if group('Weakness icons##g_wk_which', 'info', 'weak', true) then
            heading('Icon Pack')
            pack_combo('Icon Pack##info_icon_style_w', W, 'The element and damage type icons of the weaknesses (its own choice; Monster info has its own Icon Pack for the badges). Painted changes the element icons only. Glyph, High contrast and Glass are symbol-only sets.')
            el_fade(W, 'weak')
            heading('Show')
            checkbox('Weaknesses##info_wk_weak', W, 'weak', 'A green mark pointing down (it is low against it); two marks for a strong weakness.')
            imgui.SameLine(); when(W.weak ~= false, color, '##info_wk_wcol', W, 'weak_color')
            imgui.SameLine(); checkbox('Resistances##info_wk_res', W, 'resist', 'A red mark pointing up (it is strong against it), two for a strong resistance; a red line when nothing gets through. Shown a little dimmer.')
            imgui.SameLine(); when(W.resist ~= false, color, '##info_wk_rcol', W, 'resist_color')
            when(W.weak and W.elements ~= false, checkbox, 'Only its biggest weaknesses##info_wk_best', W, 'weak_best', 'Many monsters are a little weak to most elements. On: only the elements it is weakest to get an icon (all of them are listed when you hover).')
            checkbox('Elements##info_wk_el', W, 'elements')
            imgui.SameLine(); checkbox('Damage types##info_wk_ph', W, 'physical', 'Slashing, piercing, blunt, hand-to-hand and magic damage taken.')
            imgui.SameLine(); checkbox('Status effects##info_wk_st', W, 'status', 'Sleep, bind, silence, slow... that land better on it (green) or that it resists (red).')
            imgui.SameLine(); checkbox('Immunities##info_wk_im', W, 'immune', 'Status effects it can\'t get (sleep, bind, gravity...), crossed out. Also ones it resists almost always.')
            when(W.immune, color, 'Crossed-out line##info_wk_ncol', W, 'null_color')
            heading('Data and marks')
            radio('Data##info_wk_src', W, 'source', WK_SRC, WK_SRC_LABELS, 'MobDB: when the MobDB addon is installed, its numbers for elements and damage types (made from your server, the same ones MobDB shows); status effects still come from LandSandBoat. LandSandBoat: the data built into this addon (how well magic lands, by resistance rank).')
            if W.source ~= 'lsb' then imgui.SameLine(); imgui.TextDisabled(Weak.mdb_found() and '(MobDB found)' or '(MobDB not found: LandSandBoat)') end
            radio('Marks##info_wk_marks', W, 'marks', WK_MARKS, WK_MARK_LABELS, 'Arrows: green down = weak, red up = resists (two for a strong one). +/- %: the change as a number in the corner, like +50% or -30%.')
            when(W.marks == 'percent', slider_float, 'Number size##info_wk_pcts', W, 'pct_scale', 0.5, 2, '%.2f')
            when(W.resist, function ()
                slider_int('Resists from rank##info_wk_rank', W, 'resist_rank', 1, 10, '%d', 'LandSandBoat ranks resistance from -3 (weak) to 11: 1 = -15%, 2 = -30%, 3 = -40%, 4 = -50%, 5 = -60%, 6 = -70%, 7 = -75%, 8 = -80%, 9 = -85%, 10 = -90%, 11 = -95%. From this rank up it counts as resisted (1 = all of them, like MobDB); elements at 10 and up as nullified.')
                slider_float('Resisted icons opacity##info_wk_ra', W, 'resist_alpha', 0.1, 1, '%.2f')
            end)
            heading('Hover card')
            checkbox('Details when hovered##info_wk_tip', W, 'tooltip', 'Point at the row to read it in words (the whole monster card, in front of everything).')
            if not Weak.load() then imgui.TextColored({ 1, 0.5, 0.4, 1 }, 'pximobdata.lua could not be read: ' .. tostring(Weak.load_error)) end
        end
        if group('Layout##g_wk_layout', 'info', 'weak') then
            heading('Icon')
            slider_int('Icon size##info_wk_size', W, 'size', 10, 48, '%d px')
            slider_int('Spacing##info_wk_gap', W, 'spacing', 0, 12, '%d px')
            slider_int('Icons per row##info_wk_cols', W, 'per_row', 1, 16)
            combo('Row alignment##info_wk_align', W, 'align', Fx.ALIGNS, Fx.ALIGN_LABELS)
            checkbox('Extra rows go upward##info_wk_up', W, 'rows_up')
            offsets(W, 'weak')
            info_layer('weak')
        end
    end)
end


-- The icon pack and its fallback (shared by the target bar's effect icons and the party list's status effects).
function M.fx_packs(F)
    heading('Icon Pack##g_fx_packs', 'info', 'fx')
    local packs = { '' }
    local labels = { [''] = '(none)' }
    for _, p in ipairs(hpp.fx_packs or {}) do packs[#packs + 1] = p; labels[p] = p end
    -- 1.0.0: a saved pack that is not in icons\packs (packs do not ship) stays chosen; the icons that come with the
    -- addon are used until it is copied in
    for _, k in ipairs({ 'pack', 'pack2' }) do
        local v = F[k]
        if type(v) == 'string' and v ~= '' and labels[v] == nil then packs[#packs + 1] = v; labels[v] = v .. ' (not installed)' end
    end
    local help = 'Folders in addons\\partyramaxi\\icons\\packs\\. An effect uses the pack\'s icon (named by status id), else the fallback pack\'s, else icons\\status\\, else a colored tile.'
    dropdown('Icon pack##info_fx_pack', F, 'pack', packs, labels, help)
    dropdown('Fallback pack##info_fx_pack2', F, 'pack2', packs, labels, help)
    if imgui.Button('Rescan##info_fx_rescan') then hpp.fx_rescan = true end
    imgui.SameLine()
    if imgui.Button('Open folder##info_fx_open') then require('pxilist').open_folder(hpp.fx_pack_dir or '') end
    tip('Opens icons\\packs. Put one folder per pack in it, then Rescan.')
    imgui.SameLine()
    imgui.TextDisabled(('%d pack%s found'):format(#(hpp.fx_packs or {}), #(hpp.fx_packs or {}) == 1 and '' or 's'))
end

-- Effect icons on the target.
local function fx_body(F)
    if group('Effect icons##g_fx_which', 'info', 'fx', true) then
        if not SEARCHING then imgui.TextDisabled('Shown or not, and where: Enemies / Players / NPCs tabs.') end
        el_fade(F, 'fx')
        checkbox('Only effects I applied##info_fx_mine', F, 'mine_only')
        checkbox('Also effects with no known duration##info_fx_unk', F, 'show_unknown', 'Shown without a countdown until they wear off.')
        combo('Order##info_fx_sort', F, 'sort', Fx.SORTS, Fx.SORT_LABELS)
        slider_int('Duration adjust##info_fx_dur', F, 'duration_pct', 25, 300, '%d %%', 'Durations are the base values from the spell data. Scale them if yours are longer (gear, skill) or shorter.')
    end
    -- (the icon pack, shared with the party list, is drawn above this)
    if group('Layout##g_fx_layout', 'info', 'fx') then
        slider_int('Icon size##info_fx_size', F, 'size', 15, 72, '%d px')
        slider_int('Spacing##info_fx_gap', F, 'spacing', 0, 12, '%d px')
        checkbox('Slide into the gap when an effect ends##info_fx_slide', F, 'slide')
        slider_int('Icons per row##info_fx_cols', F, 'per_row', 1, 16)
        combo('Row alignment##info_fx_align', F, 'align', Fx.ALIGNS, Fx.ALIGN_LABELS)
        checkbox('Extra rows go upward##info_fx_up', F, 'rows_up')
        info_layer('fx')
    end
    if group('Countdown##g_fx_count', 'info', 'fx') then
        radio('Countdown graphic##info_fx_ring', F, 'ring', Fx.RINGS, Fx.RING_LABELS)
        when(F.ring ~= 'none', function ()
            color('Color##info_fx_rcol', F, 'ring_color')
            when(F.ring == 'ring', function ()
                combo('Ring shape##info_fx_shape', F, 'ring_shape', Fx.SHAPES, Fx.SHAPE_LABELS)
                slider_int('Ring width##info_fx_rw', F, 'ring_width', 1, 6, '%d px')
                slider_int('Gap to the icon##info_fx_pad', F, 'ring_pad', 0, 10, '%d px', 'How much larger than the icon the ring is.')
            end)
        end)
        combo('Number##info_fx_text', F, 'text', Fx.TEXTS, Fx.TEXT_LABELS)
        when(F.text ~= 'off', function ()
            slider_float('Number size (x)##info_fx_ts', F, 'text_scale', 0.4, 2, '%.1f')
            color('Number color##info_fx_tcol', F, 'text_color')
        end)
        slider_float('Warning at##info_fx_warn', F, 'warn_secs', 0, 30, '%.0f s', 'When this little time is left the number and ring change color and the icon flashes.')
        when((tonumber(F.warn_secs) or 0) > 0, function ()      -- 0 s = no warning
            imgui.SameLine(); color('##info_fx_wcol', F, 'warn_color')
            checkbox('Flash the icon during the warning##info_fx_flash', F, 'flash')
            when(F.flash, function ()
                slider_float('Flash speed##info_fx_fspeed', F, 'flash_speed', 0.5, 5, '%.1f /s', 'Flashes per second.')
                slider_float('Flash dimmest##info_fx_fmin', F, 'flash_min', 0.1, 1, '%.2f', 'Opacity at the dimmest point of the flash. Higher = a gentler flash.')
            end)
        end)
    end
end
function M.fx_section(F)
    M.fx_packs(F)      -- 2.9.1: the icon pack first (shared with the party list's status icons, so never greyed)
    if not SEARCHING then imgui.TextDisabled('Icon pack: shared with Party list > Icons (changing one changes both).') end
    local I = hpp.s.info
    if not SEARCHING and not any_kind(I, 'icons') then imgui.TextDisabled('No kind of target shows effect icons (Enemies / Players / NPCs tabs).') end
    when(any_kind(I, 'icons'), fx_body, F)
end

local PTR_MODES = { 'native', 'entity' }
M.PTR_POS = { v = 'native' }

-- 2.11.0: the modules in a sidebar on the left (with the settings search under them); the selected module's own
-- description, then its settings (sub-tabs on top) fill the right. Both sides scroll on their own.
M.MODULES = {
    { id = 'hide', name = 'HIDEPARTY', desc = 'Hides the game\'s own windows, each on its own: party, alliance 1 and 2, target and cast info. Hiding the target window also hides the game\'s target arrows (the Pointer module draws its own). Also: reset all settings.' },
    { id = 'pointer', name = 'POINTER', desc = 'Custom arrows over your target and sub-target: over the character or where the game puts its arrow, built-in shapes or your own pictures, colors, size, rotation and animation.' },
    { id = 'list', name = 'PARTY LIST', desc = 'Its own party and alliance list: themed cards with name, job, job icon and HP / MP / TP bars, the current action and cast bar, status icons with countdowns, pinning and canceling, leader marks, the list pointer, pets, health bars over members in battle, and undockable alliance and pet windows.' },
    { id = 'enemy', name = 'TARGET BAR', desc = 'Information next to your target, for enemies, players and NPCs: name, health bar, distance, level, check, evasion / defense, effect icons with timers, weaknesses and resistances (MobDB or LandSandBoat) and monster info badges, with a glide and fade in battle.' },
    { id = 'recast', name = 'RECASTXI', desc = 'Spell and ability recast timers (RecastXI built in): which recasts show, themes, element and magic type icons, layout, and placement on its own or attached to the party list.' },
}
M.mod = 'list'
-- 2.13.0: is the module switched on (sidebar dot, the box's ON / OFF)
local MOD_OFF = {
    hide = 'The game\'s windows show as usual.', pointer = 'The game\'s own arrows show only if Hideparty does not hide the target window.',
    list = 'The game\'s party window shows instead (unless Hideparty hides it).', enemy = 'No bar next to your target.',
    recast = 'No recast timers.' }
function M.mod_on(id)
    local s = hpp and hpp.s
    if s == nil then return nil end
    if id == 'hide' then return s.enabled == true
    elseif id == 'pointer' then return s.arrow.mode ~= 'off'
    elseif id == 'list' then return s.list.enabled == true
    elseif id == 'enemy' then return s.info.enabled == true
    elseif id == 'recast' then
        local R = hpp.rx and hpp.rx.settings and hpp.rx.settings() or nil
        return R ~= nil and R.enabled == true
    end
    return nil
end
local CHILD_FORM = nil          -- which BeginChild call form this Ashita accepts (it rejects a boolean border)
local function begin_child(id, size)
    local forms = { function () return real_imgui.BeginChild(id, size) end, function () return real_imgui.BeginChild(id, size, 0) end,
        function () return real_imgui.BeginChild(id, size, false, 0) end }
    if CHILD_FORM ~= nil then return forms[CHILD_FORM]() end
    for i, f in ipairs(forms) do
        local ok, r = pcall(f)
        if ok then CHILD_FORM = i; return r end
    end
    error('BeginChild: no call form works', 0)
end
local SIDE_W = 150
local function sidebar(q)
    local imgui = real_imgui
    local bt = rawget(_G, 'ImGuiStyleVar_ButtonTextAlign')
    local pushed = type(bt) == 'number' and pcall(imgui.PushStyleVar, bt, { 0, 0.5 })
    for _, m in ipairs(M.MODULES) do
        local on = M.mod == m.id and q == ''
        local nc = push_cols(on and { { 'ImGuiCol_Button', { 0.22, 0.47, 0.85, 1 } }, { 'ImGuiCol_ButtonHovered', { 0.30, 0.55, 0.92, 1 } } }
            or { { 'ImGuiCol_Button', { 0, 0, 0, 0 } }, { 'ImGuiCol_ButtonHovered', { 0.30, 0.46, 0.72, 0.6 } } })
        local bx, by = cursor()
        if imgui.Button('  ' .. m.name .. '##hpp_mod_' .. m.id, { SIDE_W - 14, 34 }) then M.mod = m.id; SEARCH[1] = '' end
        pop_cols(nc)
        -- 2.13.0: a dot says whether the module is on (green) or off (grey)
        local st = M.mod_on(m.id)
        if st ~= nil and bx ~= nil then
            pcall(function ()
                local dl = imgui.GetWindowDrawList()
                dl:AddCircleFilled({ bx + SIDE_W - 26, by + 17 }, 4.5, Draw.u32(st and { 0.30, 0.85, 0.40, 1 } or { 0.45, 0.45, 0.48, 1 }))
            end)
            if imgui.IsItemHovered() then imgui.SetTooltip(st and 'On' or 'Off') end
        end
        imgui.Dummy({ 0, 2 })
    end
    if pushed then pcall(imgui.PopStyleVar, 1) end
    imgui.Dummy({ 0, 14 })
    imgui.TextDisabled('Search settings')
    imgui.PushItemWidth(SIDE_W - 14)
    imgui.InputText('##hpp_search', SEARCH, 64)
    imgui.PopItemWidth()
    if SEARCH[1] == nil then SEARCH[1] = '' end
    if q ~= '' then
        if imgui.Button('Clear##hpp_sclr') then SEARCH[1] = '' end
    else
        imgui.TextDisabled('e.g. font, comet,')
        imgui.TextDisabled('border, sheen')
    end
    -- 2.13.0: resets every module (it used to sit in Hideparty); click twice
    imgui.Dummy({ 0, 24 })
    imgui.Separator()
    if (hpp.now or 0) < M.reset_armed_until then
        local nc = push_cols({ { 'ImGuiCol_Button', { 0.62, 0.20, 0.20, 1 } }, { 'ImGuiCol_ButtonHovered', { 0.72, 0.24, 0.24, 1 } } })
        if imgui.Button('Click again##hpp_reset', { SIDE_W - 14, 0 }) then hpp.command({ '/pxi', 'reset' }); M.reset_armed_until = 0 end
        pop_cols(nc)
    elseif imgui.Button('Reset everything##hpp_reset', { SIDE_W - 14, 0 }) then
        M.reset_armed_until = (hpp.now or 0) + 3
    end
    tip('Every setting of every module back to the defaults, RecastXI included, for this character (click twice).')
end
-- The selected module's name and what it does, in a framed box.
local function describe(m)
    local imgui = real_imgui
    local okp, x0, y0 = pcall(imgui.GetCursorScreenPos)
    if okp and type(x0) == 'table' then x0, y0 = x0.x or x0[1], x0.y or x0[2] end
    -- 1.0.1: a filled box (drawn behind the text through a second draw channel when this ImGui has them)
    local dl0 = imgui.GetWindowDrawList()
    local split = dl0 ~= nil and pcall(function () dl0:ChannelsSplit(2); dl0:ChannelsSetCurrent(1) end)
    imgui.Dummy({ 0, 4 })
    imgui.Indent(10)
    imgui.TextColored({ 1, 1, 1, 1 }, m.name)
    -- 2.13.0: ON / OFF next to the name, and what being off means
    local st = M.mod_on(m.id)
    if st ~= nil then
        imgui.SameLine()
        imgui.TextColored(st and { 0.35, 0.90, 0.45, 1 } or { 1, 0.45, 0.40, 1 }, st and 'ON' or 'OFF')
    end
    imgui.TextWrapped(m.desc)
    if st == false then imgui.TextColored({ 1, 0.8, 0.3, 1 }, 'This module is off. ' .. (MOD_OFF[m.id] or '') .. ' Press Module: Enabled below.') end
    -- 2.13.0: its key settings, each a button that opens its tab and points it out
    local keys = M.KEYS[m.id]
    if keys ~= nil then
        imgui.TextColored(GOLD, 'Key settings:')
        for _, k in ipairs(keys) do
            imgui.SameLine()
            if imgui.SmallButton(k[1] .. '##hpp_key_' .. k[3]) then M.jump(m.id, k) end
            if imgui.IsItemHovered() then imgui.SetTooltip(#k[2] > 0 and ('Opens ' .. table.concat(k[2], ' > ') .. ' and points it out.') or 'Points it out below.') end
        end
    end
    imgui.Unindent(10)
    imgui.Dummy({ 0, 4 })
    local oke, x1, y1 = pcall(imgui.GetCursorScreenPos)
    if oke and type(x1) == 'table' then x1, y1 = x1.x or x1[1], x1.y or x1[2] end
    local okw, ww = pcall(imgui.GetContentRegionAvail)
    if okw and type(ww) == 'table' then ww = ww.x or ww[1] end
    if split then pcall(function () dl0:ChannelsSetCurrent(0) end) end
    if okp and oke and tonumber(x0) and tonumber(y0) and tonumber(y1) then
        local dl = imgui.GetWindowDrawList()
        local x2 = x0 + math.max(100, tonumber(ww) or 300)
        if split then dl:AddRectFilled({ x0, y0 }, { x2, y1 - 2 }, Draw.u32({ 26 / 255, 32 / 255, 48 / 255, 1 }), 4) end
        dl:AddRect({ x0, y0 }, { x2, y1 - 2 }, Draw.u32({ 44 / 255, 53 / 255, 80 / 255, 1 }), 4)
    end
    if split then pcall(function () dl0:ChannelsMerge() end) end
    imgui.TextDisabled('Point at a setting to frame what it changes on screen. Gold = a key setting.')
    imgui.Dummy({ 0, 4 })
end

function M.draw_body()
    local s = hpp.s
    local w = hpp.wins
    local imgui = real_imgui
    if M.want_tab ~= nil then
        for _, m in ipairs(M.MODULES) do if m.id == M.want_tab then M.mod = m.id end end
        M.want_tab = nil
    end
    local q = (SEARCH[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if JUMP ~= nil then
        if JUMP.mod ~= M.mod or q ~= '' or (now() > (JUMP.flash or 0) and (JUMP.sel or 0) <= 0) then JUMP = nil
        else JUMP.idx = 1; JUMP.sel = (JUMP.sel or 0) - 1 end
    end

    local failed
    -- every child is closed again even if its body fails, so ImGui's stacks stay balanced
    local nsb = push_cols({ { 'ImGuiCol_ChildBg', rgb(21, 25, 35) } })     -- 1.0.1: the sidebar's own darker panel
    local okc, e = pcall(begin_child, '##hpp_side', { SIDE_W, 0 })
    if not okc then pop_cols(nsb); error(e, 0) end
    local ok1, e1 = pcall(sidebar, q)
    imgui.EndChild()
    pop_cols(nsb)
    if not ok1 then failed = e1 end
    q = (SEARCH[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
    imgui.SameLine()
    begin_child('##hpp_main', { 0, 0 })
    local ok2, e2 = pcall(function ()
        if #w.errors > 0 then imgui.TextColored({ 1, 0.4, 0.4, 1 }, 'Not found: ' .. table.concat(w.errors, '; ')) end
        -- Search: every matching setting of every module in one place, under "Module > Group" headings
        if q ~= '' then
            M.set_filter(q)
            SEARCHING = true
            local fails
            local list = {
                { M.tab_hideparty, s, w }, { M.tab_pointer, s }, { info_section },
                { M.tab_partylist, s, true }, { M.tab_recast, s },
            }
            for _, en in ipairs(list) do
                local okx, err = pcall(unpack(en))
                if not okx and not fails then fails = err end
            end
            SEARCHING = false
            G.title, G.el = nil, nil
            local n = M.hits()
            M.set_filter('')
            if n == 0 then imgui.TextDisabled('No setting matches "' .. q .. '".') end
            if fails then error(fails, 0) end
            return
        end
        local mod = M.MODULES[1]
        for _, m in ipairs(M.MODULES) do if m.id == M.mod then mod = m end end
        describe(mod)
        if mod.id == 'hide' then M.tab_hideparty(s, w)
        elseif mod.id == 'pointer' then M.tab_pointer(s)
        elseif mod.id == 'list' then M.tab_partylist(s)
        elseif mod.id == 'enemy' then info_section()
        else M.tab_recast(s) end
    end)
    imgui.EndChild()
    if not ok2 and failed == nil then failed = e2 end
    G.title, G.el = nil, nil
    if failed ~= nil then error(failed, 0) end
end

-- Tab 1: which game windows are hidden, plus the addon-wide options.
function M.tab_hideparty(s, w)
    local act = M.tab_head('Hideparty', 'hide', s.enabled == true, 'Hide the ticked windows. Same as /pxi hide and /pxi show.', 'none')
    if act == 'enable' then s.enabled = not s.enabled; changed() end
    if group('Game windows##g_hide_win', 'game', nil, true) then
        imgui.TextDisabled('Ticked = hidden.')
        for i = 1, Win.FRAMES do
            local n = Win.NAMES[i]
            local state = not w:available(n) and ' (not found)' or (w.hidden[n] and ' (hidden now)' or '')
            checkbox(Win.LABELS[n] .. state .. '##win_' .. n, s.windows, n,
                n == 'target' and 'Hides the game\'s target window and also its pointer arrows (the arrows over your target and sub-target), because the game draws them as part of this window. Use the Pointer tab to get custom arrows back.' or nil)
        end
    end
end

-- Tab 2: the pointer arrows.
function M.tab_pointer(s)
    local a = s.arrow
    local testing = (hpp.now or 0) < (tonumber(hpp.preview_until) or 0)
    local act = M.tab_head('Pointer', 'ptr', a.mode ~= 'off', 'Custom arrows over your target and sub-target. Turning them off remembers where they were drawn.',
        testing, 'Shows sample arrows (one over your character) and the party list for 5 seconds.')
    if act == 'enable' then
        if a.mode == 'off' then a.mode = a.mode_on or 'auto' else a.mode_on = a.mode; a.mode = 'off' end
        changed()
    elseif act == 'test' then
        hpp.preview_until = testing and 0 or hpp.now + 5
    end
    local file = Png.file_of(a.style)
    if group('Pointer Position##g_ar_where', 'arrow', 'arrow', true) then
        local P2 = M.PTR_POS
        P2.v = (a.mode == 'entity') and 'entity' or 'native'
        radio('Position##arrow_mode', P2, 'v', PTR_MODES, MODE_LABELS,
            'Where the game puts its arrow: reads the spot the game would draw its own arrow at.\nOver the character: projects the character\'s position onto the screen, at the height below.')
        if (a.mode ~= 'off') and P2.v ~= a.mode then a.mode = P2.v; a.mode_on = P2.v; changed() end
        when(P2.v == 'entity', slider_float, 'Above the head##arrow_hgap', a, 'head_gap', -1, 3, '%.2f yalms', 'Over the character only: how far above the top of the head the arrow (and the target bar) sits. It follows each character\'s own height (Taru, Galka, mounted, sitting), like the bars over party members. Characters whose model has not loaded yet use 2.4 yalms above the feet.')
        when(P2.v ~= 'entity', function ()
            slider_int('Nudge left / right##arrow_ndx', a, 'native_dx', -64, 64, '%d px', 'Where the game puts its arrow only.')
            slider_int('Nudge down / up##arrow_ndy', a, 'native_dy', -250, 40, '%d px', 'Where the game puts its arrow only. Down (-) / up (+).', true)
        end)
        -- 2.13.0: the read-out is for troubleshooting, so it waits in a tooltip
        imgui.TextDisabled('(?) Where the arrow comes from now')
        tip(('Now: main %s, sub %s. Camera: %s.'):format(hpp.src.main, hpp.src.sub, hpp.cam.why))
    end
    if group('Pointer Style##g_ar_shape', 'arrow', 'arrow', true) then
        if imgui.Button('Rescan pictures') then hpp.command({ '/pxi', 'arrows', 'reload' }) end
        tip('Looks for .png files in addons\\partyramaxi\\icons\\arrows\\ again.')
        M.style_combo(a)
        file = Png.file_of(a.style)
        if file ~= nil then
            local e = hpp.png:get(file)
            if e.err then imgui.TextColored({ 1, 0.5, 0.4, 1 }, ('%s: %s (drawing the triangle)'):format(file, e.err)) end
        end
        when(file ~= nil, combo, 'Turn image##arrow_rot', a, 'png_rotation', ROTATIONS, ROT_LABELS, 'PNG arrows only: use this if the picture does not point down.')
        slider_int('Size##arrow_size', a, 'size', 6, 64, '%d px')
        color('Color: Sub-target##arrow_sub', a, 'sub_color', 'The arrow on whatever you are choosing with <st>, <stpt>, <stal>... A PNG arrow is tinted with it (white pictures take the color exactly).')
        imgui.SameLine()
        color('Color: Target##arrow_main', a, 'main_color', 'The arrow on the target you hold.')
        checkbox('Outline##arrow_outline', a, 'outline', 'Built-in shapes and PNG arrows (PNG: needs the picture\'s transparency).')
        when(a.outline, function ()
            imgui.SameLine(); color('##arrow_outline_col', a, 'outline_color')
            slider_int('Outline width##arrow_ot', a, 'outline_thickness', 1, 5)
        end)
    end
    if group('Pointer Animation##g_ar_anim', 'arrow', 'arrow') then
        checkbox('Pulse##arrow_pulse', a, 'pulse')
        imgui.SameLine(); checkbox('Bob##arrow_bob', a, 'bob')
        imgui.SameLine(); when(file == nil, checkbox, 'Sheen##arrow_sheen', a, 'sheen', 'A soft band of light sweeps across the arrow every 2 to 8 seconds. Built-in shapes only (not PNG arrows).')
        when(a.bob, slider_int, 'Bob height##arrow_bobamt', a, 'bob_amount', 1, 20, '%d px')
        when(a.bob or a.pulse, slider_float, 'Speed##arrow_speed', a, 'anim_speed', 0.2, 4, '%.1f /s')
        when(a.sheen and file == nil, slider_float, 'Sheen strength##arrow_shst', a, 'sheen_strength', 0.1, 1, '%.2f')
    end
end

-- Tab 4: the party list (pxilistui.lua). search = true: every matching setting of its sub-tabs.
function M.tab_partylist(s, search)
    local LU = require('pxilistui')
    if search then LU.search_all(s, M.w, hpp) else LU.draw(s, M.w, hpp) end
end

-- Opens the settings window on one tab (id after ##hpp_tab_); sub = a RecastXI sub-tab for the Recasts tab.
function M.open_tab(id, sub)
    M.open[1] = true
    M.want_tab = id
    if sub ~= nil and hpp.rx ~= nil then hpp.rx.tab_req(sub) end
end

-- 2.13.0: RecastXI's settings draw through this table (pxirecast M.set_ui): its key settings get their star or gold
-- header, and while the settings search runs only its matching settings are drawn, under "RecastXI > Tab > Section".
local RXUI
do
    local R = real_imgui
    local function hit(label) return SEARCHING and skip(label, nil) end
    local W = {}
    for _, n in ipairs({ 'Checkbox', 'SliderInt', 'SliderFloat', 'RadioButton', 'ColorEdit4', 'ColorEdit3', 'InputText', 'DragInt', 'DragFloat' }) do
        W[n] = function (label, ...)
            if hit(label) then return false end
            local k = key_pre(label)
            local a, b = R[n](label, ...)
            key_post(k)
            if SEARCHING then mark() end
            return a, b
        end
    end
    W.Selectable = function (label, ...) if hit(label) then return false end return R.Selectable(label, ...) end
    W.BeginCombo = function (label, ...)
        if hit(label) then return false end
        local k = key_pre(label)
        local r = R.BeginCombo(label, ...)
        key_post(k)
        return r
    end
    W.CollapsingHeader = function (label, ...)
        local id = key_id(label)
        if SEARCHING then
            G.n = G.n + 1
            G.title, G.shown, G.col = (tostring(label):gsub('##.*$', '')), false, GCOLS[(G.n - 1) % #GCOLS + 1]
            return true
        end
        if JUMP ~= nil and JUMP.group == id and not JUMP.opened then
            local fn = R.SetNextItemOpen or R.SetNextTreeNodeOpen
            if fn then pcall(fn, true) end
            JUMP.opened = true
        end
        local nc = 0
        if KEY[id] then nc = push_cols({ { 'ImGuiCol_Header', HOT.h }, { 'ImGuiCol_HeaderHovered', HOT.hh }, { 'ImGuiCol_HeaderActive', HOT.ha } }) end
        local r = R.CollapsingHeader(label, ...)
        pop_cols(nc)
        if JUMP ~= nil and JUMP.id == id and not JUMP.scrolled and R.SetScrollHereY then pcall(R.SetScrollHereY, 0.2); JUMP.scrolled = true end
        return r
    end
    W.Text = function (t, ...)
        if SEARCHING then return end
        local k = key_pre(t)
        R.Text(t, ...)
        key_post(k)
    end
    local QUIET = { TextDisabled = NOP, TextWrapped = NOP, TextColored = NOP, Separator = NOP, SameLine = NOP, Image = NOP,
        Button = function () return false end, SmallButton = function () return false end, TreeNode = function () return false end,
        BeginTabBar = function () return false end }
    RXUI = setmetatable(W, { __index = function (_, k)
        if SEARCHING and QUIET[k] then return QUIET[k] end
        return R[k]
    end })
end

-- Recasts tab: RecastXI as a module. The PartyramaXI groups (placement, frame) come first; RecastXI's own
-- settings tabs follow in a scrolling box (its widgets, not this window's, so they do not take part in search).
local RX_PLACE = { 'on', 'off' }
local RX_PLACE_LABELS = { on = 'Attached above the party list', off = 'Separate window' }
local RX_FRAME = { 'own', 'list' }
local RX_FRAME_LABELS = { own = 'Its own theme', list = 'The party list\'s background and border' }
local RXP = { v = 'on' }
local RX_EXTRA = {}
function M.tab_recast(s)
    local Rx = hpp.rx                                   -- pxirecast, set by partyramaxi.lua
    local R = Rx ~= nil and Rx.settings() or nil
    if R == nil then imgui.TextDisabled('The RecastXI module did not start (see the chat log).'); return end
    local act = M.tab_head('RecastXI', 'rx', R.enabled == true, 'Spell and ability recast timers (RecastXI built in). Same as /pxi recast on | off.',
        Rx.testing(), 'Shows sample timers until you press this again.')
    if act == 'enable' then R.enabled = not R.enabled; Rx.mark_dirty()
    elseif act == 'test' then Rx.set_test(not Rx.testing()) end
    local why = Rx.hidden_reason()
    if why and not SEARCHING then imgui.TextColored({ 1, 0.8, 0.3, 1 }, why) end
    local function placement()
        if group('Placement##g_rx_place', 'recast', 'window', true) then
            RXP.v = R.attach and 'on' or 'off'
            radio('Where##rx_attach', RXP, 'v', RX_PLACE, RX_PLACE_LABELS, 'Attached: it sits above the party list at the list\'s width, follows it when the list moves or grows, and slides up out of the list (and back down into it) when it shows and hides. Separate: its own window you can drag (General > Lock window).')
            if (RXP.v == 'on') ~= (R.attach == true) then Rx.set_attach(RXP.v == 'on') end
            when(R.attach, function ()
                local g = R.attach_gap
                slider_int('Space above the list##rx_gap', R, 'attach_gap', 20, 600, '%d px', 'The gap between the top of the party list and the bottom of the tracker.')
                if R.attach_gap ~= g then Rx.mark_dirty() end
                if not SEARCHING then imgui.TextDisabled('Width: the party list\'s (Party list > Appearance > Cards). While the party list is off or not showing, the tracker stays where it last sat.') end
            end)
        end
    end
    local function frame()
        if group('Frame##g_rx_frame', 'recast', 'window', true) then
            local f = R.frame_src
            radio('Background and border##rx_frame', R, 'frame_src', RX_FRAME, RX_FRAME_LABELS, 'Its own theme: the RecastXI theme\'s frame, header texture and glow (settings below). The party list\'s: the background and border set in Party list > Appearance; the RecastXI theme still colors the text and bars.')
            if R.frame_src ~= f then Rx.mark_dirty() end
        end
    end
    local function pics()
        if group('Element and magic type pictures##g_rx_pics', 'recast', 'window', true) then
            pack_combo('Icon Pack##rx_icon_style', s.info, M.STYLE_HELP .. ' Same setting as Target bar > Enemies > Monster info > Icon Pack.')
            if not SEARCHING then imgui.TextDisabled('Shared with Target bar > Enemies > Monster info.') end
        end
    end
    -- 2.9.2: RecastXI's own tabs right under the Enabled / Test buttons; the PartyramaXI groups lead General.
    -- 2.13.0: the Frame follows the Theme in Appearance; the pictures lead Icons; its settings are searchable.
    RX_EXTRA.tab_general, RX_EXTRA.tab_visuals, RX_EXTRA.after_theme = placement, pics, frame
    Rx.tab_item = M.sub_tab_item
    if Rx.set_ui then Rx.set_ui(RXUI) end
    if SEARCHING then
        if Rx.config_search then Rx.config_search(RX_EXTRA, function (name) G.tab = 'RecastXI  >  ' .. name; G.title = nil end)
        else placement(); frame(); pics() end
        return
    end
    Rx.config_body(RX_EXTRA)
end

function M.draw(h)
    if not M.open[1] then hpp.preview_hold = false; hpp.list_test = false; hpp.list_test_anim = false; hpp.list_test_hl = false; hpp.list_edit = false; return end
    -- 2.11.0: a sized window (sidebar + scrolling settings) instead of one that grows with its contents
    local dh = (hpp.disp_h and hpp.disp_h > 0) and hpp.disp_h or 900
    imgui.SetNextWindowSize({ 680, math.floor(math.min(820, dh * 0.8)) }, ImGuiCond_FirstUseEver)
    if imgui.SetNextWindowSizeConstraints then
        pcall(imgui.SetNextWindowSizeConstraints, { 540, 300 }, { 1400, math.floor(dh * 0.95) })
    end
    local ok, e = true, nil
    -- 2.7.0: the window only moves when dragged by its title bar. ImGui also moves a window dragged by any empty spot,
    -- which made it wander when a drag started next to a slider or in a gap between settings.
    local flags = 0
    local mok, mx, my = pcall(imgui.GetMousePos)
    if mok and type(mx) == 'table' then mx, my = mx.x or mx[1], mx.y or mx[2] end
    mx, my = tonumber(mx), tonumber(my)
    local T = M.title
    local on_title = T ~= nil and mx ~= nil and my ~= nil and mx >= T[1] and mx <= T[3] and my >= T[2] and my <= T[4]
    local dok, down = pcall(imgui.IsMouseDown, 0)
    down = dok and down == true
    if not down then M.title_drag = on_title elseif on_title and M.title_drag == nil then M.title_drag = true end
    if not (on_title or (down and M.title_drag)) and rawget(_G, 'ImGuiWindowFlags_NoMove') ~= nil then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove)
    end
    local font = ui_font()                                  -- 1.0.1: Inter, at the size ImGui uses now
    local fsz = 0
    if font ~= nil then local okf, fz = pcall(real_imgui.GetFontSize); fsz = (okf and tonumber(fz)) or 0 end
    local fpushed = font ~= nil and fsz > 0 and Fonts.push(font, fsz)
    local nwc, nwv = push_cols(WIN_COLS), push_vars()      -- 2.9.2 / 1.0.1: the window's palette and shapes
    style_install()
    if imgui.Begin('PartyramaXI##partyramaxi_cfg', M.open, flags) then
        pcall(function ()
            local wx, wy = imgui.GetWindowPos()
            if type(wx) == 'table' then wx, wy = wx.x or wx[1], wx.y or wx[2] end
            local ww = imgui.GetWindowWidth and imgui.GetWindowWidth() or 420
            local th = imgui.GetFrameHeight and imgui.GetFrameHeight() or 20
            if tonumber(wx) and tonumber(wy) then M.title = { wx, wy, wx + (tonumber(ww) or 420), wy + (tonumber(th) or 20) } end
        end)
        ok, e = pcall(M.draw_body)
    end
    imgui.End()           -- always paired with Begin, even if the body failed
    FOLD = nil
    M.style_remove()
    pop_cols(nwc); if nwv > 0 then pcall(real_imgui.PopStyleVar, nwv) end
    if fpushed then Fonts.pop() end
    SEARCHING = false     -- a failed search must not leave the filter on for the next frame
    if not ok then
        M.open[1] = false
        hpp.err('The settings window hit an error and was closed: ' .. tostring(e))
    end
    if not M.open[1] then hpp.flush_save() end
end

M.w = { tip = tip, checkbox = checkbox, slider_int = slider_int, slider_float = slider_float, color = color, combo = combo, dropdown = dropdown,
        radio = radio, group = group, mark = mark, tab_head = M.tab_head, HOT = HOT, sub_tabs = sub_tabs,
        set_filter = M.set_filter, hits = M.hits, skip = M.skip, changed = changed, when = when, sub_head = M.sub_head,
        dis = function () return DIS end, heading = heading, fold_next = fold_next }

return M
