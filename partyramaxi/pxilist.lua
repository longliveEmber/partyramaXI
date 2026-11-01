--[[
* PartyramaXI - the party list: cards for every party / alliance member with job, bars, current
* action and status effects. Drawn with the window's draw list, so everything is one ImGui window.
*
* Per frame: read members -> work out each card's height -> size the window -> draw background, cards.
* Settings live in hpp.s.list (see pxidefaults.lua); themes are presets for them (pxilisttheme.lua).
--]]
local imgui = require('imgui')
local Draw  = require('pxidraw')
local Info  = require('pxiinfo')
local Fonts = require('pxifonts')
local Fx    = require('pxifx')
local Data  = require('pxilistdata')
local Buffs = require('pxibuffs')
local ffi   = require('ffi')

local M = {}
local K = {}          -- constants and scratch tables of this module, in one table to stay well under the 200-locals limit
local hpp
function M.init(h) hpp = h end

M.sel = -1                 -- slot picked by cycling (/pxi list next | prev), or -1
M.order = {}               -- visible slots in display order (for cycling)
M.norder = 0
M.broken = false
M.png_bg = nil             -- Png instance for window backgrounds (set by the main file)
M.png_job = nil            -- Png instance for job icons

local BASE = 14
local GA = 1               -- opacity of the card being drawn (out of zone)
local EA = 1               -- opacity of the entry being drawn (fades while it joins / leaves)
local P1, P2, P3 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local COL = { 0, 0, 0, 1 }
local MIX = { 0, 0, 0, 1 }
local W1, B1 = { 1, 1, 1, 1 }, { 0, 0, 0, 1 }
local TOP, BOTTOM = 48, 192          -- ImDrawFlags_RoundCornersTop / Bottom
K.ROLEKEYS = { 'leader', 'aleader', 'qm' }
K.ROLEFLAG = { leader = 'leader', aleader = 'aleader', qm = 'qm' }
K.ROLELETTER = { leader = 'L', aleader = 'A', qm = 'Q' }
local NPX, NPY = {}, {}          -- per slot (1-18): left edge of the card and the vertical centre of its name (for the pointer)

---------------------------------------------------------------------------
-- Colors and primitives
---------------------------------------------------------------------------
local function u32(c, a)
    COL[1], COL[2], COL[3], COL[4] = c[1], c[2], c[3], (c[4] or 1) * (a or 1) * GA
    return Draw.u32(COL)
end
local function white(a) W1[4] = a * GA; return Draw.u32(W1) end
local function black(a) B1[4] = a * GA; return Draw.u32(B1) end
local function mix(a, b, t)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    MIX[1], MIX[2], MIX[3], MIX[4] = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t
    return MIX
end

local flags_ok = nil              -- does AddRectFilled take the corner flags? learned on first use
local function rect(dl, x0, y0, x1, y1, col, r, flags)
    if x1 <= x0 or y1 <= y0 then return end
    P1[1], P1[2], P2[1], P2[2] = x0, y0, x1, y1
    if flags and r > 0 and flags_ok ~= false then
        if flags_ok then dl:AddRectFilled(P1, P2, col, r, flags); return end
        flags_ok = pcall(dl.AddRectFilled, dl, P1, P2, col, r, flags)
        if flags_ok then return end
    end
    dl:AddRectFilled(P1, P2, col, r)
end
local function frame(dl, x0, y0, x1, y1, col, r, th)
    if th <= 0 or x1 <= x0 or y1 <= y0 then return end
    P1[1], P1[2], P2[1], P2[2] = x0, y0, x1, y1
    dl:AddRect(P1, P2, col, r, 0, th)
end

-- A quarter (or any) arc as short lines: centre cx, cy, radius r, from angle a0 to a1 (radians, y down).
function K.arc(dl, cx, cy, r, a0, a1, col, th)
    if r <= 0.5 or th <= 0 then return end
    local n = math.max(4, math.min(16, math.floor(r / 2)))
    local px, py = cx + r * math.cos(a0), cy + r * math.sin(a0)
    for i = 1, n do
        local a = a0 + (a1 - a0) * i / n
        local nx, ny = cx + r * math.cos(a), cy + r * math.sin(a)
        P1[1], P1[2], P2[1], P2[2] = px, py, nx, ny
        dl:AddLine(P1, P2, col, th)
        px, py = nx, ny
    end
end
K.PI, K.HPI = math.pi, math.pi / 2

K.QA, K.QB, K.QC, K.QD = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
K.UA, K.UB, K.UC, K.UD = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
local function image(dl, id, x0, y0, x1, y1, u0, v0, u1, v1, col)
    if x1 <= x0 or y1 <= y0 then return end
    K.QA[1], K.QA[2], K.QB[1], K.QB[2], K.QC[1], K.QC[2], K.QD[1], K.QD[2] = x0, y0, x1, y0, x1, y1, x0, y1
    K.UA[1], K.UA[2], K.UB[1], K.UB[2], K.UC[1], K.UC[2], K.UD[1], K.UD[2] = u0, v0, u1, v0, u1, v1, u0, v1
    dl:AddImageQuad(id, K.QA, K.QB, K.QC, K.QD, K.UA, K.UB, K.UC, K.UD, col)
end

-- A picture stretched over a rectangle, or cut in nine (corners keep their size) when m > 0 (m = pixels of the PNG).
-- size: how big the corners are drawn on screen (default: the same m pixels).
local function panel_image(dl, t, x0, y0, x1, y1, m, col, size)
    local iw, ih = t.w, t.h
    m = math.floor(tonumber(m) or 0)
    if m <= 0 or iw < 3 or ih < 3 then image(dl, t.id, x0, y0, x1, y1, 0, 0, 1, 1, col); return end
    m = math.min(m, math.floor((iw - 1) / 2), math.floor((ih - 1) / 2))
    local dm = math.min(tonumber(size) or m, (x1 - x0) / 2, (y1 - y0) / 2)
    local um, vm = m / iw, m / ih
    local xs = { x0, x0 + dm, x1 - dm, x1 }
    local ys = { y0, y0 + dm, y1 - dm, y1 }
    local us = { 0, um, 1 - um, 1 }
    local vs = { 0, vm, 1 - vm, 1 }
    for j = 1, 3 do
        for i = 1, 3 do image(dl, t.id, xs[i], ys[j], xs[i + 1], ys[j + 1], us[i], vs[j], us[i + 1], vs[j + 1], col) end
    end
end

---------------------------------------------------------------------------
-- Text. Font size is a multiple of the base size. Every element can have its own font: FONT[key] is looked up
-- (and loaded) once per frame before the window is begun; text() draws with it (Info.text_at: shadow / outline).
---------------------------------------------------------------------------
local ST = Info.ST
local FONT = {}
local WHITEC = { 1, 1, 1, 1 }
local BARFK = {}                 -- bar table -> font key of that bar's numbers
local CURNOW = 0
for _, k in ipairs({ 'base', 'name', 'job', 'head', 'ptext', 'action', 'num', 'hpnum', 'mpnum', 'tpnum' }) do FONT[k] = { font = nil, faux = false } end

local function resolve_fonts(L)
    local function put(key, name, bold, italic)
        local f, faux = Fonts.fetch(name, bold, italic)
        local e = FONT[key]
        e.font, e.faux = f, faux
    end
    local base, bb, bi = L.font, L.bold == true, L.italic == true
    put('base', base, bb, bi)
    local function el(key, t)
        if t.font ~= nil and t.font ~= '' then put(key, t.font, t.bold == true, t.italic == true)
        else put(key, base, bb or t.bold == true, bi or t.italic == true) end
    end
    el('name', L.name); el('job', L.job); el('head', L.head); el('ptext', L.ptext); el('action', L.action)
    local nf = (L.numfont ~= nil and L.numfont ~= '') and L.numfont or base
    local own = (L.numfont ~= nil and L.numfont ~= '')
    put('num', nf, (own and L.numbold == true) or (not own and (bb or L.numbold == true)), bi)
    for _, k in ipairs({ 'hp', 'mp', 'tp' }) do
        local b = L[k]
        local fk = k .. 'num'
        BARFK[b] = fk
        if b.font ~= nil and b.font ~= '' then put(fk, b.font, b.bold == true, b.italic == true)
        else put(fk, nf, b.bold == true or bb or (own and L.numbold == true), b.italic == true or bi) end
    end
end

local function tsize(s)
    local a, b = imgui.CalcTextSize(s)
    if type(a) == 'table' or type(a) == 'userdata' then return tonumber(a.x or a[1]) or 0, tonumber(a.y or a[2]) or 0 end
    return tonumber(a) or 0, tonumber(b) or 0
end
local function pushf(scale, fk)
    local e = FONT[fk or 'base']
    local f = e and e.font
    if scale == 1 and f == nil then return false end
    return Fonts.push(f or imgui.GetFont(), BASE * scale)
end

-- Text widths are cached per (font, size, string): measuring text is the most expensive thing a frame does and almost every
-- string repeats from frame to frame. The cache is dropped when the font size of the game changes or it grows large.
local TX = { wc = {}, n = 0, fs = 0 }
local function wcache(fk, scale)
    local e = FONT[fk or 'base']
    local f = (e and e.font) or false
    local a = TX.wc[f]
    if a == nil then a = {}; TX.wc[f] = a end
    local b = a[scale]
    if b == nil then
        TX.n = TX.n + 1
        if TX.n > 120 then TX.wc = {}; TX.n = 1; a = {}; TX.wc[f] = a end
        b = { w = {}, t = {}, n = 0, h = 0 }
        a[scale] = b
    end
    return b
end
function M.wcheck()                           -- once per frame
    local ok, fs = pcall(imgui.GetFontSize)
    fs = ok and tonumber(fs) or 0
    if fs ~= TX.fs then TX.fs = fs; TX.wc, TX.n = {}, 0 end
end

-- width, height of s in the font of fk at scale
local function sized_text(s, scale, fk)
    local b = wcache(fk, scale)
    local w = b.w[s]
    if w == nil then
        local pushed = pushf(scale, fk)
        local hh
        w, hh = tsize(s)
        if pushed then Fonts.pop() end
        if b.n > 800 then b.w, b.t, b.n = {}, {}, 0 end
        b.w[s] = w; b.h = hh; b.n = b.n + 1
    end
    return w, b.h, b
end

-- s trimmed to maxw with ".." (when it is wider), and its width
local function trimmed(s, scale, maxw, fk)
    local w, h, b = sized_text(s, scale, fk)
    if not (maxw and w > maxw) then return s, w, h end
    local c = b.t[s]
    if c ~= nil and c.mw == maxw then return c.s, c.w, h end
    local pushed = pushf(scale, fk)
    local n = #s
    while n > 1 do
        n = n - 1
        if tsize(s:sub(1, n) .. '..') <= maxw then break end
    end
    local s2 = s:sub(1, n) .. '..'
    local w2 = tsize(s2)
    if pushed then Fonts.pop() end
    b.t[s] = { mw = maxw, s = s2, w = w2 }
    return s2, w2, h
end

-- Draws text vertically centred on y. maxw trims with "..." (measured with the same font). Returns the drawn width.
local function text(dl, s, x, y, align, col, scale, maxw, fk)
    if s == nil or s == '' then return 0 end
    local s2, w, h = trimmed(s, scale, maxw, fk)
    local pushed = pushf(scale, fk)
    local e = FONT[fk or 'base']
    ST.bold = e ~= nil and e.faux == true
    Info.text_at(dl, s2, x, y, align, col, ST, w, h)
    if pushed then Fonts.pop() end
    return w
end
-- Width of s once trimmed to maxw (with "..") in the font of fk, and the trimmed text.
local function measure(s, scale, maxw, fk)
    if s == nil or s == '' then return 0, s end
    local s2, w = trimmed(s, scale, maxw, fk)
    return w, s2
end
local function text_w(s, scale, fk)
    return (sized_text(s, scale, fk))
end

---------------------------------------------------------------------------
-- Per slot animation state: smoothed bar values and the damage trail
---------------------------------------------------------------------------
local anim = {}
local last_now, last_draw, was_sample = 0, 0, false
local dt = 0.016
local function astate(slot, name)
    local a = anim[slot]
    if a == nil or a.name ~= name then
        a = { name = name, hp = nil, mp = nil, tp = nil, trail = 1, hold = 0, hover = 0, sh = {}, cm = {}, full = {} }
        anim[slot] = a
    end
    return a
end
-- How much taller the card is for its extra rows of effect icons ("Fit to the card"), easing to a new height over 0.5 s.
function M.card_grow(slot, name, now)
    local a = anim[slot]
    if a == nil or a.name ~= name then return 0 end
    local want = a.bx_want or 0
    if a.bx_to ~= want then a.bx_from, a.bx_to, a.bx_t0 = a.bx_cur or 0, want, now end
    local p = math.min(1, math.max(0, (now - (a.bx_t0 or now)) / 0.5))
    a.bx_cur = a.bx_from + (want - a.bx_from) * p * p * (3 - 2 * p)
    return a.bx_cur
end
local function ease_to(cur, target, smooth)
    if cur == nil or not smooth then return target end
    local d = target - cur
    if math.abs(d) < 0.002 then return target end
    return cur + d * math.min(1, dt * 9)
end

---------------------------------------------------------------------------
-- Bars
---------------------------------------------------------------------------
local LEFT, RIGHT = 80, 160                 -- ImDrawFlags_RoundCornersLeft / Right
local TL, TR, BL, BR = 16, 32, 64, 128
-- side: 'both' | 'left' | 'right' | 'none': which ends of the shape are rounded
local function gloss(dl, kind, x0, y0, x1, y1, r, s, mult, side)
    if x1 - x0 < 1 or kind == 'none' then return end
    side = side or 'both'
    local h = y1 - y0
    local mid = y0 + h * 0.5
    local rr = math.min(r, h / 2, (x1 - x0) / 2)
    if side == 'none' then rr = 0 end
    local tf, bf = TOP, BOTTOM
    if side == 'left' then tf, bf = TL, BL elseif side == 'right' then tf, bf = TR, BR end
    local il = (side == 'both' or side == 'left') and rr or 0         -- inset of the top line from each end
    local ir = (side == 'both' or side == 'right') and rr or 0
    if kind == 'gradient' then
        rect(dl, x0, y0, x1, mid, white(0.30 * s * mult), rr, tf)
        rect(dl, x0, mid, x1, y1, black(0.30 * s * mult), rr, bf)
    elseif kind == 'glossy' then
        rect(dl, x0 + 1, y0 + 1, x1 - 1, mid, white(0.42 * s * mult), math.max(0, rr - 1), tf)
        rect(dl, x0 + 1, mid, x1 - 1, y1 - 1, black(0.12 * s * mult), math.max(0, rr - 1), bf)
        rect(dl, x0 + il, y0 + 1, x1 - ir, y0 + 2, white(0.55 * s * mult), 0)
    elseif kind == 'shine' then
        rect(dl, x0 + il, y0 + 1, x1 - ir, y0 + 2.5, white(0.65 * s * mult), 0)
    end
end

local function bar_text(b, cur, max, pct, ko)
    local m = b.text
    if m == 'none' then return nil end
    if ko then return 'KO' end
    if m == 'percent' then return ('%d%%'):format(pct) end
    if m == 'current_max' then return ('%d / %d'):format(cur, max) end
    if m == 'both' then return ('%d  (%d%%)'):format(cur, pct) end
    return tostring(cur)
end

-- Position editing: while the Positions tab is open the first full card records where each element is, so it can be dragged.
local HIT, EREC, HITKEY, FRAMEID, HLL = {}, false, nil, 0, false
M.HIT = HIT                                  -- (read by the tests)
local function hit(key, x0, y0, x1, y1, ax, ay, side)
    if not EREC then return end
    local h = HIT[key]
    if h == nil then h = {}; HIT[key] = h end
    h.x0, h.y0, h.x1, h.y1, h.ax, h.ay, h.side, h.f = x0, y0, x1, y1, ax, ay, side, FRAMEID
    Draw.hl_rect('list', key, x0, y0, x1, y1)        -- the settings window may be pointing at this element
end

---------------------------------------------------------------------------
-- Clipping a convex polygon to a bar (a rectangle with chamfered corners that stay inside its rounded corners), so
-- effects such as the sheen and the comet can never touch anything outside the bar.
---------------------------------------------------------------------------
local PA, PB = {}, {}
local POOL, PN = {}, 0
local function pt(x, y)
    PN = PN + 1
    local o = POOL[PN]
    if o == nil then o = { 0, 0 }; POOL[PN] = o end
    o[1], o[2] = x, y
    return o
end
local function clip_plane(src, n, a, b, c, dst)       -- keeps a*x + b*y + c >= 0
    local m = 0
    for i = 1, n do
        local p = src[i]
        local q = src[i % n + 1]
        local dp, dq = a * p[1] + b * p[2] + c, a * q[1] + b * q[2] + c
        if dp >= 0 then m = m + 1; dst[m] = p end
        if (dp >= 0) ~= (dq >= 0) then
            local t = dp / (dp - dq)
            m = m + 1
            dst[m] = pt(p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t)
        end
    end
    return m
end

-- Draws the convex polygon pts[1..n] (solid color), clipped to the box x0..x1 / y0..y1 with chamfers rl (left) / rr (right).
K.T1, K.T2, K.T3 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local PL8 = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
local NPL = 0
local function addpl(a, b, c)
    NPL = NPL + 1
    local t = PL8[NPL]
    t[1], t[2], t[3] = a, b, c
end
local function clipped_poly(dl, pts, n, x0, y0, x1, y1, rl, rr, col)
    PN, NPL = 0, 0
    local src, dst = PA, PB
    for i = 1, n do src[i] = pt(pts[i][1], pts[i][2]) end
    addpl(1, 0, -x0); addpl(-1, 0, x1); addpl(0, 1, -y0); addpl(0, -1, y1)
    if rl > 1 then addpl(1, 1, -(x0 + y0 + rl)); addpl(1, -1, -(x0 - y1 + rl)) end
    if rr > 1 then addpl(-1, 1, x1 - y0 - rr); addpl(-1, -1, x1 + y1 - rr) end
    for k = 1, NPL do
        local pl = PL8[k]
        n = clip_plane(src, n, pl[1], pl[2], pl[3], dst)
        if n < 3 then return end
        src, dst = dst, src
    end
    for i = 2, n - 1 do
        K.T1[1], K.T1[2], K.T2[1], K.T2[2], K.T3[1], K.T3[2] = src[1][1], src[1][2], src[i][1], src[i][2], src[i + 1][1], src[i + 1][2]
        dl:AddTriangleFilled(K.T1, K.T2, K.T3, col)
    end
end

local QUAD = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
local function quad(ax, ay, bx, by, cx, cy, dx, dy)
    local q = QUAD
    q[1][1], q[1][2], q[2][1], q[2][2], q[3][1], q[3][2], q[4][1], q[4][2] = ax, ay, bx, by, cx, cy, dx, dy
    return q
end

-- Glass sheen: a diagonal (115 degree) band, white at most 15% and feathered to nothing at both sides, sweeping left to right
-- in about a second with a quad-out slowdown. Used when a bar reaches 100%.
K.SHEEN_TIME, K.SHEEN_MAX, K.SHEEN_SLICES = 1.0, 0.15, 22
K.SLANT = 0.4663                                 -- horizontal shift per unit of height at 115 degrees
local function sheen(dl, x0, y0, x1, y1, p, r)
    local h, w = y1 - y0, x1 - x0
    local e = 1 - (1 - p) * (1 - p)                  -- quad out
    local bw = math.max(h * 3.4, w * 0.24)
    local sl = h * K.SLANT
    local cx = (x0 - bw / 2 - sl) + ((x1 + bw / 2 + sl) - (x0 - bw / 2 - sl)) * e
    for k = 1, K.SHEEN_SLICES do
        local u0, u1 = -1 + 2 * (k - 1) / K.SHEEN_SLICES, -1 + 2 * k / K.SHEEN_SLICES
        local um = (u0 + u1) / 2
        local fall = 0.5 + 0.5 * math.cos(math.pi * um)
        local al = K.SHEEN_MAX * fall * fall
        if al > 0.002 then
            local xa, xb = cx + u0 * bw / 2, cx + u1 * bw / 2
            local q = quad(xa + sl / 2, y0, xb + sl / 2, y0, xb - sl / 2, y1, xa - sl / 2, y1)
            clipped_poly(dl, q, 4, x0, y0, x1, y1, r * 0.7, r * 0.7, white(al))
        end
    end
end

-- Comet: a bright head with a fading tail that runs once along the filled part of the bar (started by barx()).
K.COMET_TRAVEL = 1.3
local function comet(dl, x0, y0, fx, y1, now, t0, speed, col, r, rr_right)
    local w = fx - x0
    if w < 8 then return end
    local h = y1 - y0
    local t = (now - t0) * speed / K.COMET_TRAVEL
    if t < 0 or t >= 1 then return end
    local e = t * t * (3 - 2 * t)
    local amt = math.min(1, (1 - t) * 4)                                 -- fades out over the last quarter
    local tail = math.max(16, math.min(110, w * 0.34))
    local hx = (x0 - 2) + (w + tail * 0.35 + 2) * e
    local K = 16
    local iy = h * 0.16
    for k = 1, K do
        local s0, s1 = (k - 1) / K, k / K
        local al = 0.62 * (s1 ^ 2.2) * amt
        local xa, xb = hx - tail * (1 - s0), hx - tail * (1 - s1)
        local q = quad(xa, y0 + iy * (1 - s0), xb, y0 + iy * (1 - s1), xb, y1 - iy * (1 - s1), xa, y1 - iy * (1 - s0))
        clipped_poly(dl, q, 4, x0, y0, fx, y1, r * 0.7, rr_right, Draw.u32(col, al * GA))
    end
    -- head: a hot spot with a soft bloom
    for k = 1, 3 do
        local ww = 2 + (3 - k) * 4
        local q = quad(hx - ww, y0 + h * 0.08, hx + ww * 0.5, y0 + h * 0.08, hx + ww * 0.5, y1 - h * 0.08, hx - ww, y1 - h * 0.08)
        clipped_poly(dl, q, 4, x0, y0, fx, y1, r * 0.7, rr_right, Draw.u32(k == 3 and WHITEC or col, ((k == 3) and 0.85 or 0.18) * amt * GA))
    end
end

--[[ One bar. frac 0-1 is what is drawn (already smoothed), fill is a color table.
     The filled part has a flat right edge until the bar is full (only the left end follows the rounding), edges sit on whole pixels.
     opts: label text, text color, trail fraction (hp), mark thirds (tp), glow strength (tp full).
     BARCUR / SHEENT / COMETAMT are set by barx() just before the call. ]]
local BARCUR, SHEENT, COMETT0, COMETSPD = nil, nil, nil, 1
-- A part-filled bar: the left end follows the bar's rounding, the right end has a small 2 px radius.
local function flatfill(dl, x0, y0, fx, y1, col, fr)
    local wd = fx - x0
    if wd <= 8 then rect(dl, x0, y0, fx, y1, col, math.min(fr, 2)); return end
    local cut = fx - 4
    rect(dl, x0, y0, cut, y1, col, fr, LEFT)
    rect(dl, cut, y0, fx, y1, col, math.min(2, (y1 - y0) / 2), RIGHT)
end

local function bar(dl, b, x0, y0, w, h, frac, fill, label, tcol, trail, thirds, glow)
    if w < 2 or h < 1 then HITKEY = nil; return end
    x0, y0 = x0 + (tonumber(b.dx) or 0), y0 + (tonumber(b.dy) or 0)
    if b.auto_len == false then w = math.max(10, math.min(500, tonumber(b.length) or w)) end     -- fixed length in pixels
    x0 = math.floor(x0 + 0.5); y0 = math.floor(y0 + 0.5); w = math.floor(w + 0.5); h = math.floor(h + 0.5)
    local x1, y1 = x0 + w, y0 + h
    if HITKEY ~= nil then
        if EREC then hit(HITKEY, x0, y0, x1, y1, x0, (y0 + y1) / 2, 'left') end
        HITKEY = nil
    end
    local r = math.min(tonumber(b.rounding) or 0, h / 2, w / 2)
    local kind, gs = b.gloss or 'none', tonumber(b.gloss_strength) or 0.5
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local full = frac >= 1 - 0.75 / w
    if glow ~= nil and glow > 0 then                  -- soft halo in the bar's own color while TP is 1000+
        local pulse = 0.55 + 0.45 * math.sin((CURNOW or 0) * 3.2)
        local gc = (frac > 0 or b.back == nil) and fill or b.back     -- at a rollover boundary the bar shows the level behind
        for k = 1, 5 do frame(dl, x0 - k, y0 - k, x1 + k, y1 + k, u32(gc, (0.45 / k) * pulse), r + k, 1) end
    end
    rect(dl, x0, y0, x1, y1, u32(b.back), r)
    local fx = x0 + math.floor(w * frac + 0.5)
    if frac > 0 then fx = math.max(x0 + math.min(2, w), fx) end
    if full then fx = x1 end
    -- the damage trail sits under the fill: rounded at the left, flat at the right unless it reaches the end
    if trail ~= nil and b.trail and trail > frac and not full then
        local tx = x0 + math.floor(w * math.min(1, trail) + 0.5)
        if tx > fx then
            local tfull = tx >= x1
            if tfull then rect(dl, x0, y0, x1, y1, u32(b.trail_color), r)      -- 2.7.0: both ends round, like the background
            else flatfill(dl, x0, y0, tx, y1, u32(b.trail_color), math.min(r, tx - x0)) end
        end
    end
    local side = full and 'both' or 'left'
    if frac > 0 then
        local fr = math.min(r, fx - x0)
        if full then rect(dl, x0, y0, fx, y1, u32(fill), fr) else flatfill(dl, x0, y0, fx, y1, u32(fill), fr) end
        gloss(dl, kind, x0, y0, fx, y1, r, gs, 1, side)
        if glow ~= nil and glow > 0 then
            if full then rect(dl, x0, y0, fx, y1, white(0.12 * glow), fr) else flatfill(dl, x0, y0, fx, y1, white(0.12 * glow), fr) end
        end
        if fx < x1 then gloss(dl, kind, fx, y0, x1, y1, r, gs, 0.35, 'right') end
        if COMETT0 ~= nil then comet(dl, x0, y0, fx, y1, (CURNOW or 0), COMETT0, COMETSPD, b.comet_color or WHITEC, r, full and r * 0.7 or 1.5) end
        if SHEENT ~= nil then
            local p = ((CURNOW or 0) - SHEENT) / K.SHEEN_TIME
            if p >= 0 and p < 1 then sheen(dl, x0, y0, x1, y1, p, r) end
        end
    else
        gloss(dl, kind, x0, y0, x1, y1, r, gs, 0.35, 'both')
    end
    if thirds then
        local inset = math.max(1, math.floor(h * 0.2))
        for k = 1, 2 do
            local tx = x0 + math.floor(w * k / 3)
            rect(dl, tx, y0 + inset, tx + 1, y1 - inset, white(0.40), 0)
        end
    end
    -- from the inside out: bar colour, outline (0-5 px), border (1-8 px); the border sits on the bar's edge, the outline just inside it
    local bw = b.border_on and math.max(1, math.min(8, tonumber(b.border_w) or 1)) or 0
    local ow = math.max(0, math.min(5, math.floor(tonumber(b.outline_w) or 0)))
    if ow > 0 and b.outline ~= nil then
        local ins = bw / 2 + ow / 2
        frame(dl, x0 + ins, y0 + ins, x1 - ins, y1 - ins, u32(b.outline), math.max(0, r - ins), ow)
    end
    if bw > 0 then frame(dl, x0, y0, x1, y1, u32(b.border), r, bw) end
    if label ~= nil then M.bar_num(dl, b, x0, y0, x1, y1, label, tcol) end
    SHEENT, COMETT0 = nil, nil
end

-- A bar's number, in the bar's number font / size / position, inside the bar rectangle x0..x1, y0..y1.
function M.bar_num(dl, b, x0, y0, x1, y1, label, tcol)
    local sc = tonumber(b.text_scale) or 0.8
    if sc < 0.45 then return end
    local pos = b.text_pos or 'center'
    local tx, al = (x0 + x1) / 2, 'center'
    if pos == 'left' then tx, al = x0 + 4, 'left' elseif pos == 'right' then tx, al = x1 - 4, 'right' end
    text(dl, label, tx + (tonumber(b.text_dx) or 0), (y0 + y1) / 2 + (tonumber(b.text_dy) or 0), al, u32(tcol), sc, nil, BARFK[b] or 'num')
end

-- The numbers of the card's HP / MP / TP bars are layers of their own (hpnum / mpnum / tpnum), so they can sit in front
-- of or behind any other element. Placed exactly like bar() places the bar.
M.NUMKEY = { hp = 'hpnum', mp = 'mpnum', tp = 'tpnum' }
function M.num_layer(L, key, dl, b, x0, y0, w, h, label, tcol)
    if label == nil or w < 2 or h < 1 then return end
    x0, y0 = x0 + (tonumber(b.dx) or 0), y0 + (tonumber(b.dy) or 0)
    if b.auto_len == false then w = math.max(10, math.min(500, tonumber(b.length) or w)) end
    x0 = math.floor(x0 + 0.5); y0 = math.floor(y0 + 0.5); w = math.floor(w + 0.5); h = math.floor(h + 0.5)
    M.defer(L, M.NUMKEY[key], M.bar_num, dl, b, x0, y0, x0 + w, y0 + h, label, tcol)
end

-- 2.5.5: the TP number's color: text_color under 1000, num_color2 from 1000, flashing (alpha dips to num_flash_min).
-- One scratch color per card slot is not needed: the number is drawn before the next card sets it again.
K.TPC = { 1, 1, 1, 1 }
function K.tp_num_color(B, tp, now)
    if tp < 1000 then return B.text_color end
    local c2 = B.num_color2 or B.text_color
    if B.num_flash == false then return c2 end
    local lo = tonumber(B.num_flash_min) or 0.35
    local k = lo + (1 - lo) * (0.5 + 0.5 * math.cos(now * 2 * math.pi * (tonumber(B.num_flash_speed) or 1.5)))
    local o = K.TPC
    o[1], o[2], o[3], o[4] = c2[1], c2[2], c2[3], (c2[4] or 1) * k
    return o
end

-- barx: bar() with a name (for dragging), the sheen / comet state of that bar on the card being drawn.
local CURA = nil
-- TP rollover: the bar fills once per 1000 TP. From 1000 on, its background is the previous level, full, in that level's
-- color, and the new level fills over it. Level colors: fill (0-999), full (1000-1999), full3 (2000-3000).
-- The proxies (one per level and bar table) only replace the background, so nothing is allocated per frame.
local TPR = { cache = setmetatable({}, { __mode = 'k' }) }
function TPR.color(B, lv)
    if lv <= 0 then return B.fill elseif lv == 1 then return B.full end
    return B.full3 or B.full
end
-- v = TP / 3000 (0..1, eased). Returns the bar table to draw with, the fill fraction and the fill color.
function TPR.split(B, v)
    local t = v * 3
    local lv = math.floor(t)
    if lv >= 3 then lv = 2 end
    if lv <= 0 then return B, t, B.fill end
    local c = TPR.cache[B]
    if c == nil then
        c = { setmetatable({}, { __index = B }), setmetatable({}, { __index = B }) }
        TPR.cache[B] = c
    end
    local P = c[lv]
    P.back = TPR.color(B, lv - 1)
    return P, t - lv, TPR.color(B, lv)
end

local function barx(key, ready, dl, b, x0, y0, w, h, frac, fill, label, tcol, trail, thirds, glow)
    HITKEY = key
    SHEENT, COMETT0 = nil, nil
    local a = CURA
    if a ~= nil then
        local st = a.sh[key]
        if b.sheen ~= false and st ~= nil and (CURNOW - st) < K.SHEEN_TIME then SHEENT = st end
        local c0 = a.cm[key]
        local spd = tonumber(b.comet_speed) or 1
        if b.comet == 'once' and c0 ~= nil and (CURNOW - c0) * spd < K.COMET_TRAVEL then COMETT0 = c0; COMETSPD = spd end
    end
    bar(dl, b, x0, y0, w, h, frac, fill, label, tcol, trail, thirds, (b.glow ~= false) and glow or nil)
end

-- The same bar for other modules (the enemy info): st = { sh = sheen start, cm = comet start } or nil, alpha = opacity.
local EXT = {}
local EXTB = setmetatable({ dx = 0, dy = 0, auto_len = true }, EXT)
function M.bar_ext(dl, b, x0, y0, w, h, frac, fill, trail, alpha, now, st)
    local ga, cn = GA, CURNOW
    GA, CURNOW = alpha, now
    HITKEY, SHEENT, COMETT0 = nil, nil, nil
    if st ~= nil then
        local sh = st.sh
        if b.sheen ~= false and sh ~= nil and now - sh < K.SHEEN_TIME then SHEENT = sh end
        local c0, spd = st.cm, tonumber(b.comet_speed) or 1
        if b.comet == 'once' and c0 ~= nil and (now - c0) * spd < K.COMET_TRAVEL then COMETT0 = c0; COMETSPD = spd end
    end
    EXT.__index = b       -- 2.9.1: the bar's own place and length (not the party list's HP offsets / fixed length)
    bar(dl, EXTB, x0, y0, w, h, frac, fill, nil, nil, trail, false, nil)
    GA, CURNOW = ga, cn
end

---------------------------------------------------------------------------
-- Job icon: a PNG from icons\jobs\<JOB>.png, else a role colored tile with the abbreviation
---------------------------------------------------------------------------
local function job_icon(dl, L, r, x, y, size)
    local ab = r.main_abbr or '???'
    local png = M.png_job
    if png ~= nil then
        local f = ab .. '.png'
        if png:has(f) then
            local t = png:get(f)
            if t.id ~= nil then image(dl, t.id, x, y, x + size, y + size, 0, 0, 1, 1, white(1)); return end
        end
    end
    local role = Data.ROLE_OF[ab] or 'support'
    local c = Data.ROLE_COLOR[role]
    local rr = math.min(tonumber(L.icon.rounding) or 4, size / 2)
    COL[1], COL[2], COL[3], COL[4] = c[1] * 0.55, c[2] * 0.55, c[3] * 0.55, 1
    rect(dl, x, y, x + size, y + size, u32(COL), rr)
    COL[1], COL[2], COL[3], COL[4] = c[1], c[2], c[3], 1
    rect(dl, x, y, x + size, y + size * 0.55, u32(COL), rr, TOP)
    rect(dl, x + rr * 0.6, y + 1, x + size - rr * 0.6, y + 2, white(0.45), 0)
    frame(dl, x, y, x + size, y + size, black(0.85), rr, 1)
    text(dl, ab, x + size / 2, y + size / 2, 'center', white(1), math.max(0.4, size * 0.40 / BASE))
end

---------------------------------------------------------------------------
-- Status effect icons
---------------------------------------------------------------------------
-- Effect order: pinned ones first (in the order of the pin list), then the rest by the chosen sort. 2.10.1: pins set
-- to Hide are never shown; Hide on party only = not on the other members' cards (still on yours).
local BORD = {}
local BF = { isp = {}, key = {}, sub = {}, red = { 1, 0.35, 0.30, 1 }, amb = { 1, 0.80, 0.30, 1 },
    dim = { 0.72, 0.74, 0.80, 1 }, white = { 1, 1, 1, 1 }, ph = { 0.4, 0.4, 0.5, 1 }, fl = {}, flp = {} }
local function by_key(p, q) local K = BF.key; local kp, kq = K[p], K[q]; if kp ~= kq then return kp < kq end return p < q end
local function buff_order(B, r, now)
    local n = 0
    local pins = type(B.pins) == 'table' and B.pins or nil
    local isp = BF.isp
    for k in pairs(isp) do isp[k] = nil end
    if pins ~= nil then
        for _, pid in ipairs(pins) do
            local pm = Buffs.pin_mode(B, pid)
            if pm == 'hide' or (pm == 'party' and r.slot ~= 0) then isp[pid] = true
            else
                for i = 1, r.nbuffs do
                    if r.buffs[i] == pid and not isp[pid] then n = n + 1; BORD[n] = pid; isp[pid] = true end
                end
            end
        end
    end
    local first = n
    -- 2.10.2: sorted By type, a type can be hidden whole (pinned effects set to Show still show)
    local th = B.sort == 'type' and type(B.type_hide) == 'table' and next(B.type_hide) ~= nil and B.type_hide or nil
    for i = 1, r.nbuffs do
        local id = r.buffs[i]
        if not isp[id] and not (th and th[Buffs.group_of(r, id)]) then n = n + 1; BORD[n] = id end
    end
    for i = n + 1, #BORD do BORD[i] = nil end
    local mode = B.sort or 'game'
    if mode ~= 'game' and n - first > 1 then
        local key, sub = BF.key, BF.sub
        local m = 0
        for i = first + 1, n do
            local id = BORD[i]
            if mode == 'soonest' or mode == 'longest' then
                local ex = Buffs.exp(r, id)
                if mode == 'soonest' then key[id] = ex and (ex - now) or 1e9 else key[id] = -(ex and (ex - now) or -1e9) end
            elseif mode == 'recent' then key[id] = -Buffs.t0(r, id, now)
            else key[id] = Buffs.skill_rank(r, id, B.type_order) end
            m = m + 1; sub[m] = id
        end
        for i = m + 1, #sub do sub[i] = nil end
        table.sort(sub, by_key)
        for i = 1, m do BORD[first + i] = sub[i] end
    end
    return n
end

local function fmt_left(t, plus)
    local c = plus and BF.flp or BF.fl
    local key, n, unit
    -- hours and minutes round down (4 h 55 m -> 4h, 15 m 42 s -> 15m); plain seconds count as before
    if t >= 3600 then n, unit = math.floor(t / 3600), 'h'; key = -100000 - n
    elseif t >= 60 then n, unit = math.floor(t / 60), 'm'; key = -n
    else n, unit = math.max(0, math.ceil(t)), ''; key = n end
    local s = c[key]
    if s == nil then s = (plus and '+' or '') .. ('%d%s'):format(n, unit); c[key] = s end
    return s
end

local function buff_extra(B)
    if B.timers and B.timer_pos == 'below' then return math.floor(BASE * (tonumber(B.timer_scale) or 0.6) + 0.5) end
    return 0
end
-- Room around each icon for the countdown graphic: m = ring margin on every side, bh = the bar under the icon (+1 gap).
-- Pitch (icon to icon): across = size + 2m + gap, down = size + 2m + bar + number + gap.
local function buff_geom(B)
    local size, gap = tonumber(B.size) or 16, tonumber(B.gap) or 1
    local m, bh = 0, 0
    if B.timers then
        if B.ring == 'ring' then m = (tonumber(B.ring_pad) or 2) + (tonumber(B.ring_width) or 2)
        elseif B.ring == 'bar' then bh = math.max(2, math.floor(size * 0.12)) + 1 end
    end
    return size, m, bh, size + 2 * m + gap, size + 2 * m + bh + buff_extra(B) + gap
end
M.buff_geom = buff_geom

-- Each icon eases to its place (slide) and fades in (pxibuffs.lua keeps the per-icon state), so a removed, replaced or
-- re-sorted effect makes the others glide instead of jump. Beneficial effects flash now and then.
-- ar: rows end at the box's right edge (the cards are to its right); up: extra rows go upward (the cards are below it).
local function buff_icons(dl, B, r, x, y, w, ar, up)
    local size, m, bh, pxs, pys = buff_geom(B)
    local per = B.fit == true and Buffs.fit_per(B, w, pxs) or math.max(1, math.floor(tonumber(B.per_row) or 12))
    local now = CURNOW or 0
    local total = buff_order(B, r, now)
    total = Buffs.with_gone(r, BORD, total, now, B)       -- effects that just ended, fading out in their old places
    local maxn = math.min(total, math.floor(tonumber(B.max) or 24))
    local extra = buff_extra(B)
    local ring, circle = B.timers and B.ring or 'none', B.ring_shape ~= 'square'
    local rpad, rw = tonumber(B.ring_pad) or 2, tonumber(B.ring_width) or 2
    local warn_at = tonumber(B.warn_secs) or 5
    local wflash, wspeed = B.warn_flash ~= false, tonumber(B.warn_speed) or 2.5
    local wmin = math.max(0.1, math.min(1, tonumber(B.warn_min) or 0.6))
    local tsc = tonumber(B.timer_scale) or 0.6
    local th = math.floor(BASE * tsc + 0.5)
    local slide, flash = B.slide ~= false, B.flash ~= false
    local own = r.slot == 0 and not BF.sample
    local OWN, cur = Buffs.own, Buffs.cur
    if r.slot == 0 then OWN.n = 0 end            -- the sample party (Test) never offers anything to cancel
    for i = 1, maxn do
        local row, col = math.floor((i - 1) / per), (i - 1) % per
        local id = BORD[i]
        local rx = col * pxs + m
        if ar then rx = rx + w + (tonumber(B.gap) or 1) - math.min(per, maxn - row * per) * pxs end
        local st = Buffs.icon(r, id, rx, (up and -row or row) * pys + m, now, dt, slide)
        local x0, y0, ia = x + st.x, y + st.y, st.a
        local ghost = st.gone ~= nil
        if ghost then ia = ia * (st.ga or 0) else st.idx = i end
        -- time left, and the full length for the ring / bar: from the spell when known, else the time left when first
        -- seen (or when it was renewed)
        local ex = (B.timers and not ghost) and Buffs.exp(r, id) or nil
        local left = (ex and ex > now) and (ex - now) or nil
        local full = nil
        if left then
            if st.dexp == nil or ex > st.dexp + 1.5 then st.ddur = math.max(1, left) end
            st.dexp = ex
            full = Buffs.dur(r, id) or st.ddur
            if left > full then full = left; st.ddur = left end
        else st.dexp = nil end
        local warn = left ~= nil and left <= warn_at
        if not ghost then st.warn = warn end
        if warn and wflash then ia = ia * ((1 + wmin) / 2 + (1 - wmin) / 2 * math.cos(now * 6.2831853 * wspeed)) end
        local ic = Fx.find_icon and Fx.find_icon(id) or nil
        local drew = false
        if ic then
            local t = ic.png:get(ic.file)
            if t.id ~= nil then image(dl, t.id, x0, y0, x0 + size, y0 + size, 0, 0, 1, 1, white(ia)); drew = ic end
        end
        if not drew then
            local l = Fx.placeholder and Fx.placeholder(id) or nil
            local c = l and l.col or BF.ph
            rect(dl, x0, y0, x0 + size, y0 + size, u32(c, 0.95 * ia), 3)
            frame(dl, x0, y0, x0 + size, y0 + size, black(0.6 * ia), 3, 1)
            if l and size >= 12 then text(dl, l.label, x0 + size / 2, y0 + size / 2, 'center', white(ia), math.max(0.4, size * 0.34 / BASE)) end
        end
        if flash and not ghost then
            local p = Buffs.flash(st, id, now, B)
            if p then
                local fs = (tonumber(B.flash_strength) or 0.5) * ia * GA
                if drew then          -- a picture: light only its visible pixels (white copy, alpha kept); none if unavailable
                    local wt = drew.png.silhouette and drew.png:silhouette(drew.file) or nil
                    -- 2.7.1: only over the picture's own shape; without the white copy there is no flash (and one chat
                    -- line says why, so it can be fixed)
                    if wt and wt.id then Draw.sheen_image(dl, wt.id, x0, y0, size, p, fs)
                    elseif wt and wt.err and not BF.sil_said then
                        BF.sil_said = true
                        hpp.err('Effect icon flash is off: the icon\'s white copy could not be made (' .. tostring(wt.err) .. ').')
                    end
                else Draw.sheen(dl, 'square', x0 + size / 2, y0 + size, 'down', size, p, fs, now) end   -- the solid tile
            end
        end
        if not ghost then Buffs.place(r, id, x0, y0, size) end
        if own and not ghost then
            OWN.n = OWN.n + 1; OWN[OWN.n] = id
            if cur.on and cur.i == OWN.n then
                frame(dl, x0 - 2, y0 - 2, x0 + size + 2, y0 + size + 2, u32(BF.amb), 3, 2)
                OWN.x, OWN.y = x0 + size + 4, y0
            end
        end
        if left and ring ~= 'none' then
            local cc = u32(warn and (B.warn_color or BF.red) or (B.ring_color or BF.white), st.a)
            local keep = math.max(0, math.min(1, left / full))
            if ring == 'ring' then
                Fx.ring(dl, x0, y0, size, keep, circle, rpad, rw, black(0.35 * st.a), cc)
            elseif ring == 'top' then
                local tid, sid = nil, nil
                if drew then
                    tid = drew.png:get(drew.file).id
                    local s = drew.png.silhouette and drew.png:silhouette(drew.file) or nil
                    sid = s and s.id or nil
                end
                Fx.drain(dl, x0, y0, size, keep, black(0.6 * st.a), cc, tid, sid)
            else
                local by = y0 + size + 1
                rect(dl, x0, by, x0 + size, by + bh - 1, black(0.7 * st.a), 0)
                rect(dl, x0, by, x0 + size * keep, by + bh - 1, cc, 0)
            end
        end
        if B.timers and not ghost then
            local str, col
            if left then
                col = warn and (B.warn_color or BF.red) or B.timer_color or BF.white
                str = fmt_left(left)
            elseif B.timer_unknown ~= 'none' then            -- duration unknown: how long it has been on (counting up)
                str, col = fmt_left(now - Buffs.t0(r, id, now), true), BF.dim
            end
            if str ~= nil and B.timer_pos ~= 'off' then
                if B.timer_pos == 'below' then
                    text(dl, str, x0 + size / 2, y0 + size + m + bh + extra / 2 + 0.5, 'center', u32(col, st.a), tsc, nil, 'base')
                else
                    rect(dl, x0, y0 + size - th - 1, x0 + size, y0 + size, black(0.55 * st.a), 0)
                    text(dl, str, x0 + size / 2, y0 + size - th / 2 - 0.5, 'center', u32(col, st.a), tsc, nil, 'base')
                end
            end
        end
    end
    return maxn, per, pxs, pys
end

-- 1.0.0: the party list's status icons for another module (the docked target card): the effects on server id sid,
-- drawn with the party list's icon settings (B = list.buffs: size, countdown, sort, pins, flash...), left-aligned
-- at x, y in a box w px wide. Returns the width and height used (0, 0 = nothing on it).
local XR = { sid = 0, slot = -1, buffs = {}, nbuffs = 0 }
local XL = {}
function M.buffs_ext(dl, B, sid, x, y, w, alpha, now)
    if type(B) ~= 'table' or sid == nil or sid == 0 then return 0, 0 end
    local n = Fx.active and Fx.active(sid, now, { show_unknown = true }, XL) or 0
    XR.sid, XR.nbuffs = sid, 0
    for i = 1, n do
        local e = XL[i]
        local id = e and (e.id or e.status)
        if id ~= nil then XR.nbuffs = XR.nbuffs + 1; XR.buffs[XR.nbuffs] = id end
    end
    for i = XR.nbuffs + 1, #XR.buffs do XR.buffs[i] = nil end
    local ga, cn = GA, CURNOW
    GA, CURNOW = alpha or 1, now
    local ok, cnt, per, pxs, pys = pcall(buff_icons, dl, B, XR, x, y, w, false, false)
    GA, CURNOW = ga, cn
    if not ok then error(cnt, 0) end
    if (cnt or 0) == 0 then return 0, 0 end
    local rows = math.ceil(cnt / per)
    return math.min(cnt, per) * pxs, rows * pys
end

---------------------------------------------------------------------------
-- Layout: heights of the pieces (all in pixels, from settings and the base font size)
---------------------------------------------------------------------------
local function px(scale) return math.floor(BASE * scale + 0.5) end

-- Cards have fixed sizes (settings: party / alliance / pet / selected). Inside a card every element sits at a home
-- position and is moved with its offsets; nothing is padded, trimmed or clipped.
local LY = { cp = 5, vg = 3, hg = 4, bleed = 6 }      -- home positions only (not settings); bleed: how far the window background reaches past the cards
local function card_wh(L, kind, selected)
    local C = L.cards
    local c = C[kind] or C.party
    local w, h = tonumber(c.w) or 248, tonumber(c.h) or 90
    if selected and kind ~= 'pet' then
        w, h = w + (tonumber(C.sel.dw) or 0), h + (tonumber(C.sel.dh) or 0)
    end
    return math.max(20, w), math.max(8, h)
end


---------------------------------------------------------------------------
-- One card
---------------------------------------------------------------------------
local function action_color(L, kind)
    local A = L.action
    if kind == 'fail' then return A.fail_color end
    if kind == 'done' then return A.done_color end
    return A.color
end

local function job_text(L, r)
    local f = L.job.format
    local mj, sj = r.main_abbr or '???', r.sub_abbr
    if f == 'both' then
        if sj then return ('%s %d / %s %d'):format(mj, r.lv, sj, r.sublv) end
        return ('%s %d'):format(mj, r.lv)
    elseif f == 'jobs' then
        if sj then return mj .. '/' .. sj end
        return mj
    elseif f == 'main' then return ('%s %d'):format(mj, r.lv)
    elseif f == 'lv' then return ('Lv%d'):format(r.lv) end
    return ''
end

---------------------------------------------------------------------------
-- Role marks (leader, alliance leader, quartermaster): drawn with primitives, no images needed
---------------------------------------------------------------------------
local function tri(dl, ax, ay, bx, by, cx, cy, col)
    P1[1], P1[2], P2[1], P2[2], P3[1], P3[2] = ax, ay, bx, by, cx, cy
    dl:AddTriangleFilled(P1, P2, P3, col)
end
local function crown(dl, cx, cy, h, col, ox, oy)
    cx, cy = cx + ox, cy + oy
    tri(dl, cx - h, cy + h * 0.1, cx - h * 0.7, cy - h * 0.8, cx - h * 0.25, cy + h * 0.1, col)
    tri(dl, cx - h * 0.45, cy + h * 0.1, cx, cy - h, cx + h * 0.45, cy + h * 0.1, col)
    tri(dl, cx + h * 0.25, cy + h * 0.1, cx + h * 0.7, cy - h * 0.8, cx + h, cy + h * 0.1, col)
    rect(dl, cx - h, cy + h * 0.1, cx + h, cy + h * 0.7, col, 0)
end
local function star(dl, cx, cy, R, col, ox, oy)
    cx, cy = cx + ox, cy + oy
    local r = R * 0.45
    local px0, py0 = cx, cy - R
    for i = 1, 10 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rad = (i % 2 == 0) and R or r
        local px1, py1 = cx + math.cos(ang) * rad, cy + math.sin(ang) * rad
        tri(dl, cx, cy, px0, py0, px1, py1, col)
        px0, py0 = px1, py1
    end
end

local function role_glyph(dl, cfg, letter, cx, cy, now)
    local s = tonumber(cfg.size) or 12
    local st = cfg.style
    local col, dark = u32(cfg.color), black(0.9)
    if st == 'crown' then
        local h = s / 2
        crown(dl, cx, cy, h, dark, 1, 0); crown(dl, cx, cy, h, dark, -1, 0); crown(dl, cx, cy, h, dark, 0, 1); crown(dl, cx, cy, h, dark, 0, -1)
        crown(dl, cx, cy, h, col, 0, 0)
        rect(dl, cx - h * 0.9, cy + h * 0.25, cx + h * 0.9, cy + h * 0.3 + 1, white(0.35), 0)
    elseif st == 'star' then
        local R = s / 2 + 1
        star(dl, cx, cy, R, dark, 1, 0); star(dl, cx, cy, R, dark, -1, 0); star(dl, cx, cy, R, dark, 0, 1); star(dl, cx, cy, R, dark, 0, -1)
        star(dl, cx, cy, R, col, 0, 0)
    elseif st == 'coin' or st == 'dot' then
        P1[1], P1[2] = cx, cy
        dl:AddCircleFilled(P1, s / 2 + 1, dark, 20)
        dl:AddCircleFilled(P1, s / 2, col, 20)
        P1[1], P1[2] = cx - s * 0.12, cy - s * 0.14
        dl:AddCircleFilled(P1, s * 0.22, white(0.28), 12)
        if st == 'coin' and s >= 9 then text(dl, letter, cx, cy + 0.5, 'center', black(0.85), math.max(0.4, s * 0.62 / BASE), nil, 'num') end
    elseif st == 'badge' then
        local h = s / 2
        rect(dl, cx - h - 1, cy - h - 1, cx + h + 1, cy + h + 1, dark, 3)
        rect(dl, cx - h, cy - h, cx + h, cy + h, col, 2)
        rect(dl, cx - h + 1, cy - h + 1, cx + h - 1, cy - h * 0.1, white(0.25), 2, TOP)
        if s >= 9 then text(dl, letter, cx, cy + 0.5, 'center', black(0.85), math.max(0.4, s * 0.62 / BASE), nil, 'num') end
    end
end

local GEO = { icx = 0, icy = 0, icsz = 0, namex = 0, liney = 0, x1 = 0, y0 = 0, nrole = 0, rc = 0 }
-- Draws one role mark where its place says; returns nothing, advances GEO.rc / GEO.nrole.
local function role_mark(dl, cfg, letter, now)
    local st = cfg.style
    if st == 'none' or st == 'name' or st == 'strip' then return end
    local s = tonumber(cfg.size) or 12
    local place = cfg.place
    if place == 'icon' and GEO.icsz <= 0 then place = 'name' end
    local cx, cy
    if place == 'icon' then
        cx = GEO.icx + GEO.icsz - s * 0.15
        cy = (GEO.rc == 0) and (GEO.icy + s * 0.15) or (GEO.icy + GEO.icsz - s * 0.15)
    elseif place == 'card' then
        cx, cy = GEO.x1 - 3 - s * 0.5 - GEO.rc * (s + 2), GEO.y0 + 2 + s * 0.35
    else
        cx, cy = GEO.namex + 5 + s * 0.5 + GEO.nrole, GEO.liney
        GEO.nrole = GEO.nrole + s + 3
    end
    role_glyph(dl, cfg, letter, cx + (tonumber(cfg.dx) or 0), cy + (tonumber(cfg.dy) or 0), now)
    GEO.rc = GEO.rc + 1
end

---------------------------------------------------------------------------
-- Draw order: every element of a card queues its drawing with its layer (z); the queue is run lowest layer first.
---------------------------------------------------------------------------
local ZDEF = { icon = 1, name = 2, job = 3, ptext = 4, hp = 5, mp = 6, tp = 7, action = 8, buffs = 9, hpnum = 10, mpnum = 11, tpnum = 12, roles = 50 }
M.ZDEF = ZDEF
local QN, Q = 0, {}
-- 2.9.1: the drawing function and its arguments are kept in a reused record (no closure per element, card and frame)
local function defer(L, key, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12)
    QN = QN + 1
    local q = Q[QN]
    if q == nil then q = {}; Q[QN] = q end
    local t = L[key]
    q.z, q.fn, q.i = (type(t) == 'table' and tonumber(t.z)) or ZDEF[key] or 0, fn, QN
    q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8], q[9], q[10], q[11], q[12] = a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12
end
M.defer = defer
local function run_queue()
    for i = 2, QN do
        local q = Q[i]
        local j = i - 1
        while j >= 1 and (Q[j].z > q.z or (Q[j].z == q.z and Q[j].i > q.i)) do Q[j + 1] = Q[j]; j = j - 1 end
        Q[j + 1] = q
    end
    for i = 1, QN do
        local q = Q[i]
        q.fn(q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8], q[9], q[10], q[11], q[12])
    end
    QN = 0
end

-- Health bar color: full color above warn_at, the warning color between warn_at and low_at, the low color below (each change
-- blends over a few percent unless "Blend" is off).
local function hp_tint(HP, p)
    if not HP.by_hp then return HP.fill end
    local A = tonumber(HP.warn_at) or 0.5
    local B = math.min(tonumber(HP.low_at) or 0.25, A - 0.01)
    local sw = (HP.blend == false) and 0 or math.min(0.05, (A - B) / 2)
    if sw > 0 then
        if p >= A + sw then return HP.fill end
        if p >= A - sw then return mix(HP.warn, HP.fill, (p - (A - sw)) / (2 * sw)) end
        if p >= B + sw then return HP.warn end
        if p >= B - sw then return mix(HP.low, HP.warn, (p - (B - sw)) / (2 * sw)) end
        return HP.low
    end
    if p >= A then return HP.fill elseif p >= B then return HP.warn end
    return HP.low
end

local function ease_dir(cur, target, smooth, up, down)
    if cur == nil or not smooth then return target end
    local d = target - cur
    if math.abs(d) < 0.002 then return target end
    return cur + d * math.min(1, dt * (d > 0 and up or down))
end

local CD = {}         -- 2.9.1: per-card helpers that used to be closures made for every card, every frame
-- a bar that has just reached 100% gets one sheen sweep; the comet plays once when HP / MP reach 100% and TP 1000
function CD.full(a, key, v, now)
    local isfull = v >= 0.995
    if a.full[key] == false and isfull then a.sh[key] = now end
    a.full[key] = isfull
end
function CD.comet(a, key, isready, now)
    if a.rdy[key] == false and isready then a.cm[key] = now end
    a.rdy[key] = isready
end
-- 2.9.1: the card's deferred drawing, as plain functions taking their values (see defer)
function CD.text(dl, s, x, y, align, col, al, scale, fk) text(dl, s, x, y, align, u32(col, al), scale, nil, fk) end
function CD.roles(dl, r, RL, now)
    for _, rk in ipairs(K.ROLEKEYS) do
        if r[K.ROLEFLAG[rk]] then role_mark(dl, RL[rk], K.ROLELETTER[rk], now) end
    end
end
function CD.hp(dl, HP, bx, by, bw, bh, a, ready) barx('hp', ready, dl, HP, bx, by, bw, bh, a.hp, hp_tint(HP, a.hp), nil, nil, a.trail, false, nil) end
function CD.mp(dl, MP, bx, by, bw, bh, a, ready) barx('mp', ready, dl, MP, bx, by, bw, bh, a.mp, MP.fill, nil, nil, nil, false, nil) end
function CD.tp(dl, TP, bx, by, bw, bh, a, ready, glow, tp, now)
    if TP.rollover ~= false then
        local B, f, c = TPR.split(TP, a.tp)
        barx('tp', ready, dl, B, bx, by, bw, bh, f, c, nil, nil, nil, false, glow)
    else
        local c = TP.fill
        if tp >= 1000 then c = TP.pulse and mix(TP.fill, TP.full, 0.7 + 0.3 * math.sin(now * 5)) or TP.full end
        barx('tp', ready, dl, TP, bx, by, bw, bh, a.tp, c, nil, nil, nil, TP.ticks, glow)
    end
end
function CD.action(dl, A, r, ax, ay, iw, ah, label, col)
    if A.bar and r.act_frac ~= nil then
        local tr = tonumber(A.bar_h) or 3
        rect(dl, ax, ay + ah - tr, ax + iw, ay + ah, black(0.45), 1)
        rect(dl, ax, ay + ah - tr, ax + iw * r.act_frac, ay + ah, u32(A.bar_color), 1)
    end
    text(dl, label, ax, ay + (ah - 2) / 2, 'left', u32(col), A.scale, nil, 'action')
end
-- the bars and their numbers (each a layer of its own; the number: M.num_layer)
function CD.hpbar(L, dl, HP, bx, by, bw, bh, a, r, ko, ready)
    GEO.low = math.max(GEO.low, by + (tonumber(HP.dy) or 0) + bh)
    defer(L, 'hp', CD.hp, dl, HP, bx, by, bw, bh, a, ready)
    local lab = nil
    if HP.show and HP.text ~= 'none' then lab = bar_text(HP, r.hp, r.mhp, r.hpp, ko) end
    M.num_layer(L, 'hp', dl, HP, bx, by, bw, bh, lab, HP.text_color)
end
function CD.mpbar(L, dl, MP, bx, by, bw, bh, a, r, ready)
    GEO.low = math.max(GEO.low, by + (tonumber(MP.dy) or 0) + bh)
    defer(L, 'mp', CD.mp, dl, MP, bx, by, bw, bh, a, ready)
    local lab = nil
    if MP.show and MP.text ~= 'none' then lab = bar_text(MP, r.mp, r.mmp, r.mpp, false) end
    M.num_layer(L, 'mp', dl, MP, bx, by, bw, bh, lab, MP.text_color)
end
function CD.tpbar(L, dl, TP, bx, by, bw, bh, a, r, ready, glow, now)
    GEO.low = math.max(GEO.low, by + (tonumber(TP.dy) or 0) + bh)
    if TP.show then defer(L, 'tp', CD.tp, dl, TP, bx, by, bw, bh, a, ready, glow, r.tp or 0, now) end
    local lab = nil
    if TP.text ~= 'none' then lab = bar_text(TP, r.tp, 3000, math.floor((r.tp or 0) / 30 + 0.5), false) end
    M.num_layer(L, 'tp', dl, TP, bx, by, bw, bh, lab, K.tp_num_color(TP, r.tp or 0, now))
end

local function draw_card(dl, L, r, x0, y0, w, h, compact, state, hovered, now)
    local a = astate(r.slot, r.name)
    CURA, CURNOW = a, now
    QN = 0
    EREC = (M.edit_slot == r.slot) and not compact
    HITKEY = nil
    local rr = tonumber(L.card.rounding) or 4
    local sr = tonumber(L.sel.rounding) or rr          -- the selector (highlight, outline, flash) has its own rounding
    GA = (r.here and 1 or (tonumber(L.out_alpha) or 0.45)) * EA
    Info.set_alpha(GA)
    -- the selected (or targeted) member's card moves a few pixels off its place, easing there and back in 0.15 s
    local S = L.sel
    local lw = ((state.select or state.target) and S.lift ~= false) and 1 or 0
    local lv = a.lift or 0
    if lv ~= lw then lv = (lw > lv) and math.min(lw, lv + dt / 0.15) or math.max(lw, lv - dt / 0.15); a.lift = lv end
    if lv > 0 then
        local e = lv * lv * (3 - 2 * lv)
        x0, y0 = x0 + (tonumber(S.move_dx) or 6) * e, y0 + (tonumber(S.move_dy) or 0) * e
    end
    local x1, y1 = x0 + w, y0 + h
    if EREC then Draw.hl_rect('list', 'card', x0, y0, x1, y1) end

    -- background
    local BG = L.bg
    local png = nil
    if BG.mode == 'png' and BG.scope == 'row' and M.png_bg ~= nil and BG.file ~= '' then
        local t = M.png_bg:get(BG.file)
        if t.id ~= nil then png = t end
    end
    if png then panel_image(dl, png, x0, y0, x1, y1, BG.slice, u32(BG.tint))
    elseif L.card.show then
        rect(dl, x0, y0, x1, y1, u32(L.card.bg), rr)
        if (tonumber(L.card.border_w) or 0) > 0 then frame(dl, x0, y0, x1, y1, u32(L.card.border), rr, L.card.border_w) end
    end
    if hovered and L.card.hover then rect(dl, x0, y0, x1, y1, white(0.07), rr) end

    -- selection / target marks
    local mark, mcol = nil, nil
    if state.cursor then mark, mcol = 'cursor', S.cursor
    elseif state.select then mark, mcol = 'select', S.select
    elseif state.target then mark, mcol = 'target', S.target end
    -- a card that just became targeted / selected gets a flash and one sheen sweep (drawn over the card after its content)
    local sel_t, sel_col = nil, mcol
    if mark ~= nil then
        if a.mk ~= mark and a.mk_seen then a.mk_t = now end
        sel_t = a.mk_t
    end
    if a.mk ~= mark then a.mk_r = now end
    a.mk, a.mk_seen = mark, true
    -- 2.6.1: the highlight has its own height (centred on the card) and the selected box its own fill color
    local hd = (tonumber(S.height) or 0) / 2
    local hy0, hy1 = y0 - hd, y1 + hd
    if hy1 - hy0 < 2 then hy0, hy1 = (y0 + y1) / 2 - 1, (y0 + y1) / 2 + 1 end
    if mark then
        local pulse = (mark == 'cursor') and (0.75 + 0.25 * math.sin(now * 6)) or 1
        if state.select then rect(dl, x0, hy0, x1, hy1, u32(S.fill or S.select, S.fill == nil and (tonumber(S.tint) or 0.12) or nil), sr) end
        frame(dl, x0, hy0, x1, hy1, u32(mcol, pulse), sr, tonumber(S.border_w) or 2)
        -- the sheen sweeps again every 2-3 s (at random) while the card stays highlighted
        if S.sheen ~= false then
            if a.sh_next == nil or a.mk_r == now then a.sh_next = now + 2 + math.random() end
            if now >= a.sh_next then a.sh_t, a.sh_next = now, now + 2 + math.random() end
        end
    else
        a.sh_next, a.sh_t = nil, nil
    end
    a.hy0, a.hy1 = hy0, hy1

    local cp = LY.cp
    local ix = x0 + cp
    local iw = w - cp * 2
    local ytop = y0 + cp
    local ko = r.here and r.hpp == 0 and r.hp == 0

    -- line 1: icon, name, job text. The icon's room is always kept, so hiding it does not move anything else.
    local nameh = L.name.show and px(L.name.scale) or 0
    local jobh = (L.job.show and L.job.format ~= 'none' and not compact) and px(L.job.scale) or 0
    local iconres = tonumber(L.icon.size) or 18
    if compact then iconres = math.min(iconres, nameh + 4) end
    local iconsz = L.icon.show and iconres or 0
    local line1 = compact and (h - cp * 2) or math.max(nameh, jobh, iconres, 8)
    local cx = ix
    local RL = L.roles
    GEO.icsz, GEO.nrole, GEO.rc, GEO.x1, GEO.y0 = 0, 0, 0, x1, y0
    GEO.low = ytop                 -- bottom of the lowest element drawn so far (where fitted effect icons start)
    if iconsz > 0 then
        local icx, icy = cx + (tonumber(L.icon.dx) or 0), ytop + (line1 - iconsz) / 2 + (tonumber(L.icon.dy) or 0)
        GEO.icx, GEO.icy, GEO.icsz = icx, icy, iconsz
        GEO.low = math.max(GEO.low, icy + iconsz)
        hit('icon', icx, icy, icx + iconsz, icy + iconsz, icx, icy + iconsz / 2, 'left')
        defer(L, 'icon', job_icon, dl, L, r, icx, icy, iconsz)
    end
    cx = cx + iconres + 5
    -- strips along the card's left edge, and a role colored name
    local ncol = ko and { 0.62, 0.62, 0.66, 1 } or L.name.color
    local sx = x0 + 1
    for _, rk in ipairs(K.ROLEKEYS) do
        local cfg = RL[rk]
        if r[K.ROLEFLAG[rk]] then
            if cfg.style == 'strip' then rect(dl, sx, y0 + 3, sx + 3, y1 - 3, u32(cfg.color), 1); sx = sx + 4
            elseif cfg.style == 'name' then ncol = cfg.color end
        end
    end
    local jt = (jobh > 0) and job_text(L, r) or ''
    local jw = (jt ~= '') and text_w(jt, L.job.scale, 'job') or 0
    local ndx, ndy = tonumber(L.name.dx) or 0, tonumber(L.name.dy) or 0
    local line_y = ytop + line1 / 2
    local nw = 0
    if L.name.show then
        local avail = (compact and (iw * 0.42) or (iw - (cx - ix) - jw - 8))
        local nm = L.name.caps and r.name:upper() or r.name
        local ns
        nw, ns = measure(nm, L.name.scale, nil, 'name')
        defer(L, 'name', CD.text, dl, ns, cx + ndx, line_y + ndy, 'left', ncol, 1, L.name.scale, 'name')
    end
    NPX[r.slot + 1], NPY[r.slot + 1] = math.min(x0, cx + ndx, (GEO.icsz > 0) and GEO.icx or x0), line_y + ndy
    if L.name.show then GEO.low = math.max(GEO.low, line_y + ndy + nameh / 2) end
    if L.name.show then hit('name', cx + ndx, line_y + ndy - nameh / 2, cx + ndx + math.max(nw, 30), line_y + ndy + nameh / 2, cx + ndx, line_y + ndy, 'left') end
    GEO.namex, GEO.liney = cx + ndx + nw, line_y
    defer(L, 'roles', CD.roles, dl, r, RL, now)
    if jt ~= '' then
        local jx, jy = ix + iw + (tonumber(L.job.dx) or 0), line_y + (tonumber(L.job.dy) or 0)
        hit('job', jx - jw, jy - jobh / 2, jx, jy + jobh / 2, jx, jy, 'right')
        GEO.low = math.max(GEO.low, jy + jobh / 2)
        defer(L, 'job', CD.text, dl, jt, jx, jy, 'right', L.job.color, 1, L.job.scale, 'job')
    end

    -- 2.10.0: out of zone and the action line (which says where they are) is off: the zone's name after the name
    if not r.here and not L.action.show then
        if r.zonetxt == '' or r.zone_for ~= r.zone then r.zonetxt, r.zone_for = Data.zone_name(r.zone), r.zone end
        local zx = cx + ndx + nw + 6 + GEO.nrole
        local avail = ix + iw - jw - 8 - zx
        if avail >= 16 then
            local zs = select(2, measure(r.zonetxt, L.job.scale, avail, 'job'))
            defer(L, 'job', CD.text, dl, zs, zx, line_y + ndy, 'left', L.job.color, 1, L.job.scale, 'job')
        end
    end
    -- text next to the name: your note for this member, or what they just said (fades out)
    local P = L.ptext
    if not compact and P.mode ~= 'off' then
        GEO.low = math.max(GEO.low, line_y + (tonumber(P.dy) or 0) + px(P.scale) / 2)    -- its place, even while empty
        local ptxt, pcol, pal = nil, nil, 1
        local age = r.chat_t and (now - r.chat_t) or nil
        if (P.mode == 'both' or P.mode == 'chat') and r.chat_text and age and age < P.hold then
            ptxt, pcol = '"' .. r.chat_text .. '"', P.chat_color
            pal = math.max(0, math.min(1, (P.hold - age) / math.max(0.05, P.fade)))
        elseif P.mode == 'both' or P.mode == 'note' then
            local n = L.notes[r.lname or ''] or r.demo_note
            if n ~= nil and n ~= '' then ptxt, pcol = P.brackets and ('[' .. n .. ']') or n, P.note_color end
        end
        if ptxt ~= nil then
            local px0 = cx + ndx + nw + 6 + GEO.nrole
            local avail = ix + iw - jw - 8 - (px0 - 0)
            if avail >= 16 then
                local tx0, ty0 = px0 + (tonumber(P.dx) or 0), line_y + (tonumber(P.dy) or 0)
                local pw, ps = measure(ptxt, P.scale, nil, 'ptext')
                local ph = px(P.scale)
                hit('ptext', tx0, ty0 - ph / 2, tx0 + math.max(pw, 20), ty0 + ph / 2, tx0, ty0, 'left')
                defer(L, 'ptext', CD.text, dl, ps, tx0, ty0, 'left', pcol, pal, P.scale, 'ptext')
            end
        end
    end

    -- bars. Health falls quickly (the trail shows what was lost) and rises smoothly; the trail never sits below the fill,
    -- so a heal can not make the two fight.
    local HP, MP, TP = L.hp, L.mp, L.tp
    local TPON = TP.show or TP.text ~= 'none'     -- 2.7.6: the TP bar and its number turn off separately; either keeps the row
    local smooth = L.smooth
    local hpf = (r.hpp or 0) / 100
    local mpf = (r.mpp or 0) / 100
    local tpf = math.min(1, (r.tp or 0) / 3000)
    a.hp, a.mp, a.tp = ease_dir(a.hp, hpf, smooth, 7, 22), ease_dir(a.mp, mpf, smooth, 8, 14), ease_dir(a.tp, tpf, smooth, 10, 18)
    if a.last_hp == nil then a.trail = a.hp end
    if hpf < (a.last_hp or hpf) - 0.0005 then a.hold = now + 0.30 end
    a.last_hp = hpf
    if a.trail < a.hp then a.trail = a.hp end
    if a.trail > a.hp and now >= a.hold then a.trail = math.max(a.hp, a.trail - math.max(0.30, (a.trail - a.hp) * 1.3) * dt) end
    -- a bar that has just reached 100% gets one sheen sweep
    CD.full(a, 'hp', a.hp, now); CD.full(a, 'mp', a.mp, now); CD.full(a, 'tp', a.tp, now)
    -- the comet plays once, when HP / MP reach 100% and when TP reaches 1000
    a.rdy = a.rdy or {}
    CD.comet(a, 'hp', a.hp >= 0.995, now); CD.comet(a, 'mp', a.mp >= 0.995, now); CD.comet(a, 'tp', (r.tp or 0) >= 1000, now)
    local hp_ready, mp_ready, tp_ready = a.hp >= 0.995, a.mp >= 0.995, (r.tp or 0) >= 1000

    local tp_glow = ((r.tp or 0) >= 1000) and 1 or 0
    if compact then
        if not r.here then
            -- 2.10.0: out of zone: the zone's name where the health bar goes (its numbers mean nothing there)
            if r.zonetxt == '' or r.zone_for ~= r.zone then r.zonetxt, r.zone_for = Data.zone_name(r.zone), r.zone end
            local bw = iw * 0.54
            local zs = select(2, measure(r.zonetxt, L.job.scale, bw, 'job'))
            defer(L, 'job', CD.text, dl, zs, ix + iw - bw, y0 + h / 2, 'left', L.job.color, 1, L.job.scale, 'job')
        elseif HP.show then
            local bw = iw * 0.54
            local bh = math.min(HP.height, h - cp * 2)
            CD.hpbar(L, dl, HP, ix + iw - bw, y0 + (h - bh) / 2, bw, bh, a, r, ko, hp_ready)
        end
        run_queue()
        return
    end

    local y = ytop + line1
    local vg = LY.vg
    local hg = LY.hg
    if HP.show then
        y = y + vg
        CD.hpbar(L, dl, HP, ix, y, iw, HP.height, a, r, ko, hp_ready)
        y = y + HP.height
    end
    if MP.show or TPON then
        y = y + vg
        local bh = math.max(MP.show and MP.height or 0, TPON and TP.height or 0)
        if MP.show and TPON then
            local mw = (iw - hg) * 0.5
            CD.mpbar(L, dl, MP, ix, y + (bh - MP.height) / 2, mw, MP.height, a, r, mp_ready)
            CD.tpbar(L, dl, TP, ix + mw + hg, y + (bh - TP.height) / 2, iw - mw - hg, TP.height, a, r, tp_ready, tp_glow, now)
        elseif MP.show then
            CD.mpbar(L, dl, MP, ix, y, iw, MP.height, a, r, mp_ready)
        else
            CD.tpbar(L, dl, TP, ix, y, iw, TP.height, a, r, tp_ready, tp_glow, now)
        end
        y = y + bh
    end

    -- current action (or the zone, for someone who is somewhere else)
    local A = L.action
    if A.show then
        y = y + vg
        local ah = px(A.scale) + 2
        GEO.low = math.max(GEO.low, y + (tonumber(A.dy) or 0) + ah)       -- its place, even with nothing to say
        local label, col = r.act_text, nil
        if label ~= nil then col = action_color(L, r.act_kind) end
        if label == nil and not r.here then
            if r.zonetxt == '' or r.zone_for ~= r.zone then r.zonetxt, r.zone_for = Data.zone_name(r.zone), r.zone end
            label, col = r.zonetxt, L.job.color
        end
        if label ~= nil then
            local ax, ay = ix + (tonumber(A.dx) or 0), y + (tonumber(A.dy) or 0)
            hit('action', ax, ay, ax + iw, ay + ah, ax, ay + (ah - 2) / 2, 'left')
            defer(L, 'action', CD.action, dl, A, r, ax, ay, iw, ah, label, col)
        end
        y = y + ah
    end

    -- status effects
    -- "Fit to the card": the icons sit at their home spot inside the card (not draggable), wrap at the card's width,
    -- and the card grows by the extra rows (M.card_grow animates it). Otherwise they go anywhere (offsets / dragging).
    local B = L.buffs
    local fit = B.fit == true
    a.bx_want = 0
    if B.show then
        y = y + vg
        if r.nbuffs > 0 then
            local bx0, by0 = ix, y
            local bar_, bup = false, false
            if not fit then
                -- placed anywhere: the icons keep to the side of their box that faces the cards (the right edge when the
                -- box is left of the card, the bottom row first and further rows upward when it is above the card)
                bx0, by0 = ix + (tonumber(B.dx) or 0), y + (tonumber(B.dy) or 0)
                local _, _, _, pxs, pys = buff_geom(B)
                local gap = tonumber(B.gap) or 1
                bar_ = bx0 + iw / 2 < x0 and bx0 + iw <= x0 + 1
                bup = by0 + pys - gap <= y0 + 1
                local per = math.max(1, math.floor(tonumber(B.per_row) or 12))
                local rows = math.max(1, math.ceil(math.min(r.nbuffs, math.floor(tonumber(B.max) or 24)) / per))
                local bh_ = rows * pys - gap
                local top = bup and (by0 + pys - gap - bh_) or by0
                hit('buffs', bx0 - 2, top - 2, bx0 + iw + 2, top + bh_ + 2, bx0, by0 + B.size / 2, 'left')   -- the box, 2 px around the icons
            else
                -- under the lowest element of the card (icon, name, job, note, bars, action, with their offsets) plus the
                -- padding; the card's set height (without the growth now applied) must reach the last row plus the
                -- bottom padding
                by0 = GEO.low + (tonumber(B.fit_pad) or 3)
                local _, _, _, pxs, pys = buff_geom(B)
                local rows = math.ceil(math.min(r.nbuffs, math.floor(tonumber(B.max) or 24)) / Buffs.fit_per(B, iw, pxs))
                local need = (by0 - y0) + rows * pys - (tonumber(B.gap) or 1) + cp
                local _, hb = card_wh(L, r.slot >= 6 and 'alliance' or 'party', state ~= nil and state.select == true)
                a.bx_want = math.max(0, math.floor(need - hb + 0.5))
            end
            defer(L, 'buffs', buff_icons, dl, B, r, bx0, by0, iw, bar_, bup)
        end
    end
    HITKEY = nil
    run_queue()
    -- a border flash that repeats every few seconds on the member the cursor / selection is on
    if mark ~= nil and mark ~= 'target' and S.repeat_flash ~= false then
        local every = math.max(1, tonumber(S.repeat_every) or 3)
        local ph = (now - (a.mk_r or now)) % every
        local dur = math.min(0.8, every * 0.6)
        if ph < dur then
            local k = math.sin(math.pi * ph / dur)
            local bw0 = tonumber(S.border_w) or 2
            local hy0, hy1 = a.hy0 or y0, a.hy1 or y1
            frame(dl, x0, hy0, x1, hy1, white(0.85 * k), sr, bw0 + 1)
            frame(dl, x0, hy0, x1, hy1, u32(sel_col, k), sr, bw0 + 1)
            for i = 1, 4 do
                frame(dl, x0 - i, hy0 - i, x1 + i, hy1 + i, u32(sel_col, 0.45 * k / i), sr + i, 1)
            end
        end
    end
    if sel_t ~= nil then
        local el = now - sel_t
        local hy0, hy1 = a.hy0 or y0, a.hy1 or y1
        if S.flash ~= false and el >= 0 and el < 0.45 then
            local k = 1 - el / 0.45
            rect(dl, x0, hy0, x1, hy1, u32(sel_col, 0.32 * k * k), sr)
        end
        if a.sh_t ~= nil and a.sh_t > sel_t then el = now - a.sh_t end
        if S.sheen ~= false and el >= 0 and el < K.SHEEN_TIME then sheen(dl, x0, hy0, x1, hy1, el / K.SHEEN_TIME, sr) end
    end
end


---------------------------------------------------------------------------
-- Pets and summons: a smaller card under the owner (attached) or in a "Pets" section at the end
---------------------------------------------------------------------------
local PB = { a = nil, b = nil, c = nil, hp = nil, mp = nil, tp = nil }
K.PETCOL = { 0.55, 0.82, 1, 1 }
local function pet_bars(L)
    if PB.a ~= L.hp or PB.b ~= L.mp or PB.c ~= L.tp then
        PB.a, PB.b, PB.c = L.hp, L.mp, L.tp
        PB.hp = setmetatable({ dx = 0, dy = 0, text = 'percent' }, { __index = L.hp })
        PB.mp = setmetatable({ dx = 0, dy = 0, text = 'none', height = 3, border_on = false }, { __index = L.mp })
        PB.tp = setmetatable({ dx = 0, dy = 0, text = 'none', height = 3, border_on = false }, { __index = L.tp })
    end
    return PB.hp, PB.mp, PB.tp
end

local function draw_pet(dl, L, pr, x0, y0, w, h, now, attached)
    local PC = L.pets
    local a = astate(100 + pr.slot, pr.name)
    local rr = tonumber(L.card.rounding) or 4
    local x1, y1 = x0 + w, y0 + h
    Draw.hl_rect('list', 'pet', x0, y0, x1, y1)
    GA = EA
    Info.set_alpha(GA)
    if L.card.show then
        rect(dl, x0, y0, x1, y1, u32(L.card.bg, 0.85), rr)
        if (tonumber(L.card.border_w) or 0) > 0 then frame(dl, x0, y0, x1, y1, u32(L.card.border, 0.85), rr, L.card.border_w) end
    end
    local sc = L.name.scale * PC.scale
    local nameh = px(sc)
    local ly = y0 + 3 + nameh / 2
    local tx = x0 + 6
    if PC.connector and attached then
        local cxl = x0 - math.max(4, PC.indent * 0.5)
        local col = u32(L.card.border, 0.9)
        rect(dl, cxl, y0 - 3, cxl + 1, y0 + h / 2 + 1, col, 0)
        rect(dl, cxl, y0 + h / 2, x0, y0 + h / 2 + 1, col, 0)
    end
    if PC.glyph then
        local gx, gy, g = x0 + 9, ly, 3.5
        tri(dl, gx, gy - g, gx + g, gy, gx, gy + g, u32(K.PETCOL))
        tri(dl, gx, gy - g, gx - g, gy, gx, gy + g, u32(K.PETCOL, 0.75))
        tx = x0 + 18
    end
    local own = pr.owner
    local rw = 0
    if own ~= nil and (PC.show_owner or not attached) then
        local ot = attached and ('(' .. own.name .. ')') or own.name
        rw = text(dl, ot, x1 - 6, ly, 'right', u32(L.job.color), sc * 0.9, nil, 'job') or 0
    end
    text(dl, L.name.caps and pr.name:upper() or pr.name, tx, ly, 'left', u32(L.name.color), sc, nil, 'name')

    local HB, MB, TB = pet_bars(L)
    HB.height = PC.bar_h
    local hpf = (pr.hpp or 0) / 100
    a.hp = ease_to(a.hp, hpf, L.smooth)
    local HP = L.hp
    local col = hp_tint(HP, a.hp)
    local by = y0 + 3 + nameh + 2
    bar(dl, HB, x0 + 6, by, w - 12, PC.bar_h, a.hp, col, PC.bar_h >= 8 and bar_text(HB, 0, 0, pr.hpp or 0, false) or nil, HP.text_color, nil, false, nil)
    if PC.mptp and pr.has_mptp then
        a.tp = ease_to(a.tp, math.min(1, (pr.tp or 0) / 3000), L.smooth)
        local tx0, tw = x0 + 6, w - 12
        if pr.has_mp then         -- MP only for pets with a mana pool; otherwise TP takes the whole row
            a.mp = ease_to(a.mp, (pr.mpp or 0) / 100, L.smooth)
            tw = (w - 12 - 3) / 2
            bar(dl, MB, x0 + 6, by + PC.bar_h + 2, tw, 3, a.mp, L.mp.fill, nil, nil, nil, false, nil)
            tx0 = x0 + 9 + tw
        end
        if L.tp.rollover ~= false then
            local B, f, c = TPR.split(TB, a.tp)
            bar(dl, B, tx0, by + PC.bar_h + 2, tw, 3, f, c, nil, nil, nil, false, nil)
        else
            bar(dl, TB, tx0, by + PC.bar_h + 2, tw, 3, a.tp, (pr.tp or 0) >= 1000 and L.tp.full or L.tp.fill, nil, nil, nil, false, nil)
        end
    end
end

---------------------------------------------------------------------------
-- Party invite: a banner above the list that, after a few seconds, morphs into a round "!" badge (like the game's)
---------------------------------------------------------------------------
local function sstep(t) if t < 0 then t = 0 elseif t > 1 then t = 1 end return t * t * (3 - 2 * t) end
local function lerp(a, b, t) return a + (b - a) * t end
local function ease_back(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    local c1, c3 = 1.70158, 2.70158
    t = t - 1
    return 1 + c3 * t * t * t + c1 * t * t
end
K.IBG, K.IMIX = { 0, 0, 0, 1 }, { 0, 0, 0, 1 }

local function exclaim(dl, cx, cy, d, s, col, dark)
    if s <= 0.02 then return end
    local w = math.max(2, d * 0.13) * s
    local hh = d * 0.46 * s
    for _, o in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        rect(dl, cx - w / 2 + o[1], cy - hh / 2 + o[2], cx + w / 2 + o[1], cy + hh * 0.1 + o[2], dark, w / 2)
        P1[1], P1[2] = cx + o[1], cy + hh * 0.38 + o[2]
        dl:AddCircleFilled(P1, w * 0.7, dark, 10)
    end
    rect(dl, cx - w / 2, cy - hh / 2, cx + w / 2, cy + hh * 0.1, col, w / 2)
    P1[1], P1[2] = cx, cy + hh * 0.38
    dl:AddCircleFilled(P1, w * 0.7, col, 10)
end

local function draw_invite(L, now, wx, wy, W)
    local I = Data.invite
    local C = L.invite
    if not I.active then return end
    if C.mode == 'off' then I.active = false; return end
    local banner_t = (C.mode == 'banner') and C.banner or 0
    if I.resolved == 0 then
        local limit = I.test and (banner_t + 0.9 + 6) or C.timeout
        if now - I.t0 > limit then Data.invite_resolve(now) end
    end
    local out = 0
    if I.resolved ~= 0 then
        out = (now - I.resolved) / 0.45
        if out >= 1 then I.active = false; return end
    end
    local age = now - I.t0
    local d = C.size
    local fg = imgui.GetForegroundDrawList()
    GA = 1 - sstep(out)
    Info.set_alpha(GA)
    local bh = d + 8
    local bx0, bx1 = wx, wx + W
    local by1 = wy - 4
    local by0 = by1 - bh
    local ccx, ccy = wx + W - d / 2 - 2 + C.dx, wy - d / 2 - 4 + C.dy
    local m = (C.mode == 'banner') and sstep((age - banner_t) / 0.8) or 1
    local enter = sstep(age / 0.35)
    local yoff = (1 - enter) * -14
    local bob = (m >= 1) and math.sin(now * 5) * 1.5 or 0
    local x0, x1 = lerp(bx0, ccx - d / 2, m), lerp(bx1, ccx + d / 2, m)
    local y0, y1 = lerp(by0, ccy - d / 2, m) + yoff + bob, lerp(by1, ccy + d / 2, m) + yoff + bob
    local grow = sstep(out) * d * 0.35
    x0, x1, y0, y1 = x0 - grow, x1 + grow, y0 - grow, y1 + grow
    local rr = lerp(5, (y1 - y0) / 2, m)
    local k = C.color
    K.IBG[1], K.IBG[2], K.IBG[3], K.IBG[4] = lerp(k[1] * 0.28, k[1], m), lerp(k[2] * 0.28, k[2], m), lerp(k[3] * 0.28, k[3], m), 0.96 * enter
    local cxm, cym = (x0 + x1) / 2, (y0 + y1) / 2

    -- pulse ring on the finished badge
    if m >= 1 and C.pulse and I.resolved == 0 then
        local ph = (now * 1.1) % 1
        P1[1], P1[2] = cxm, cym
        K.IMIX[1], K.IMIX[2], K.IMIX[3], K.IMIX[4] = k[1], k[2], k[3], 0.65 * (1 - ph)
        fg:AddCircle(P1, d / 2 + 1 + ph * d * 0.8, u32(K.IMIX), 32, 2)
    end
    rect(fg, x0 - 1, y0 - 1, x1 + 1, y1 + 1, black(0.8 * enter), rr + 1)
    rect(fg, x0, y0, x1, y1, u32(K.IBG), rr)
    rect(fg, x0 + 1, y0 + 1, x1 - 1, lerp(y0 + (y1 - y0) * 0.5, cym - 1, m), white(0.16 * enter), math.max(0, rr - 1), TOP)
    frame(fg, x0, y0, x1, y1, u32(k, 0.9 * enter), rr, 1.5)

    if m < 0.45 then
        local ta = 1 - sstep(m / 0.45)
        -- shimmer sweep
        local sw = ((age * 0.7) % 1.6 - 0.3) * (x1 - x0)
        rect(fg, math.max(x0 + 2, x0 + sw), y0 + 2, math.min(x1 - 2, x0 + sw + 36), y1 - 2, white(0.14 * ta), 0)
        local who = (I.from ~= '' and I.from or 'Someone')
        text(fg, who .. ' invites you to a party', (x0 + x1) / 2, cym, 'center', u32(C.text_color, ta), tonumber(C.text_scale) or 0.85, (x1 - x0) - 12, 'name')
    end
    local gs = (C.mode == 'banner') and ease_back((m - 0.5) / 0.5) or ease_back(enter)
    exclaim(fg, cxm, cym, d, gs, u32(C.text_color), black(0.9))
    GA = 1
    Info.set_alpha(1)
end

function M.test_invite(now)
    Data.invite_start('Altair', now, 0, true)
end

---------------------------------------------------------------------------
-- Selection: cycling, clicking, targeting
---------------------------------------------------------------------------
local function tag_of(slot)
    if slot == 0 then return '<me>' end
    if slot <= 5 then return ('<p%d>'):format(slot) end
    if slot <= 11 then return ('<a1%d>'):format(slot - 6) end
    return ('<a2%d>'):format(slot - 12)
end
M.tag_of = tag_of

local function dbg(text) if hpp.s.list.debug then hpp.msg('[list] ' .. text) end end

-- Which list slot holds entity index idx (matches by target index, then by server id), or -1.
local function slot_for(idx)
    if idx == nil or idx == 0 then return -1 end
    local party = hpp.targets.api.party()
    if party == nil then return -1 end
    for s = 0, 17 do
        if Data.m[s + 1].active and party:GetMemberTargetIndex(s) == idx then return s end
    end
    local ok, sid = pcall(function () return AshitaCore:GetMemoryManager():GetEntity():GetServerId(idx) end)
    if ok and type(sid) == 'number' and sid ~= 0 then
        for s = 0, 17 do
            local r = Data.m[s + 1]
            if r.active and r.sid == sid then return s end
        end
    end
    return -1
end
M.slot_for = slot_for

local function queue(cmd)
    local ok, e = pcall(function () AshitaCore:GetChatManager():QueueCommand(1, cmd) end)
    if not ok then hpp.err('Could not send ' .. cmd .. ': ' .. tostring(e)) end
    return ok
end

function M.target(slot)
    if slot == nil or slot < 0 then return end
    queue('/ta ' .. tag_of(slot))
end

-- Key presses for closing / confirming the game's own target cursor (keybd_event from user32), sent a moment later.
local KEYQ, KEYN = {}, 0
local kb_state = nil
local function keybd(vk, scan, up)
    if kb_state == nil then
        local ok, err = pcall(ffi.cdef, 'void keybd_event(uint8_t bVk, uint8_t bScan, uint32_t dwFlags, uintptr_t dwExtraInfo);')
        kb_state = ok or tostring(err):find('redefine', 1, true) ~= nil
    end
    if not kb_state then return false end
    return pcall(function () ffi.C.keybd_event(vk, scan, up and 0x0A or 0x08, 0) end)    -- 0x08 scan code, 0x02 key up
end
local function press(vk, scan, now, delay, needs_cursor)
    if vk == 0x1B then M.own_esc = now + delay + 0.5 end    -- our own Esc must not clear the selection (M.escape)
    KEYN = KEYN + 1
    KEYQ[KEYN] = { at = now + delay, vk = vk, scan = scan, up = false, needs = needs_cursor }
    KEYN = KEYN + 1
    KEYQ[KEYN] = { at = now + delay + 0.06, vk = vk, scan = scan, up = true, needs = false }
end
-- 2.6.0: Esc (or losing your target) also clears the member picked in the list, so its pointer goes away
function M.escape(now)
    if now < (M.own_esc or 0) then return end
    M.sel = -1
end
-- Called every frame (also when the list is not drawn).
function M.pump(now)
    local main = hpp.st and hpp.st.main or 0
    if main == 0 and (M.last_main or 0) ~= 0 and now >= (M.own_esc or 0) then M.sel = -1 end
    M.last_main = main
    if KEYN == 0 then return end
    local keep, n = {}, 0
    for i = 1, KEYN do
        local k = KEYQ[i]
        if now >= k.at then
            if not (k.needs and not hpp.st.sub_active) then keybd(k.vk, k.scan, k.up) end
        else n = n + 1; keep[n] = k end
    end
    KEYQ, KEYN = keep, n
end

--[[
* Selecting a member (click or cycle). With "perform" on and the game waiting for a target (a spell / ability typed
* or macroed with <st>, <stpc>, <stnpc>, <stpt> or <stal>), the selection does what the game asked for:
*   1. the command that opened the cursor (remembered by the main file) is sent again with the chosen member
*      written in place of the <st..> tag, and the game's cursor is closed (Esc);
*   2. if that command is unknown (the cursor came from a game menu): the game's party cursor is moved to the member
*      and Enter is pressed.
* Otherwise the member is just targeted (/ta).
--]]
function M.select(slot, from_click)
    M.sel = slot
    if slot < 0 or hpp.list_test then return end
    local L = hpp.s.list
    local st, now = hpp.st, hpp.clock()
    if L.select_action == 'auto' and st.sub_active then
        local pc = hpp.pending
        if pc ~= nil and now - pc.at < 60 then
            local cmd = (pc.cmd:gsub('<st%a*>', tag_of(slot)))
            hpp.pending = nil
            if queue(cmd) then
                press(0x1B, 0x01, now, 0.12, true)      -- Esc closes the cursor if it is still open
                dbg('sent ' .. cmd)
                return
            end
        elseif st.slot >= 0 then
            local ok, moved = pcall(hpp.targets.set_party_cursor, hpp.targets, slot)
            if ok and moved then
                press(0x0D, 0x1C, now, 0.10, true)     -- Enter confirms
                dbg('moved the game cursor to slot ' .. slot .. ' and pressed Enter')
                return
            end
        end
        dbg('could not perform the pending action; targeting instead')
    end
    M.target(slot)
end

-- dir = 1 (next) / -1 (previous); wraps around the visible members.
function M.cycle(dir)
    local n = M.norder
    if n == 0 then return false end
    local cur = -1
    for i = 1, n do if M.order[i] == M.sel then cur = i; break end end
    if cur < 0 then
        local ms = slot_for(hpp.st.main)
        for i = 1, n do if M.order[i] == ms then cur = i; break end end
    end
    local nxt
    if cur < 0 then nxt = (dir > 0) and 1 or n else nxt = ((cur - 1 + dir) % n) + 1 end
    M.select(M.order[nxt])
    return true
end
function M.clear() M.sel = -1 end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
K.LIST_OPEN, K.LIST_POS, K.SIZE, K.WPOS = { true }, { 0, 0 }, { 0, 0 }, { 0, 0 }
K.BTN = { 0, 0 }
K.BOX = { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
M.BOX = K.BOX                -- x0, y0, x1, y1 of the list's background this frame (valid while M.box_ok)
local STATE = { target = false, cursor = false, select = false }
local PTR = { on = false, x = 0, y = 0, lx = 0, ly = 0, cn = 0 }
M.PTR = PTR                                  -- (read by the tests)

local function flag(name) local v = rawget(_G, name); return type(v) == 'number' and v or 0 end

-- Layered PNG background: a fill (stretched or tiled), four edge strips and four corner pieces, each optional.
local function frame_bg(dl, L, x0, y0, x1, y1)
    local F = L.bg.frame
    local tint = u32(L.bg.tint)
    local function tex(f)
        if f == nil or f == '' or M.png_bg == nil then return nil end
        local t = M.png_bg:get(f)
        if t.id ~= nil then return t end
        return nil
    end
    local t = tex(F.bg)
    if t then
        local tw, th = t.w * (tonumber(F.tile) or 1), t.h * (tonumber(F.tile) or 1)
        if F.fit == 'tile' and tw >= 4 and th >= 4 and ((x1 - x0) / tw + 1) * ((y1 - y0) / th + 1) <= 400 then
            local yy = y0
            while yy < y1 do
                local hh = math.min(th, y1 - yy)
                local xx = x0
                while xx < x1 do
                    local ww = math.min(tw, x1 - xx)
                    image(dl, t.id, xx, yy, xx + ww, yy + hh, 0, 0, ww / tw, hh / th, tint)
                    xx = xx + tw
                end
                yy = yy + th
            end
        else
            image(dl, t.id, x0, y0, x1, y1, 0, 0, 1, 1, tint)
        end
    end
    local sc, ins = tonumber(F.scale) or 1, tonumber(F.inset) or 0
    local ax0, ay0, ax1, ay1 = x0 + ins, y0 + ins, x1 - ins, y1 - ins
    t = tex(F.top);    if t then image(dl, t.id, ax0, ay0, ax1, ay0 + t.h * sc, 0, 0, 1, 1, tint) end
    t = tex(F.bottom); if t then image(dl, t.id, ax0, ay1 - t.h * sc, ax1, ay1, 0, 0, 1, 1, tint) end
    t = tex(F.left);   if t then image(dl, t.id, ax0, ay0, ax0 + t.w * sc, ay1, 0, 0, 1, 1, tint) end
    t = tex(F.right);  if t then image(dl, t.id, ax1 - t.w * sc, ay0, ax1, ay1, 0, 0, 1, 1, tint) end
    t = tex(F.tl); if t then image(dl, t.id, ax0, ay0, ax0 + t.w * sc, ay0 + t.h * sc, 0, 0, 1, 1, tint) end
    t = tex(F.tr); if t then image(dl, t.id, ax1 - t.w * sc, ay0, ax1, ay0 + t.h * sc, 0, 0, 1, 1, tint) end
    t = tex(F.bl); if t then image(dl, t.id, ax0, ay1 - t.h * sc, ax0 + t.w * sc, ay1, 0, 0, 1, 1, tint) end
    t = tex(F.br); if t then image(dl, t.id, ax1 - t.w * sc, ay1 - t.h * sc, ax1, ay1, 0, 0, 1, 1, tint) end
end

-- Vertical gradient inside a rounded rectangle: thin strips whose ends follow the corner curve.
local function grad_rect(dl, x0, y0, x1, y1, c1, c2, r)
    local h = y1 - y0
    if h < 2 then return end
    local n = math.max(2, math.min(160, math.floor(h / 2)))
    r = math.min(r, h / 2, (x1 - x0) / 2)
    local prev = y0
    for i = 1, n do
        local ye = (i == n) and y1 or math.floor(y0 + h * i / n + 0.5)
        if ye > prev then
            local t = (i - 0.5) / n
            local m = mix(c1, c2, t)
            local ym = (prev + ye) / 2
            local inset = 0
            if r > 0 then
                local d = math.min(ym - y0, y1 - ym)
                if d < r then inset = r - math.sqrt(math.max(0, r * r - (r - d) * (r - d))) end
            end
            rect(dl, x0 + inset, prev, x1 - inset, ye, u32(m), 0)
            prev = ye
        end
    end
end

-- 2.5: the window's corners are rounded only with "Curved corners" on; then every border style follows the rounding.
function K.win_r(W) return W.curved == false and 0 or (tonumber(W.rounding) or 0) end

local function window_fill(dl, W, x0, y0, x1, y1)
    local rr = K.win_r(W)
    if W.grad then
        if (W.bg[4] or 0) > 0 or (W.bg2[4] or 0) > 0 then grad_rect(dl, x0, y0, x1, y1, W.bg, W.bg2, rr) end
    elseif (W.bg[4] or 0) > 0 then
        rect(dl, x0, y0, x1, y1, u32(W.bg), rr)
    end
    local ln = tonumber(W.lines) or 0
    if ln > 0.001 then                                    -- faint scanlines, like the game's own windows
        local ya = y0 + rr * 0.5
        while ya + 1 <= y1 - rr * 0.5 do
            rect(dl, x0 + rr * 0.5, ya, x1 - rr * 0.5, ya + 1, black(ln), 0)
            ya = ya + 3
        end
    end
end

local function window_border(dl, W, x0, y0, x1, y1)
    local bw = tonumber(W.border_w) or 0
    local c = W.border
    if bw <= 0 or (c[4] or 0) <= 0 then return end
    local rr = math.min(K.win_r(W), (x1 - x0) / 2, (y1 - y0) / 2)
    local st = W.style or 'line'
    if st == 'glow' then
        for k = 4, 1, -1 do frame(dl, x0 - k, y0 - k, x1 + k, y1 + k, u32(c, 0.07 + (4 - k) * 0.035), rr + k, 1.5) end
        frame(dl, x0, y0, x1, y1, u32(c), rr, bw)
    elseif st == 'double' then
        frame(dl, x0, y0, x1, y1, u32(c), rr, bw)
        local g = bw + 2
        frame(dl, x0 + g, y0 + g, x1 - g, y1 - g, u32(c, 0.5), math.max(0, rr - g), 1)
    elseif st == 'bevel' then
        frame(dl, x0, y0, x1, y1, u32(c), rr, bw)
        local g = bw
        rect(dl, x0 + rr + g, y0 + g, x1 - rr - g, y0 + g + 1, white(0.35), 0)
        rect(dl, x0 + g, y0 + rr + g, x0 + g + 1, y1 - rr - g, white(0.20), 0)
        rect(dl, x0 + rr + g, y1 - g - 1, x1 - rr - g, y1 - g, black(0.40), 0)
        rect(dl, x1 - g - 1, y0 + rr + g, x1 - g, y1 - rr - g, black(0.30), 0)
    elseif st == 'tb' then                                -- a line along the top and the bottom only
        local col, q = u32(c), rr
        rect(dl, x0 + q, y0, x1 - q, y0 + bw, col, 0)
        rect(dl, x0 + q, y1 - bw, x1 - q, y1, col, 0)
        if q > 0.5 then                                    -- curved: the lines bend down / up into the corners
            local ar = q - bw / 2
            K.arc(dl, x0 + q, y0 + q, ar, K.PI, K.PI + K.HPI, col, bw)
            K.arc(dl, x1 - q, y0 + q, ar, K.PI + K.HPI, 2 * K.PI, col, bw)
            K.arc(dl, x0 + q, y1 - q, ar, K.HPI, K.PI, col, bw)
            K.arc(dl, x1 - q, y1 - q, ar, 0, K.HPI, col, bw)
        end
    elseif st == 'custom' then                            -- a PNG frame from backgrounds\, cut in nine; thickness = drawn edge size
        local t = (M.png_bg ~= nil and (W.border_file or '') ~= '') and M.png_bg:get(W.border_file) or nil
        if t and t.id ~= nil then panel_image(dl, t, x0, y0, x1, y1, tonumber(W.border_slice) or 12, u32(c), bw)
        else frame(dl, x0, y0, x1, y1, u32(c), rr, math.min(bw, 3)) end
    elseif st == 'corners' then
        local q = rr
        local L_ = math.max(10, math.min(22, (x1 - x0) * 0.08), q + 6)
        local col = u32(c)
        rect(dl, x0 + q, y0, x0 + L_, y0 + bw, col, 0); rect(dl, x0, y0 + q, x0 + bw, y0 + L_, col, 0)
        rect(dl, x1 - L_, y0, x1 - q, y0 + bw, col, 0); rect(dl, x1 - bw, y0 + q, x1, y0 + L_, col, 0)
        rect(dl, x0 + q, y1 - bw, x0 + L_, y1, col, 0); rect(dl, x0, y1 - L_, x0 + bw, y1 - q, col, 0)
        rect(dl, x1 - L_, y1 - bw, x1 - q, y1, col, 0); rect(dl, x1 - bw, y1 - L_, x1, y1 - q, col, 0)
        if q > 0.5 then                                    -- curved: each bracket bends round its corner
            local ar = q - bw / 2
            K.arc(dl, x0 + q, y0 + q, ar, K.PI, K.PI + K.HPI, col, bw)
            K.arc(dl, x1 - q, y0 + q, ar, K.PI + K.HPI, 2 * K.PI, col, bw)
            K.arc(dl, x0 + q, y1 - q, ar, K.HPI, K.PI, col, bw)
            K.arc(dl, x1 - q, y1 - q, ar, 0, K.HPI, col, bw)
        end
        frame(dl, x0, y0, x1, y1, u32(c, 0.18), rr, 1)
    elseif st == 'gilded' then
        frame(dl, x0, y0, x1, y1, u32(c), rr, bw)
        local g = bw + 3
        frame(dl, x0 + g, y0 + g, x1 - g, y1 - g, u32(c, 0.55), math.max(0, rr - g), 1)
        for _, p in ipairs({ { x0 + g + 4, y0 + g + 4 }, { x1 - g - 4, y0 + g + 4 }, { x0 + g + 4, y1 - g - 4 }, { x1 - g - 4, y1 - g - 4 } }) do
            P1[1], P1[2] = p[1], p[2]
            dl:AddCircleFilled(P1, 2.4, u32(c), 10)
        end
    else
        frame(dl, x0, y0, x1, y1, u32(c), rr, bw)
    end
end

local function window_background(dl, L, x0, y0, x1, y1)
    local BG = L.bg
    local W = L.win
    -- 2.13.1: RecastXI's theme frame (pxirecast M.theme_panel); its own look below when RecastXI did not start
    if BG.rx_theme == true and M.rx_panel ~= nil then
        local ok, drawn = pcall(M.rx_panel, dl, x0, y0, x1, y1, GA)
        if ok and drawn then return end
    end
    if BG.mode == 'frame' then
        window_fill(dl, W, x0, y0, x1, y1)
        frame_bg(dl, L, x0, y0, x1, y1)
        window_border(dl, W, x0, y0, x1, y1)
        return
    end
    if BG.mode == 'png' and BG.scope == 'window' and M.png_bg ~= nil and BG.file ~= '' then
        local t = M.png_bg:get(BG.file)
        if t.id ~= nil then panel_image(dl, t, x0, y0, x1, y1, BG.slice, u32(BG.tint)); window_border(dl, W, x0, y0, x1, y1); return end
    end
    window_fill(dl, W, x0, y0, x1, y1)
    window_border(dl, W, x0, y0, x1, y1)
end

-- The list's background and border drawn into another rect (the Recasts module's "party list" frame), at an alpha.
function M.panel(dl, x0, y0, x1, y1, alpha)
    local ga = GA
    GA = alpha or 1
    local ok, e = pcall(window_background, dl, hpp.s.list, x0, y0, x1, y1)
    GA = ga
    if not ok then error(e, 0) end
end

-- For the settings window: a PNG from backgrounds\ cut in nine (slice px), drawn into a box, as the list would draw it.
function M.preview_panel(dl, file, x0, y0, x1, y1, slice, tint, size)
    if M.png_bg == nil or file == nil or file == '' then return false end
    local t = M.png_bg:get(file)
    if t.id == nil then return false end
    local ga = GA; GA = 1
    panel_image(dl, t, x0, y0, x1, y1, slice, u32(tint or K.WHITE1), size)
    GA = ga
    return true
end
K.WHITE1 = { 1, 1, 1, 1 }

-- Opens a folder in Windows Explorer (ShellExecute; falls back to "start").
function M.open_folder(dir)
    local ok = pcall(function ()
        if K.SHELL == nil then
            pcall(ffi.cdef, 'void* ShellExecuteA(void* hwnd, const char* op, const char* file, const char* params, const char* dir, int show);')
            K.SHELL = ffi.load('shell32')
        end
        K.SHELL.ShellExecuteA(nil, 'open', dir, nil, nil, 1)
    end)
    if not ok then pcall(os.execute, 'start "" "' .. tostring(dir) .. '"') end
end

---------------------------------------------------------------------------
-- Dragging elements (Positions tab) and the marks that show where each element is justified
---------------------------------------------------------------------------
M.edit_slot, M.edit_until = -1, 0
M.drag_key, M.drag_t = nil, -10
local DRAG = { key = nil, was = false, sx = 0, sy = 0, mx = 0, my = 0 }
K.PRIO_KEYS = { 'icon', 'name', 'job', 'ptext', 'hp', 'mp', 'tp', 'action', 'buffs' }
K.AMBER = { 1.00, 0.78, 0.20, 1 }
local function clampi(v, lo, hi) v = math.floor(v + 0.5); if v < lo then return lo elseif v > hi then return hi end return v end

local function mouse()
    local ok, x, y = pcall(imgui.GetMousePos)
    if not ok then return nil end
    if type(x) == 'table' then x, y = x.x or x[1], x.y or x[2] end
    return tonumber(x), tonumber(y)
end

-- Is this element currently being dragged, or was it within the last 2 seconds? (the settings window highlights its row)
function M.active_key(now)
    if DRAG.key then return DRAG.key end
    if M.drag_key and now - M.drag_t < 2 then return M.drag_key end
    return nil
end

local function edit_pass(L, now)
    local mx, my = mouse()
    if mx == nil then return end
    local okd, down = pcall(imgui.IsMouseDown, 0)
    down = okd and down == true
    local hov = nil
    -- the topmost element under the mouse wins: pointer and group title first, then the cards' elements from the highest layer down
    local PRIO = { 'pointer', 'head' }
    do
        local ks = {}
        for _, k in ipairs(K.PRIO_KEYS) do ks[#ks + 1] = k end
        table.sort(ks, function (p, q)
            local zp, zq = tonumber(L[p].z) or ZDEF[p], tonumber(L[q].z) or ZDEF[q]
            if zp ~= zq then return zp > zq end
            return p < q
        end)
        for _, k in ipairs(ks) do PRIO[#PRIO + 1] = k end
    end
    for _, k in ipairs(PRIO) do
        local h = HIT[k]
        if h ~= nil and h.f == FRAMEID and mx >= h.x0 - 2 and mx <= h.x1 + 2 and my >= h.y0 - 2 and my <= h.y1 + 2 then hov = k; break end
    end
    if not down then DRAG.key, DRAG.was = nil, false end
    if down and not DRAG.was then
        DRAG.was = true
        local okh, wh = pcall(imgui.IsWindowHovered)
        if hov ~= nil and okh and wh then
            local t = (hov == 'pointer') and L.pointer or L[hov]
            DRAG.key, DRAG.sx, DRAG.sy, DRAG.mx, DRAG.my = hov, tonumber(t.dx) or 0, tonumber(t.dy) or 0, mx, my
        end
    end
    if DRAG.key and down then
        local t = (DRAG.key == 'pointer') and L.pointer or L[DRAG.key]
        local lim = (DRAG.key == 'pointer' or DRAG.key == 'head') and 400 or 600
        t.dx, t.dy = clampi(DRAG.sx + (mx - DRAG.mx), -lim, lim), clampi(DRAG.sy + (my - DRAG.my), -lim, lim)
        M.drag_key, M.drag_t = DRAG.key, now
        hpp.schedule_save()
    end

    -- marks, on the foreground list so they are never cut off
    local fg = imgui.GetForegroundDrawList()
    GA, EA = 1, 1
    Info.set_alpha(1)
    for k, h in pairs(HIT) do
        if h.f == FRAMEID then frame(fg, h.x0, h.y0, h.x1, h.y1, Draw.u32({ 1, 1, 1, 1 }, k == hov and 0.55 or 0.16), 2, 1) end
    end
    local key, a = nil, 1
    if DRAG.key then key = DRAG.key
    elseif M.drag_key and now - M.drag_t < 2 then key = M.drag_key; a = math.min(1, (2 - (now - M.drag_t)) / 0.5) end
    local h = key and HIT[key] or nil
    if h ~= nil and h.f == FRAMEID then
        local col = Draw.u32(K.AMBER, a)
        frame(fg, h.x0 - 1, h.y0 - 1, h.x1 + 1, h.y1 + 1, col, 2, 1.5)
        rect(fg, h.ax - 1, h.ay - 9, h.ax + 1, h.ay + 9, col, 0)            -- tick at the justify point
        P1[1], P1[2] = h.ax, h.ay
        fg:AddCircleFilled(P1, 3.5, col, 12)
        if h.side == 'center' then
            tri(fg, h.ax + 12, h.ay, h.ax + 6, h.ay - 4, h.ax + 6, h.ay + 4, col)
            tri(fg, h.ax - 12, h.ay, h.ax - 6, h.ay - 4, h.ax - 6, h.ay + 4, col)
        else
            local d = (h.side == 'right') and -1 or 1                       -- the way the element grows from its anchor
            tri(fg, h.ax + d * 12, h.ay, h.ax + d * 6, h.ay - 4, h.ax + d * 6, h.ay + 4, col)
        end
        local t = (key == 'pointer') and L.pointer or L[key]
        -- shown like the sliders: + = up
        text(fg, ('%s  %d, %d'):format(key, tonumber(t.dx) or 0, -(tonumber(t.dy) or 0)), h.x0, h.y0 - 9, 'left', Draw.u32(K.AMBER, a), 0.8, nil, 'base')
    end
end

-- Entries of the animated list: one per card / pet / title. p = presence 0..1 (grows in, shrinks out).
local ENT, ORD, NO = {}, {}, 0
local ITEMS, NI = {}, 0

local function cubic(p) if p >= 1 then return 1 elseif p <= 0 then return 0 end return 1 - (1 - p) ^ 3 end
local function by_order(a, b) if a.ord ~= b.ord then return a.ord < b.ord end return a.key < b.key end
-- 2.6.0: the space after list item a (before b): pets and alliance cards have their own spacing
local function gap_of(L, a, b)
    if (a.kind == 'pet') or (b ~= nil and b.kind == 'pet') then return tonumber(L.gap_pet) or 0 end
    if b ~= nil and a.kind == 'card' and b.kind == 'card' and (a.slot or 0) >= 6 and (b.slot or 0) >= 6 then return tonumber(L.gap_ally) or 0 end
    return tonumber(L.gap) or 0
end

local function add_item(key, ord, kind, r, h, compact, txt, slot, w)
    NI = NI + 1
    local it = ITEMS[NI]
    if it == nil then it = {}; ITEMS[NI] = it end
    it.key, it.ord, it.kind, it.r, it.h, it.compact, it.text, it.slot, it.w = key, ord, kind, r, h, compact, txt, slot, w
end

local function snapshot(r)
    local c = {}
    for k, v in pairs(r) do c[k] = v end
    return c
end


-- Where a group title's text goes: its anchor x and alignment, and the left / right ends of the text.
local function head_span(L, e, wx, W, ox)
    local H, pad = L.head, LY.bleed
    local hx0, hx1 = wx + pad + 2 + ox, wx + pad + W - pad * 2 - 2
    local tw = text_w(e.text, H.scale, 'head')
    local al = H.align or 'left'
    local tx, ax = hx0, 'left'
    if al == 'center' then tx, ax = (hx0 + hx1) / 2, 'center' elseif al == 'right' then tx, ax = hx1, 'right' end
    tx = tx + (tonumber(H.dx) or 0)
    local lx0, lx1 = tx, tx + tw
    if ax == 'center' then lx0, lx1 = tx - tw / 2, tx + tw / 2 elseif ax == 'right' then lx0, lx1 = tx - tw, tx end
    return tx, ax, lx0, lx1, hx0, hx1
end

-- 2.7.0: alliance cards with their own sizes / offsets: the party values and the alliance's are swapped in place
-- around drawing an alliance card (called twice: in, then back)
K.ALLY_F = { name = { 'scale', 'dx', 'dy' }, job = { 'scale', 'dx', 'dy' }, icon = { 'size', 'dx', 'dy' }, action = { 'scale', 'dx', 'dy' },
    hp = { 'height', 'length', 'dx', 'dy', 'text_scale', 'text_dx', 'text_dy' }, mp = { 'height', 'length', 'dx', 'dy', 'text_scale', 'text_dx', 'text_dy' },
    tp = { 'height', 'length', 'dx', 'dy', 'text_scale', 'text_dx', 'text_dy' } }
function K.ally_swap(L, AL)
    for el, fs in pairs(K.ALLY_F) do
        local a, p = AL[el], L[el]
        if a ~= nil and p ~= nil then
            for _, f in ipairs(fs) do
                if a[f] ~= nil then a[f], p[f] = p[f], a[f] end
            end
        end
    end
end
-- Copies the party's current values into the alliance's (the first time they are turned on).
function M.ally_copy(L)
    local AL = L.ally_look
    for el, fs in pairs(K.ALLY_F) do
        for _, f in ipairs(fs) do if L[el][f] ~= nil then AL[el][f] = L[el][f] end end
    end
end

local function body(L, now, sample, W, H, mg, sub)
    local wx, wy = imgui.GetWindowPos()
    wx, wy = (tonumber(wx) or 0) + mg, (tonumber(wy) or 0) + mg
    Draw.obst(wx, wy, wx + (tonumber(W) or 0), wy + (tonumber(H) or 0))      -- 2.10.0: the target bar keeps off this window
    local dl = imgui.GetWindowDrawList()
    local clip_full = pcall(dl.PushClipRectFullScreen, dl)
    if not clip_full then clip_full = pcall(dl.PushClipRect, dl, { -20000, -20000 }, { 20000, 20000 }, false) end       -- elements may sit outside the window; do not cut them off
    EA = 1
    GA = 1
    Info.set_alpha(1)
    -- the background and border start at the first group title's middle (the title sits half over the top edge, like a
    -- label on a frame), moved by "Border starts"; without a title at the window's top
    local top = wy
    local e1 = ORD[1]
    if e1 ~= nil and e1.kind == 'hdr' then top = wy + e1.y + e1.h / 2 + (tonumber(L.head.dy) or 0) end
    top = math.max(wy - 60, math.min(wy + H - 8, top + (tonumber(L.win.top_dy) or 0)))
    window_background(dl, L, wx, top, wx + W, wy + H)
    if not sub then
        Draw.hl_rect('list', 'window', wx, top, wx + W, wy + H)
        K.BOX.x0, K.BOX.y0, K.BOX.x1, K.BOX.y1 = wx, top, wx + W, wy + H     -- for the Recasts module (attached above the list)
        M.box_ok = true
    end
    if e1 ~= nil and e1.kind == 'hdr' and cubic(e1.p) > 0.01 then
        -- the border line is broken under the title (covered with the background color), so the text reads cleanly
        local hh = px(L.head.scale)
        local ty = wy + e1.y + e1.h / 2 + (tonumber(L.head.dy) or 0)
        if math.abs(top - ty) < hh / 2 + 1 and L.win.style ~= 'custom' and L.bg.mode ~= 'png' then
            local _, _, lx0, lx1 = head_span(L, e1, wx, W, 0)
            local bw = math.max(1, tonumber(L.win.border_w) or 1)
            local bg = L.win.bg
            rect(dl, lx0 - 5, top - 1, lx1 + 5, top + bw + 1, u32(bg[4] and bg[4] > 0 and { bg[1], bg[2], bg[3], 1 } or bg), 0)
        end
    end

    ST.shadow = L.shadow and 0.85 or 0
    ST.outline = L.outline == true
    ST.ow, ST.oc = tonumber(L.outline_w) or 1, L.outline_color

    local st = hpp.st
    local sub_slot = st.slot
    if sub_slot < 0 and st.sub ~= 0 then sub_slot = slot_for(st.sub) end
    local main_slot = slot_for(st.main)
    local sel = M.sel
    if sample then
        -- 2.6.1 / 2.10.1: the Test cycles each member in turn as target, then sub-target, then selected (3 s each);
        -- this was its own "Test highlight" button
        local t = math.floor(now / 3)
        local who = M.order[(math.floor(t / 3) % math.max(1, M.norder)) + 1] or -1
        local k = t % 3
        main_slot, sub_slot, sel = (k == 0) and who or -1, (k == 1) and who or -1, (k == 2) and who or -1
    end

    local interactive = L.locked and L.click_select and mg == 0
    local pad = LY.bleed
    local slide = L.anim.slide and L.anim.enable
    local hdr_done = false
    for i = 1, NO do
        local e = ORD[i]
        local hf = cubic(e.p)
        if hf > 0.01 then
            local dy = wy + e.y
            local ox = slide and (-(1 - hf) * 30) or 0
            EA = e.p * e.p * (3 - 2 * e.p)
            local cardw = e.w
            if e.kind == 'hdr' then
                GA = EA
                Info.set_alpha(GA)
                local H = L.head
                local hc = H.color
                local tx, ax, lx0, lx1, hx0, hx1 = head_span(L, e, wx, W, ox)
                local ty = dy + e.h / 2 + (tonumber(H.dy) or 0)
                text(dl, e.text, tx, ty, ax, u32(hc), H.scale, nil, 'head')
                local ly = dy + e.h / 2
                local rc = u32(hc, 0.30)
                if not (i == 1 and math.abs(top - ty) < 3) then        -- a title sitting on the border needs no rule of its own
                    rect(dl, hx0, ly, lx0 - 6, ly + 1, rc, 0)
                    rect(dl, lx1 + 6, ly, hx1, ly + 1, rc, 0)
                end
                if (mg > 0 or HLL) and not hdr_done then
                    hdr_done = true
                    EREC = true
                    local hh = px(H.scale)
                    hit('head', lx0, ty - hh / 2, lx1, ty + hh / 2, tx, ty, ax == 'left' and 'left' or (ax == 'right' and 'right' or 'center'))
                    EREC = false
                end
            elseif e.kind == 'pet' then
                local ind = e.attached and L.pets.indent or 0
                draw_pet(dl, L, e.r, wx + pad + ind + ox, dy, cardw, e.h, now, e.attached)
            else
                local r = e.r
                STATE.target = (r.slot == main_slot)
                STATE.cursor = (r.slot == sub_slot)
                STATE.select = (r.slot == sel)
                local hovered = false
                if interactive and e.seen and e.p > 0.9 then
                    K.BTN[1], K.BTN[2] = cardw, e.h
                    P1[1], P1[2] = wx + pad, dy
                    imgui.SetCursorScreenPos(P1)
                    -- over one of its effect icons the click belongs to the icon (cancel), not the card
                    if not Buffs.hovering(r.slot) and imgui.InvisibleButton('##plcard' .. r.slot, K.BTN) then M.select(r.slot, true) end
                    hovered = imgui.IsItemHovered()
                end
                local AL = L.ally_look
                if r.slot >= 6 and AL ~= nil and AL.on then
                    K.ally_swap(L, AL)
                    local okc, ec = pcall(draw_card, dl, L, r, wx + pad + ox, dy, cardw, e.h, e.compact, STATE, hovered, now)
                    K.ally_swap(L, AL)
                    if not okc then error(ec, 0) end
                else
                    draw_card(dl, L, r, wx + pad + ox, dy, cardw, e.h, e.compact, STATE, hovered, now)
                end
            end
        end
    end
    EA = 1
    GA = 1
    Info.set_alpha(1)
    if sub then
        if clip_full then dl:PopClipRect() end
        return
    end

    -- the pointer: the arrow chosen in the Pointer tab, beside the name of the member the cursor / selection is on;
    -- it glides up and down between members. Drawn on the foreground list so it can sit outside the window.
    local P = L.pointer
    local pslot, pmain = -1, false
    if P.show then
        if sub_slot >= 0 and Data.m[sub_slot + 1].active then pslot = sub_slot
        elseif sel >= 0 and Data.m[sel + 1].active then pslot = sel
        elseif main_slot >= 0 and Data.m[main_slot + 1].active then pslot, pmain = main_slot, true end
    end
    if pslot >= 0 and NPY[pslot + 1] ~= nil then
        -- The pointer is only drawn once its target has been the same member for two frames (and, for a first
        -- appearance, at the same spot): a one-frame wrong slot or a card still being laid out never shows it.
        -- Its position is kept relative to the window, so a window that moves or resizes does not make it jump.
        local tx, ty = NPX[pslot + 1] - wx, NPY[pslot + 1] - wy
        if PTR.cs == pslot then PTR.cn = PTR.cn + 1 else PTR.cs, PTR.cn = pslot, 1 end
        local ready = PTR.cn >= 2
        if not PTR.on then ready = ready and math.abs(tx - PTR.lx) < 0.75 and math.abs(ty - PTR.ly) < 0.75 end
        PTR.lx, PTR.ly = tx, ty
        if not PTR.on and ready then PTR.x, PTR.y, PTR.on, PTR.slot = tx, ty, true, pslot end
        if PTR.on and ready then
            PTR.slot = pslot
            if not P.glide then PTR.x, PTR.y = tx, ty
            else
                local k = math.min(1, dt * (tonumber(P.glide_speed) or 14))
                PTR.x, PTR.y = PTR.x + (tx - PTR.x) * k, PTR.y + (ty - PTR.y) * k
            end
        elseif PTR.on and PTR.slot == pslot then
            PTR.x, PTR.y = tx, ty
        end
    end
    if PTR.on and pslot >= 0 and NPY[pslot + 1] ~= nil then
        local px0, py0 = PTR.x, PTR.y
        PTR.x, PTR.y = wx + px0, wy + py0
        local ar = hpp.s.arrow
        local bob, alpha = Draw.anim(ar, now)
        if pmain then bob, alpha = 0, 1 end
        local line = ar.outline and Draw.u32(ar.outline_color, alpha) or 0
        local fg = imgui.GetForegroundDrawList()
        M.pdraw_t = now
        hpp.shape(fg, PTR.x + (tonumber(P.dx) or 0) - bob * 0.5, PTR.y + (tonumber(P.dy) or 0), 'right', tonumber(P.size) or 14,
            pmain and ar.main_color or ar.sub_color, alpha, line, tonumber(ar.outline_thickness) or 2)
        if mg > 0 or HLL then
            EREC = true
            local psz = tonumber(P.size) or 14
            local px_, py_ = PTR.x + (tonumber(P.dx) or 0), PTR.y + (tonumber(P.dy) or 0)
            hit('pointer', px_ - psz, py_ - psz / 2, px_ + 2, py_ + psz / 2, px_, py_, 'right')
            EREC = false
        end
        PTR.x, PTR.y = px0, py0
    elseif not (pslot >= 0 and NPY[pslot + 1] ~= nil) then
        PTR.on, PTR.cs, PTR.cn = false, nil, 0
    end

    draw_invite(L, now, wx, wy, W)

    if mg > 0 then edit_pass(L, now) end
    if clip_full then dl:PopClipRect() end

    if not L.locked then
        local x, yy = imgui.GetWindowPos()
        if type(x) == 'number' and type(yy) == 'number'
            and (math.abs(x + mg - K.LIST_POS[1]) > 0.5 or math.abs(yy + mg - K.LIST_POS[2]) > 0.5) then
            L.x, L.y = math.floor(x + mg), math.floor(yy + mg + ((tonumber(L.y) or 320) - K.LIST_POS[2])); hpp.schedule_save()   -- the saved spot is without the upward growth
        end
    end
end

-- 2.7.1: members in your own party (the title says Solo only when it is just you)
function K.party_n() local n = 0; for sl = 0, 5 do if Data.m[sl + 1].active then n = n + 1 end end; return n end
K.GROUPS = { { 0, 5, 'Party' }, { 6, 11, 'Alliance 1' }, { 12, 17, 'Alliance 2' } }

local function fail(e)
    M.broken = true
    hpp.err('The party list hit an error and was turned off (/pxi list on retries): ' .. tostring(e))
end

-- Places the entries of ORD (1..NO) top to bottom; returns the window's height and widest entry.
local function layout(L, instant, ease)
    local pad = LY.bleed
    local y, lastgap, maxw = pad, 0, 0
    for i = 1, NO do
        local e = ORD[i]
        local gap = gap_of(L, e, ORD[i + 1])
        local hf = cubic(e.p)
        local ew = (e.w or 0) + ((e.kind == 'pet' and e.attached) and (tonumber(L.pets.indent) or 0) or 0)
        if e.kind ~= 'hdr' and ew > maxw then maxw = ew end
        e.ty = y
        if e.y == nil or instant then e.y = y else e.y = e.y + (y - e.y) * ease end
        y = y + e.h * hf + gap * hf
        lastgap = gap * hf
    end
    return (NO > 0) and (y - lastgap + pad) or 0, maxw
end

function M.box() return K.BOX end
K.GW = { main = { l = {}, n = 0 }, ally = { l = {}, n = 0 }, pets = { l = {}, n = 0 } }
K.SUBPOS, K.SUBSIZE, K.SUBOPEN = { 0, 0 }, { 0, 0 }, { true }
-- 2.6.2: an undocked group (alliance or pets) in its own window at P.x / P.y (its top left), dragged like the list
local function sub_window(L, now, sample, G, id, P, editing, instant, ease)
    if G.n == 0 or P == nil then return end
    local all_o, all_n = ORD, NO
    ORD, NO = G.l, G.n
    local total, maxw = layout(L, instant, ease)
    local pad = LY.bleed
    local flags = bit.bor(flag('ImGuiWindowFlags_NoDecoration'), flag('ImGuiWindowFlags_NoBackground'),
        flag('ImGuiWindowFlags_NoNav'), flag('ImGuiWindowFlags_NoFocusOnAppearing'), flag('ImGuiWindowFlags_NoSavedSettings'),
        flag('ImGuiWindowFlags_NoScrollWithMouse'), flag('ImGuiWindowFlags_NoBringToFrontOnFocus'))
    if editing or L.locked then flags = bit.bor(flags, flag('ImGuiWindowFlags_NoMove')) end
    if L.locked and not L.click_select then flags = bit.bor(flags, flag('ImGuiWindowFlags_NoInputs')) end
    local px_, py_ = tonumber(P.x) or 300, tonumber(P.y) or 320
    K.SUBPOS[1], K.SUBPOS[2] = px_, py_
    K.SUBSIZE[1], K.SUBSIZE[2] = math.max(maxw, 20) + pad * 2, math.max(2, total)
    imgui.SetNextWindowPos(K.SUBPOS, (L.locked or editing) and flag('ImGuiCond_Always') or flag('ImGuiCond_FirstUseEver'))
    imgui.SetNextWindowSize(K.SUBSIZE, flag('ImGuiCond_Always'))
    K.SUBOPEN[1] = true
    local pv = imgui.PushStyleVar ~= nil and rawget(_G, 'ImGuiStyleVar_WindowPadding') ~= nil
        and pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 0, 0 })
    local okb, open = pcall(imgui.Begin, 'partyramaxi_plist_' .. id, K.SUBOPEN, flags)
    if pv then imgui.PopStyleVar() end
    local ok, e = okb, open
    if okb then
        if open then
            ok, e = pcall(body, L, now, sample, K.SUBSIZE[1], K.SUBSIZE[2], 0, id)
            Fonts.unwind()
            if not L.locked and not editing then
                local x, y = imgui.GetWindowPos()
                if type(x) == 'number' and type(y) == 'number' and (math.abs(x - px_) > 0.5 or math.abs(y - py_) > 0.5) then
                    P.x, P.y = math.floor(x), math.floor(y); hpp.schedule_save()
                end
            end
        end
        imgui.End()
    end
    ORD, NO = all_o, all_n
    if not ok then fail(e) end
end

function M.draw(now, sample, cycle)
    if M.broken then return end
    local L = hpp.s.list
    dt = math.min(0.1, math.max(0.001, now - last_now)); last_now = now
    BASE = tonumber(imgui.GetFontSize()) or 14
    resolve_fonts(L); M.wcheck()

    local AN = L.anim
    local spd = math.max(0.1, tonumber(AN.speed) or 1)
    local instant = not AN.enable
    if now - last_draw > 0.5 or was_sample ~= (sample == true) then
        for k in pairs(ENT) do ENT[k] = nil end
        instant = true
    end
    last_draw = now
    was_sample = (sample == true)

    local RO = L.roles
    Data.masks.leader, Data.masks.aleader, Data.masks.qm = tonumber(RO.leader_mask) or 0, tonumber(RO.aleader_mask) or 0, tonumber(RO.qm_mask) or 0

    FRAMEID = FRAMEID + 1
    BF.sample = sample == true
    Buffs.begin(mouse())
    local EDITING = now < (M.edit_until or 0)
    local mg = EDITING and 140 or 0
    HLL = Draw.hl_on('list')          -- a party list setting is hovered: record the first card's elements to frame one
    local last = L.alliance and 17 or 5
    local PC = L.pets
    local count
    if sample then count = Data.sample(now, last, cycle) else count = Data.read_all(now, tonumber(L.action.hold) or 1.5, last) end
    if not sample then
        if PC.show then Data.read_pets(PC.scope, last) else for i = 1, 18 do Data.pets[i].active = false end end
        local I = Data.invite
        if I.active and I.resolved == 0 and not I.test and Data.count_real() > I.count0 then Data.invite_resolve(now) end
    end

    -- the current set of entries
    NI = 0
    M.grow = 0                 -- "Fit to the card": total extra height; the list grows upward by it (its bottom stays put)
    -- "You at the bottom": the order is turned over (alliance 2, alliance 1, then your party with you last) and the list
    -- is held by its bottom edge, so a growing party extends upward
    local up = L.from_bottom ~= false
    local nord = 0
    local groups = 0
    for _, g in ipairs(K.GROUPS) do
        for sl = g[1], g[2] do if Data.m[sl + 1].active then groups = groups + 1; break end end
    end
    local sect_any = false
    local es = -1
    local selslot = M.sel
    if sample then
        local t = math.floor(now / 3)
        selslot = (t % 3 == 2) and (M.order[(math.floor(t / 3) % math.max(1, M.norder)) + 1] or -1) or -1
    end
    local hw = 120
    for _, k in ipairs({ 'party', 'alliance' }) do hw = math.max(hw, tonumber(L.cards[k].w) or 0) end
    for _, g in ipairs(K.GROUPS) do
        local first, last_slot, title = g[1], g[2], g[3]
        local any = false
        for sl = first, last_slot do if Data.m[sl + 1].active then any = true; break end end
        if any then
            if L.headers and (groups > 1 or L.head.show_solo) then add_item('h' .. title, up and ((17 - last_slot) * 10 - 1) or (first * 10 - 1), 'hdr', nil, px(L.head.scale) + 2, false, (title == 'Party' and K.party_n() <= 1) and 'Solo' or title, first, hw) end
            for sl = first, last_slot do
                local r = Data.m[sl + 1]
                if r.active then
                    nord = nord + 1
                    local comp = (sl >= 6) and L.alliance_compact
                    local cw, ch = card_wh(L, sl >= 6 and 'alliance' or 'party', sl == selslot)
                    if not comp then local g = M.card_grow(sl, r.name, now); ch = ch + g; M.grow = M.grow + g end
                    add_item('c' .. sl .. ':' .. r.name, up and (17 - sl) * 10 or sl * 10, 'card', r, ch, comp, '', sl, cw)
                    if es < 0 and not comp then es = sl end
                    M.order[nord] = sl
                    local pr = Data.pets[sl + 1]
                    if PC.show and pr.active then
                        if PC.mode == 'section' or PC.dock == false then sect_any = true
                        else local pw, ph = card_wh(L, 'pet'); add_item('p' .. sl .. ':' .. pr.name, (up and (17 - sl) * 10 or sl * 10) + 1, 'pet', pr, ph, false, '', sl, pw) end
                    end
                end
            end
        end
    end
    if sect_any then
        add_item('hPets', up and -1000 or 999, 'hdr', nil, px(L.head.scale) + 2, false, 'Pets', 99, hw)
        for sl = 0, 17 do
            local pr = Data.pets[sl + 1]
            if pr.active and Data.m[sl + 1].active then local pw, ph = card_wh(L, 'pet'); add_item('p' .. sl .. ':' .. pr.name, up and (-990 + sl) or (1000 + sl * 10), 'pet', pr, ph, false, '', sl, pw) end
        end
    end
    M.edit_slot = (EDITING or HLL) and es or -1
    for i = nord + 1, #M.order do M.order[i] = nil end
    M.norder = nord
    if M.sel >= 0 and not Data.m[M.sel + 1].active then M.sel = -1 end

    -- merge into the animated entries
    for _, e in pairs(ENT) do e.seen = false end
    for i = 1, NI do
        local it = ITEMS[i]
        local e = ENT[it.key]
        if e == nil then e = { p = instant and 1 or 0, key = it.key }; ENT[it.key] = e end
        e.seen = true
        e.ord, e.kind, e.h, e.compact, e.text, e.slot, e.w = it.ord, it.kind, it.h, it.compact, it.text, it.slot, it.w
        e.attached = (PC.mode ~= 'section') and PC.dock ~= false
        -- 2.6.2: undocked alliance / pets are drawn in their own windows
        local grp = 'main'
        if L.ally_dock == false and (it.slot or 0) >= 6 and (it.slot or 0) < 99 and it.kind ~= 'pet' then grp = 'ally' end
        if PC.dock == false and (it.kind == 'pet' or (it.kind == 'hdr' and it.slot == 99)) then grp = 'pets' end
        e.grp = grp
        e.r = it.r
        e.snap = false
    end
    local step = dt * spd / 0.32
    for k, e in pairs(ENT) do
        if not e.seen and not e.snap then
            if e.r ~= nil and e.kind ~= 'hdr' then e.r = snapshot(e.r); e.r.active = true end
            e.snap = true
        end
        if instant then e.p = e.seen and 1 or 0
        elseif e.seen then e.p = math.min(1, e.p + step)
        else e.p = math.max(0, e.p - step) end
        if e.p <= 0 and not e.seen then ENT[k] = nil end
    end
    NO = 0
    for _, e in pairs(ENT) do NO = NO + 1; ORD[NO] = e end
    for i = NO + 1, #ORD do ORD[i] = nil end
    table.sort(ORD, by_order)

    local pad = LY.bleed
    local ease = math.min(1, dt * 16 * spd)
    -- 2.6.2: split into the party list window and the undocked alliance / pets windows
    local GW = K.GW
    for _, g in pairs(GW) do g.n = 0 end
    for i = 1, NO do local e = ORD[i]; local g = GW[e.grp or 'main']; g.n = g.n + 1; g.l[g.n] = e end
    for _, g in pairs(GW) do for i = g.n + 1, #g.l do g.l[i] = nil end end
    for i = 1, 18 do NPX[i], NPY[i] = nil, nil end      -- only cards actually drawn this frame may place the pointer
    sub_window(L, now, sample, GW.ally, 'ally', L.ally_win, EDITING, instant, ease)
    sub_window(L, now, sample, GW.pets, 'pets', PC.win, EDITING, instant, ease)
    local all_o, all_n = ORD, NO
    ORD, NO = GW.main.l, GW.main.n
    local total, maxw = layout(L, instant, ease)

    local inv = Data.invite
    if NO == 0 and not inv.active then ORD, NO = all_o, all_n; return end
    if total < 2 then total = 2 end

    local flags = bit.bor(flag('ImGuiWindowFlags_NoDecoration'), flag('ImGuiWindowFlags_NoBackground'),
        flag('ImGuiWindowFlags_NoNav'), flag('ImGuiWindowFlags_NoFocusOnAppearing'), flag('ImGuiWindowFlags_NoSavedSettings'),
        flag('ImGuiWindowFlags_NoScrollWithMouse'), flag('ImGuiWindowFlags_NoBringToFrontOnFocus'))
    if EDITING then
        flags = bit.bor(flags, flag('ImGuiWindowFlags_NoMove'))          -- dragging an element must not drag the window
    elseif L.locked then
        flags = bit.bor(flags, flag('ImGuiWindowFlags_NoMove'))
        -- the mouse over one of your effect icons: take the click (tooltip / cancel) instead of passing it to the game
        if not L.click_select and not Buffs.hovering(0) then flags = bit.bor(flags, flag('ImGuiWindowFlags_NoInputs')) end
    end
    -- 2.7.6: "Grow upward" holds the bottom edge with you still at the top: added members push the list up, and it
    -- shrinks back down when the party gets smaller. "You at the bottom" always holds the bottom edge.
    if up or L.grow_up ~= false then
        -- the saved spot is the list's bottom edge. Settings from before 2.2 kept its top: convert them once.
        if not L.bot220 then
            local ft = LY.bleed * 2                                         -- the full height (not the animated one)
            for i = 1, NI do ft = ft + ITEMS[i].h + (i < NI and gap_of(L, ITEMS[i], ITEMS[i + 1]) or 0) end
            L.y = math.floor((tonumber(L.y) or 320) + ft + 0.5); L.bot220 = true; hpp.schedule_save()
        end
        K.LIST_POS[1], K.LIST_POS[2] = tonumber(L.x) or 40, (tonumber(L.y) or 700) - math.floor(total + 0.5)
    else
        if L.bot220 then
            local ft = LY.bleed * 2
            for i = 1, NI do ft = ft + ITEMS[i].h + (i < NI and gap_of(L, ITEMS[i], ITEMS[i + 1]) or 0) end
            L.y = math.floor((tonumber(L.y) or 700) - ft + 0.5); L.bot220 = false; hpp.schedule_save()
        end
        K.LIST_POS[1], K.LIST_POS[2] = tonumber(L.x) or 40, (tonumber(L.y) or 320) - math.floor(M.grow + 0.5)
    end
    K.LIST_OPEN[1] = true
    local cond_always, cond_first = flag('ImGuiCond_Always'), flag('ImGuiCond_FirstUseEver')
    -- while editing, the window gets a margin so elements dragged outside the list are still inside it (and draggable)
    local winw = math.max(maxw, 20) + pad * 2
    K.SIZE[1], K.SIZE[2] = winw + mg * 2, total + mg * 2
    K.WPOS[1], K.WPOS[2] = K.LIST_POS[1] - mg, K.LIST_POS[2] - mg
    local force = (mg ~= (M.last_mg or 0)) or K.LIST_POS[2] ~= (M.last_gy or K.LIST_POS[2])
    M.last_mg, M.last_gy = mg, K.LIST_POS[2]
    imgui.SetNextWindowPos(K.WPOS, (L.locked or force or EDITING) and cond_always or cond_first)
    imgui.SetNextWindowSize(K.SIZE, cond_always)
    local pv = imgui.PushStyleVar ~= nil and rawget(_G, 'ImGuiStyleVar_WindowPadding') ~= nil
        and pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 0, 0 })
    local okb, open = pcall(imgui.Begin, 'partyramaxi_plist', K.LIST_OPEN, flags)
    if pv then imgui.PopStyleVar() end
    if not okb then fail(open); return end
    local ok, e = true, nil
    if open then
        ok, e = pcall(body, L, now, sample, winw, total, mg)
        Fonts.unwind()
    end
    imgui.End()
    ORD, NO = all_o, all_n
    Info.set_alpha(1)
    if not ok then fail(e) end
end

return M
