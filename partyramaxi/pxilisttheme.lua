--[[
* PartyramaXI - party list themes.
*
* A theme is a preset: choosing one copies its colors, rounding and bar finish into the party list settings,
* after which every value can still be changed by hand (each bar has its own color pickers). Window
* background PNGs are separate (Theme tab -> Background) and work with any theme.
--]]
local M = {}

local function C(r, g, b, a) return { r, g, b, a or 1 } end

-- bar = { fill, warn, low, back, border } (warn / low are only used by the health bar's "color by health")
local function bars(hp, mp, tp, common)
    return { hp = hp, mp = mp, tp = tp, common = common }
end

M.THEMES = {
    {
        name = 'Midnight',
        win  = { bg = C(0.05, 0.06, 0.09, 0.90), border = C(0.22, 0.27, 0.40, 1), border_w = 1, rounding = 7 },
        card = { bg = C(0.10, 0.12, 0.18, 0.88), border = C(0.17, 0.21, 0.31, 1), rounding = 5 },
        text = { name = C(0.96, 0.97, 1.00, 1), job = C(0.58, 0.67, 0.86, 1), head = C(0.46, 0.58, 0.82, 1), action = C(0.78, 0.86, 1.00, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(0.99, 0.82, 0.09, 1), select = C(0.38, 0.78, 1.00, 1) },
        bars = bars(
            { fill = C(0.26, 0.78, 0.44, 1), warn = C(0.96, 0.80, 0.24, 1), low = C(0.92, 0.26, 0.26, 1) },
            { fill = C(0.30, 0.54, 0.96, 1) },
            { fill = C(0.58, 0.46, 0.94, 1), full = C(1.00, 0.78, 0.25, 1) },
            { back = C(0, 0, 0, 0.55), border = C(0, 0, 0, 0.90), rounding = 4, gloss = 'glossy', gloss_strength = 0.50 }),
    },
    {
        name = 'Vana\'diel Blue',
        win  = { bg = C(0.06, 0.08, 0.34, 0.93), border = C(0.86, 0.89, 1.00, 1), border_w = 2, rounding = 5 },
        card = { bg = C(0.03, 0.05, 0.24, 0.72), border = C(0.42, 0.48, 0.80, 1), rounding = 3 },
        text = { name = C(1, 1, 1, 1), job = C(0.78, 0.84, 1.00, 1), head = C(0.86, 0.90, 1.00, 1), action = C(1.00, 0.96, 0.78, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(1.00, 0.90, 0.30, 1), select = C(0.55, 0.95, 1.00, 1) },
        bars = bars(
            { fill = C(0.46, 0.88, 0.46, 1), warn = C(1.00, 0.85, 0.30, 1), low = C(1.00, 0.35, 0.30, 1) },
            { fill = C(0.50, 0.70, 1.00, 1) },
            { fill = C(0.80, 0.84, 1.00, 1), full = C(1.00, 0.88, 0.40, 1) },
            { back = C(0, 0, 0.12, 0.60), border = C(0.80, 0.84, 1.00, 0.75), rounding = 2, gloss = 'gradient', gloss_strength = 0.45 }),
    },
    {
        name = 'Steel',
        win  = { bg = C(0.13, 0.14, 0.16, 0.95), border = C(0.52, 0.55, 0.60, 1), border_w = 1, rounding = 3 },
        card = { bg = C(0.19, 0.20, 0.23, 0.95), border = C(0.30, 0.32, 0.36, 1), rounding = 2 },
        text = { name = C(0.92, 0.93, 0.95, 1), job = C(0.66, 0.69, 0.74, 1), head = C(0.62, 0.66, 0.72, 1), action = C(0.88, 0.90, 0.94, 1) },
        sel  = { target = C(0.95, 0.96, 1, 1), cursor = C(1.00, 0.76, 0.20, 1), select = C(0.45, 0.78, 0.95, 1) },
        bars = bars(
            { fill = C(0.42, 0.74, 0.46, 1), warn = C(0.90, 0.76, 0.28, 1), low = C(0.86, 0.30, 0.28, 1) },
            { fill = C(0.38, 0.58, 0.86, 1) },
            { fill = C(0.64, 0.66, 0.74, 1), full = C(0.96, 0.78, 0.30, 1) },
            { back = C(0.04, 0.04, 0.05, 0.85), border = C(0.02, 0.02, 0.03, 1), rounding = 1, gloss = 'gradient', gloss_strength = 0.65 }),
    },
    {
        name = 'Verdant',
        win  = { bg = C(0.04, 0.10, 0.08, 0.92), border = C(0.28, 0.62, 0.42, 1), border_w = 1, rounding = 8 },
        card = { bg = C(0.07, 0.17, 0.13, 0.88), border = C(0.14, 0.32, 0.24, 1), rounding = 6 },
        text = { name = C(0.92, 1.00, 0.95, 1), job = C(0.56, 0.80, 0.66, 1), head = C(0.44, 0.78, 0.58, 1), action = C(0.84, 1.00, 0.88, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(1.00, 0.86, 0.30, 1), select = C(0.40, 1.00, 0.70, 1) },
        bars = bars(
            { fill = C(0.30, 0.86, 0.50, 1), warn = C(0.92, 0.84, 0.28, 1), low = C(0.94, 0.34, 0.28, 1) },
            { fill = C(0.28, 0.72, 0.90, 1) },
            { fill = C(0.74, 0.58, 0.98, 1), full = C(1.00, 0.82, 0.30, 1) },
            { back = C(0, 0.04, 0.02, 0.60), border = C(0, 0.05, 0.02, 0.95), rounding = 6, gloss = 'glossy', gloss_strength = 0.45 }),
    },
    {
        name = 'Crimson',
        win  = { bg = C(0.09, 0.04, 0.05, 0.92), border = C(0.66, 0.20, 0.22, 1), border_w = 1, rounding = 4 },
        card = { bg = C(0.16, 0.07, 0.08, 0.88), border = C(0.34, 0.12, 0.14, 1), rounding = 3 },
        text = { name = C(1.00, 0.95, 0.94, 1), job = C(0.86, 0.60, 0.58, 1), head = C(0.90, 0.46, 0.44, 1), action = C(1.00, 0.88, 0.80, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(1.00, 0.78, 0.22, 1), select = C(1.00, 0.52, 0.42, 1) },
        bars = bars(
            { fill = C(0.34, 0.80, 0.42, 1), warn = C(0.96, 0.76, 0.22, 1), low = C(0.96, 0.24, 0.22, 1) },
            { fill = C(0.34, 0.54, 0.92, 1) },
            { fill = C(0.92, 0.50, 0.38, 1), full = C(1.00, 0.84, 0.30, 1) },
            { back = C(0.04, 0, 0, 0.65), border = C(0, 0, 0, 0.95), rounding = 2, gloss = 'shine', gloss_strength = 0.55 }),
    },
    {
        name = 'Minimal',
        win  = { bg = C(0, 0, 0, 0), border = C(0, 0, 0, 0), border_w = 0, rounding = 0 },
        card = { bg = C(0, 0, 0, 0.38), border = C(1, 1, 1, 0.07), rounding = 2 },
        text = { name = C(1, 1, 1, 1), job = C(0.78, 0.80, 0.84, 1), head = C(0.70, 0.74, 0.80, 1), action = C(0.92, 0.94, 1, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(1.00, 0.84, 0.24, 1), select = C(0.50, 0.85, 1.00, 1) },
        bars = bars(
            { fill = C(0.40, 0.84, 0.52, 1), warn = C(0.95, 0.82, 0.30, 1), low = C(0.95, 0.32, 0.30, 1), h = 10 },
            { fill = C(0.42, 0.62, 0.95, 1), h = 6 },
            { fill = C(0.70, 0.62, 0.95, 1), full = C(1.00, 0.82, 0.30, 1), h = 6 },
            { back = C(1, 1, 1, 0.10), border = C(0, 0, 0, 0), rounding = 1, gloss = 'none', gloss_strength = 0.4, border_on = false }),
    },
}


-- Gradient themes: a vertical window gradient (top > bottom), a border style and fitting bar colors.
local function grad(name, o)
    local b = o.bar
    return {
        name = name,
        win  = { bg = o.top, bg2 = o.bot, grad = true, border = o.border, border_w = o.bw or 1, rounding = o.round or 9, style = o.style or 'line', lines = o.lines or 0 },
        card = { bg = o.card, border = o.cardb, rounding = (o.round or 9) - 3 },
        text = { name = o.name, job = o.job, head = o.head, action = o.action or o.name },
        sel  = { target = C(1, 1, 1, 1), cursor = o.cursor or C(1.00, 0.84, 0.28, 1), select = o.select or C(0.50, 0.85, 1.00, 1) },
        bars = bars(
            { fill = b.hp, warn = C(0.98, 0.82, 0.30, 1), low = C(0.95, 0.30, 0.30, 1) },
            { fill = b.mp },
            { fill = b.tp, full = b.full },
            { back = o.back or C(0, 0, 0, 0.50), border = o.barb or C(0, 0, 0, 0.8), rounding = o.bround or 5, gloss = o.gloss or 'glossy', gloss_strength = 0.45 }),
    }
end
table.insert(M.THEMES, 1, grad('Aurora', {
    top = C(0.05, 0.12, 0.20, 0.94), bot = C(0.10, 0.05, 0.22, 0.94), border = C(0.45, 0.85, 0.90, 0.9), style = 'glow', bw = 2, round = 12,
    card = C(0.06, 0.12, 0.22, 0.60), cardb = C(0.40, 0.80, 0.90, 0.22), name = C(0.94, 1, 1, 1), job = C(0.60, 0.82, 0.92, 1), head = C(0.55, 0.90, 0.85, 1),
    bar = { hp = C(0.35, 0.90, 0.62, 1), mp = C(0.38, 0.62, 1.00, 1), tp = C(0.72, 0.52, 1.00, 1), full = C(1.00, 0.86, 0.40, 1) } }))
table.insert(M.THEMES, 2, grad('Gilded', {
    top = C(0.12, 0.09, 0.06, 0.95), bot = C(0.06, 0.04, 0.03, 0.95), border = C(0.86, 0.68, 0.32, 1), style = 'gilded', bw = 2, round = 6,
    card = C(0.17, 0.12, 0.08, 0.80), cardb = C(0.55, 0.42, 0.20, 0.55), name = C(1.00, 0.96, 0.86, 1), job = C(0.84, 0.72, 0.50, 1), head = C(0.92, 0.76, 0.40, 1),
    bar = { hp = C(0.52, 0.80, 0.36, 1), mp = C(0.40, 0.62, 0.92, 1), tp = C(0.90, 0.62, 0.30, 1), full = C(1.00, 0.90, 0.45, 1) }, gloss = 'gradient' }))
table.insert(M.THEMES, 3, grad('Frost', {
    top = C(0.82, 0.90, 0.97, 0.88), bot = C(0.55, 0.68, 0.84, 0.88), border = C(1, 1, 1, 0.85), style = 'bevel', bw = 2, round = 10,
    card = C(1, 1, 1, 0.30), cardb = C(1, 1, 1, 0.50), name = C(0.08, 0.14, 0.26, 1), job = C(0.22, 0.32, 0.50, 1), head = C(0.16, 0.30, 0.52, 1), cursor = C(0.95, 0.60, 0.10, 1), select = C(0.10, 0.45, 0.85, 1),
    back = C(0.1, 0.2, 0.35, 0.35), barb = C(1, 1, 1, 0.55),
    bar = { hp = C(0.20, 0.72, 0.46, 1), mp = C(0.22, 0.46, 0.90, 1), tp = C(0.55, 0.40, 0.88, 1), full = C(0.95, 0.65, 0.12, 1) } }))
table.insert(M.THEMES, 4, grad('Ember', {
    top = C(0.16, 0.06, 0.05, 0.94), bot = C(0.07, 0.03, 0.04, 0.94), border = C(0.95, 0.48, 0.20, 0.95), style = 'glow', bw = 2, round = 8, lines = 0.06,
    card = C(0.22, 0.09, 0.07, 0.70), cardb = C(0.80, 0.35, 0.18, 0.30), name = C(1.00, 0.95, 0.88, 1), job = C(0.92, 0.66, 0.50, 1), head = C(1.00, 0.58, 0.30, 1),
    bar = { hp = C(0.45, 0.84, 0.38, 1), mp = C(0.36, 0.58, 0.95, 1), tp = C(1.00, 0.55, 0.30, 1), full = C(1.00, 0.88, 0.40, 1) } }))
table.insert(M.THEMES, 5, grad('Sakura', {
    top = C(0.25, 0.14, 0.22, 0.92), bot = C(0.14, 0.09, 0.18, 0.92), border = C(1.00, 0.72, 0.82, 0.9), style = 'double', bw = 1, round = 14,
    card = C(0.32, 0.18, 0.28, 0.60), cardb = C(1.00, 0.72, 0.82, 0.30), name = C(1.00, 0.95, 0.97, 1), job = C(0.94, 0.70, 0.80, 1), head = C(1.00, 0.76, 0.86, 1), bround = 8,
    bar = { hp = C(0.60, 0.90, 0.60, 1), mp = C(0.55, 0.72, 1.00, 1), tp = C(0.98, 0.62, 0.82, 1), full = C(1.00, 0.88, 0.50, 1) } }))
table.insert(M.THEMES, 6, grad('Slate Corners', {
    top = C(0.12, 0.14, 0.17, 0.92), bot = C(0.08, 0.09, 0.11, 0.92), border = C(0.70, 0.76, 0.84, 1), style = 'corners', bw = 2, round = 3, lines = 0.05,
    card = C(0.17, 0.19, 0.23, 0.80), cardb = C(0.35, 0.38, 0.44, 0.7), name = C(0.94, 0.96, 1, 1), job = C(0.62, 0.68, 0.78, 1), head = C(0.70, 0.78, 0.90, 1), bround = 2, gloss = 'gradient',
    bar = { hp = C(0.42, 0.78, 0.50, 1), mp = C(0.38, 0.62, 0.92, 1), tp = C(0.68, 0.66, 0.90, 1), full = C(1.00, 0.80, 0.30, 1) } }))


-- Layered PNG themes (pieces live in backgrounds\): the window look comes from the pictures, the cards sit lightly on top.
local function F(prefix, parts, extra)
    local t = { bg = prefix .. '_bg.png', scale = 0.5, inset = 0, fit = 'stretch', tile = 1 }
    for _, k in ipairs(parts) do t[k] = prefix .. '_' .. (({ tl = 'tl', tr = 'tr', bl = 'bl', br = 'br', top = 'top', bottom = 'bottom', left = 'left', right = 'right' })[k]) .. '.png' end
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end
local ALL8 = { 'top', 'bottom', 'left', 'right', 'tl', 'tr', 'bl', 'br' }
local TB = { 'top', 'bottom' }
local function framed(name, frame, tint)
    return {
        name = name, frame = frame,
        win  = { bg = C(0, 0, 0, 0), border = C(0, 0, 0, 0), border_w = 0, rounding = 0 },
        card = { bg = C(0, 0, 0, 0.30), border = C(1, 1, 1, 0.10), rounding = 3 },
        text = { name = C(1, 1, 1, 1), job = C(0.80, 0.84, 0.96, 1), head = C(0.88, 0.90, 1.00, 1), action = C(1.00, 0.97, 0.82, 1) },
        sel  = { target = C(1, 1, 1, 1), cursor = C(1.00, 0.88, 0.30, 1), select = C(0.55, 0.95, 1.00, 1) },
        bars = bars(
            { fill = C(0.46, 0.88, 0.46, 1), warn = C(1.00, 0.85, 0.30, 1), low = C(1.00, 0.35, 0.30, 1) },
            { fill = C(0.50, 0.70, 1.00, 1) },
            { fill = C(0.80, 0.84, 1.00, 1), full = C(1.00, 0.88, 0.40, 1) },
            { back = C(0, 0, 0.10, 0.55), border = C(0.80, 0.84, 1.00, 0.55), rounding = 3, gloss = 'gradient', gloss_strength = 0.45 }),
    }
end
local FRAMED = {
    framed('Classic Scanline', F('classic', ALL8, { fit = 'tile', tile = 0.5 }, nil)),
    framed('Vana\'diel Gradient', F('vdblue', ALL8)),
    framed('Dusk', F('dusk', TB)),
    framed('Smoke', F('smoke', TB)),
    framed('Void', F('void', TB)),
}
FRAMED[1].frame.bg = 'classic_scanline_bg.png'
for _, t in ipairs(FRAMED) do M.THEMES[#M.THEMES + 1] = t end

M.CUSTOM = 'Custom'            -- not a preset: choosing it keeps every value as it is
M.NAMES = { M.CUSTOM }
for _, t in ipairs(M.THEMES) do M.NAMES[#M.NAMES + 1] = t.name end

function M.find(name)
    for _, t in ipairs(M.THEMES) do if t.name == name then return t end end
    return nil
end

local DEFH = { hp = 14, mp = 9, tp = 9 }
local function setc(dst, src)
    if type(dst) ~= 'table' or type(src) ~= 'table' then return end
    dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4]
end

-- Copies a theme into the party list settings table L. Returns false for an unknown name.
function M.apply(L, name)
    if name == M.CUSTOM then L.theme = M.CUSTOM; return true end
    local t = M.find(name)
    if t == nil then return false end
    L.theme = t.name
    if t.frame then
        L.bg.mode = 'frame'
        for _, k in ipairs({ 'bg', 'top', 'bottom', 'left', 'right', 'tl', 'tr', 'bl', 'br' }) do L.bg.frame[k] = t.frame[k] or '' end
        L.bg.frame.fit, L.bg.frame.tile, L.bg.frame.scale, L.bg.frame.inset = t.frame.fit, t.frame.tile, t.frame.scale, t.frame.inset
        L.bg.scope = 'window'
    elseif L.bg.mode == 'frame' or L.bg.mode == 'png' then
        L.bg.mode = 'color'
    end
    setc(L.win.bg, t.win.bg); setc(L.win.border, t.win.border)
    L.win.grad, L.win.style, L.win.lines = t.win.grad == true, t.win.style or 'line', t.win.lines or 0
    if t.win.bg2 then setc(L.win.bg2, t.win.bg2) else setc(L.win.bg2, t.win.bg) end
    L.win.border_w, L.win.rounding = t.win.border_w, t.win.rounding
    setc(L.card.bg, t.card.bg); setc(L.card.border, t.card.border); L.card.rounding = t.card.rounding
    setc(L.name.color, t.text.name); setc(L.job.color, t.text.job)
    setc(L.head.color, t.text.head); setc(L.action.color, t.text.action)
    setc(L.sel.target, t.sel.target); setc(L.sel.cursor, t.sel.cursor); setc(L.sel.select, t.sel.select)
    for _, key in ipairs({ 'hp', 'mp', 'tp' }) do
        local b, src, com = L[key], t.bars[key], t.bars.common
        setc(b.fill, src.fill)
        if src.warn then setc(b.warn, src.warn) end
        if src.low then setc(b.low, src.low) end
        if src.full then setc(b.full, src.full) end
        setc(b.back, com.back); setc(b.border, com.border)
        b.rounding, b.gloss, b.gloss_strength = com.rounding, com.gloss, com.gloss_strength
        if com.border_on ~= nil then b.border_on = com.border_on else b.border_on = true end
        b.height = src.h or DEFH[key]
    end
    return true
end

return M
