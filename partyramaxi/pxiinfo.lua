--[[
* PartyramaXI - enemy info next to the pointer: name, health bar, level (range) and what it checks as.
*
* The game does not keep a monster's level or check result in memory; it only tells you when you /check.
* So this module collects it from the three places it shows up:
*   1. the check reply packet (0x0029),
*   2. the chat line of the reply (fallback, also understands "Lv. 18-20" style ranges),
*   3. a per-name memory of the levels seen this session (that is where a range comes from).
* Everything is stored by entity index with the monster's name, so a reused index is never trusted.
--]]
local imgui = require('imgui')
local Draw  = require('pxidraw')
local Fonts = require('pxifonts')

local M = {}

-- difficulty 1..8, in the order the client numbers them (0x40..0x47)
M.DIFF = {
    { short = 'TW',  full = 'Too weak',             color = { 0.62, 0.62, 0.68, 1 } },
    { short = 'IEP', full = 'Incredibly easy prey', color = { 0.55, 0.80, 1.00, 1 } },
    { short = 'EP',  full = 'Easy prey',            color = { 0.35, 0.60, 1.00, 1 } },
    { short = 'DC',  full = 'Decent challenge',     color = { 0.45, 0.90, 0.50, 1 } },
    { short = 'EM',  full = 'Even match',           color = { 1.00, 1.00, 1.00, 1 } },
    { short = 'T',   full = 'Tough',                color = { 1.00, 0.90, 0.35, 1 } },
    { short = 'VT',  full = 'Very tough',           color = { 1.00, 0.60, 0.25, 1 } },
    { short = 'IT',  full = 'Incredibly tough',     color = { 1.00, 0.35, 0.30, 1 } },
    -- 2.13.1: notorious monsters, battlefield monsters and a few others only answer "impossible to gauge"
    { short = '??',  full = 'Impossible to gauge',  color = { 0.85, 0.55, 1.00, 1 } },
}
M.GAUGE = 9
-- chat phrases, longest first so "incredibly easy prey" is not read as "easy prey"
local PHRASES = {
    { 'impossible to gauge', 9 }, { 'incredibly easy prey', 2 }, { 'easy prey', 3 }, { 'too weak', 1 }, { 'decent challenge', 4 },
    { 'even match', 5 }, { 'incredibly tough', 8 }, { 'very tough', 7 }, { 'tough', 6 },
}
for _, d in ipairs(M.DIFF) do d.both = d.short .. ' - ' .. d.full end
M.CHECK_STYLES = { 'short', 'full', 'both' }
M.CHECK_LABELS = { short = 'Short (EP, DC, VT...)', full = 'Spelled out (Easy prey...)', both = 'Both (DC - Decent challenge)' }

M.checks = {}      -- entity index -> { name, sid, level, lo, hi, diff, at }. 2.10.0: one record per individual monster
                   -- (its server id), forgotten KEEP s after the check; nothing is kept by name or saved to a file
M.KEEP = 180
M.sid_of = function () return nil end         -- entity index -> server id (set by partyramaxi.lua)
M.now = function () return 0 end              -- the clock the checks are stamped with (set by partyramaxi.lua)
M.ranges = {}      -- monster name -> { lo, hi } of levels seen this session
M.tried = {}       -- entity index -> name, for auto-check (one /check per monster)

M.names = {}       -- monster name -> { diff } from the last check of any monster with that name
M.trail = {}       -- entity index -> { name, v, at } for the damage trail on the bar
M.bst = {}         -- entity index -> { name, disp, last, full, rdy, sh, cm }: smoothed fill, sheen / comet start times

function M.reset() M.checks, M.ranges, M.tried, M.trail, M.names, M.bst = {}, {}, {}, {}, {}, {} end
-- M.tried: 2.10.0 server id -> when it was last checked

local function sane_level(v) v = tonumber(v); if v ~= nil and v >= 1 and v <= 99 then return math.floor(v) end return nil end

-- Store what a check told us. level / lo / hi / diff may each be nil.
function M.set(idx, name, level, lo, hi, diff, now, eva, def)
    if idx == nil or idx == 0 or type(name) ~= 'string' or name == '' then return end
    local c = M.checks[idx]
    local sid = M.sid_of(idx)
    if c == nil or c.name ~= name or c.sid ~= sid then c = { name = name, sid = sid }; M.checks[idx] = c end
    level, lo, hi = sane_level(level), sane_level(lo), sane_level(hi)
    if level then c.level = level end
    if lo and hi then if lo > hi then lo, hi = hi, lo end; c.lo, c.hi = lo, hi end
    if diff and M.DIFF[diff] then
        c.diff = diff
    end
    if eva ~= nil then c.eva = eva end
    if def ~= nil then c.def = def end
    c.at = now or 0
end

-- 2.10.0: nothing is reused by monster name any more (monsters with one name differ in level), and data\checks.txt
-- is no longer read or written. known() stays for callers and always answers nil.
M.my_level = nil
M.dirty = false
function M.known() return nil end

function M.get(idx, name)
    local c = M.checks[idx]
    if c == nil or c.name ~= name then return nil end
    local sid = M.sid_of(idx)
    if sid ~= nil and c.sid ~= nil and sid ~= c.sid then M.checks[idx] = nil; return nil end      -- another monster now
    if M.now() - (c.at or 0) > M.KEEP then M.checks[idx] = nil; return nil end                    -- 3 minutes old
    return c
end

-- Reads a check reply out of a chat line about the monster `name`. Returns true when it found something.
function M.parse_text(line, name, idx, now)
    if type(line) ~= 'string' or type(name) ~= 'string' or name == '' then return false end
    line = line:gsub('[\30\31].', ''):gsub('\127.', '')
    local l = line:lower()
    if not l:find(name:lower(), 1, true) then return false end
    local diff
    for _, p in ipairs(PHRASES) do
        if l:find(p[1], 1, true) then diff = p[2]; break end
    end
    local level, lo, hi
    local a, b = l:match('lv%.?%s*(%d+)%s*[%-~]%s*(%d+)')
    if not a then a, b = l:match('level%s*(%d+)%s*[%-~to]+%s*(%d+)') end
    if a then lo, hi = a, b
    else level = l:match('lv%.?%s*(%d+)') or l:match('level%s*(%d+)') end
    if diff == nil and level == nil and lo == nil then return false end
    M.set(idx, name, level, lo, hi, diff, now)
    return true
end

-- The second line of a check reply: "It seems to have high evasion but low defense." (no monster name in it).
-- Applied to the monster whose check came in within the last few seconds.
local EVA_PHRASES = {
    { 'high evasion and defense', 1, 1 }, { 'high evasion but low defense', 1, -1 },
    { 'low evasion but high defense', -1, 1 }, { 'low evasion and defense', -1, -1 },
    { 'high evasion', 1, 0 }, { 'low evasion', -1, 0 }, { 'high defense', 0, 1 }, { 'low defense', 0, -1 },
}
function M.parse_defev(line, idx, name, now)
    if type(line) ~= 'string' or idx == nil or idx == 0 then return false end
    local c = M.checks[idx]
    if c == nil or c.name ~= name or (now or 0) - (c.at or 0) > 5 then return false end
    local l = line:gsub('[\30\31].', ''):gsub('\127.', ''):lower()
    if not l:find('seems to have', 1, true) then return false end
    for _, p in ipairs(EVA_PHRASES) do
        if l:find(p[1], 1, true) then M.set(idx, name, nil, nil, nil, nil, now, p[2], p[3]); return true end
    end
    return false
end

-- Classify a 0x0029 message. p1/p2 are the packet parameters. Returns level, diff or nil.
-- Check reply messages 170-178 say how the monster's evasion / defense compare: { evasion, defense }, +1 high, -1 low, 0 normal.
local DEFEV = {
    [170] = { 1, 1 }, [171] = { 1, 0 }, [172] = { 1, -1 },
    [173] = { 0, 1 }, [174] = { 0, 0 }, [175] = { 0, -1 },
    [176] = { -1, 1 }, [177] = { -1, 0 }, [178] = { -1, -1 },
}

-- Returns level, difficulty, evasion, defense (any of them may be nil).
function M.classify(msg, p1, p2)
    local de = DEFEV[msg]
    local eva, def
    if de then eva, def = de[1], de[2] end
    if p2 >= 0x40 and p2 <= 0x47 then return sane_level(p1), p2 - 0x3F, eva, def end
    if msg >= 0x40 and msg <= 0x47 then return sane_level(p1), msg - 0x3F, eva, def end
    if msg == 249 then return nil, M.GAUGE, nil, nil end         -- "... is impossible to gauge!" (no level is sent)
    if de then return nil, nil, eva, def end
    return nil
end

--------------------------------------------------------------------------- text for the panel
-- Strings are cached: this runs every frame and should not create garbage.
local RANGE_TXT, ONE_TXT = {}, {}
local function range_txt(lo, hi)
    local k = lo * 1000 + hi
    local t = RANGE_TXT[k]
    if t == nil then t = ('Lv %d-%d'):format(lo, hi); RANGE_TXT[k] = t end
    return t
end
local function one_txt(lv)
    local t = ONE_TXT[lv]
    if t == nil then t = ('Lv %d'):format(lv); ONE_TXT[lv] = t end
    return t
end

function M.level_text(c)
    if c and c.lo and c.hi and c.lo ~= c.hi then return range_txt(c.lo, c.hi) end
    if c and c.level then return one_txt(c.level) end
    if c and c.lo then return one_txt(c.lo) end
    return nil
end

function M.check_text(c, style)
    local d = c and c.diff and M.DIFF[c.diff]
    if not d then return nil, nil end
    local t
    if style == 'full' then t = d.full
    elseif style == 'both' then t = d.both
    else t = d.short end
    return t, d.color
end

--------------------------------------------------------------------------- drawing
M.GLOSS = { 'none', 'gradient', 'glossy', 'shine' }
M.GLOSS_LABELS = {
    none     = 'Flat',
    gradient = 'Gradient (light top, dark bottom)',
    glossy   = 'Glossy (glass top half + highlight)',
    shine    = 'Shine (thin highlight line)',
}

local P1, P2, P3 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local WHITE, BLACK = { 1, 1, 1, 1 }, { 0, 0, 0, 1 }
local COL = { 0, 0, 0, 1 }
local GX, GY = 0, 0               -- battle glide: the shared in-battle offset (already eased), added to every element
local OFF = nil                   -- 2.9.0: players' / NPCs' own offsets { name = { dx, dy }, bar, dist } (nil: the elements' own)
local function ox(k, el) local o = OFF and OFF[k] or el; return tonumber(o.dx) or 0 end
local function oy(k, el) local o = OFF and OFF[k] or el; return tonumber(o.dy) or 0 end
local AL = 1                      -- opacity of the element being drawn (battle fade)
local TOP, BOTTOM = 48, 192          -- ImDrawFlags_RoundCornersTop / Bottom

local function tsize(s)
    local a, b = imgui.CalcTextSize(s)
    if type(a) == 'table' or type(a) == 'userdata' then return tonumber(a.x or a[1]) or 0, tonumber(a.y or a[2]) or 0 end
    return tonumber(a) or 0, tonumber(b) or 0
end

local function rgba(c, a)        -- color table -> u32 with its alpha multiplied by a (no allocation)
    COL[1], COL[2], COL[3], COL[4] = c[1], c[2], c[3], (c[4] or 1) * a * AL
    return Draw.u32(COL)
end
local function white(a) COL[1], COL[2], COL[3], COL[4] = 1, 1, 1, a * AL; return Draw.u32(COL) end
local function black(a) COL[1], COL[2], COL[3], COL[4] = 0, 0, 0, a * AL; return Draw.u32(COL) end

-- Outline offsets per thickness (1-3 px): every point of the ring at that distance, so thicker stays round.
local OUTS = {}
for t = 1, 3 do
    local o = {}
    for dy = -t, t do
        for dx = -t, t do
            local d = math.max(math.abs(dx), math.abs(dy))
            if d >= 1 and (d == t or (t > 1 and d == t - 1 and (dx == 0 or dy == 0))) then o[#o + 1] = dx; o[#o + 1] = dy end
        end
    end
    OUTS[t] = o
end
-- 2 px: 12 copies instead of 20 (the ring's sides and corners at 2 px plus the diagonals at 1 px). Compared with the
-- full ring on rendered text at 12-24 px it looks the same, and it is the outline most texts use (half of all draw calls).
OUTS[2] = { 2, 0, -2, 0, 0, 2, 0, -2, 2, 2, -2, 2, 2, -2, -2, -2, 1, 1, -1, 1, 1, -1, -1, -1 }
local OCOL = { 0, 0, 0, 0.95 }
local function ocolor(c) local a = c and (c[4] or 1) or 0.95; COL[1], COL[2], COL[3], COL[4] = c and c[1] or 0, c and c[2] or 0, c and c[3] or 0, a * AL; return Draw.u32(COL) end
local function put(dl, s, x, y, col)
    P1[1], P1[2] = x, y
    dl:AddText(P1, col, s)
end

-- One piece of text, centred vertically on ay. st = { shadow, outline, bold } (u32 / booleans).
local function text_at(dl, s, ax, ay, align, col, st, w, h)
    if w == nil then w, h = tsize(s) end
    local x = ax
    if align == 'center' then x = ax - w / 2 elseif align == 'right' then x = ax - w end
    local y = ay - h / 2
    if st.outline then
        local o = ocolor(st.oc or OCOL)
        local OUT = OUTS[math.max(1, math.min(3, math.floor(tonumber(st.ow) or 1)))]
        for i = 1, #OUT, 2 do put(dl, s, x + OUT[i], y + OUT[i + 1], o) end
    end
    if st.shadow ~= 0 then
        local sh = black(st.shadow)
        put(dl, s, x + 1, y + 1, sh)
        if st.bold then put(dl, s, x + 2, y + 1, sh) end
    end
    put(dl, s, x, y, col)
    if st.bold then put(dl, s, x + 1, y, col) end
    return x, y, x + w, y + h
end

local FILLC = { 0, 0, 0, 1 }
local function bar_color(hp)
    local p = hp / 100
    if p >= 0.5 then FILLC[1], FILLC[2], FILLC[3] = 1 - (p - 0.5) * 2 * 0.85, 0.85, 0.2
    else FILLC[1], FILLC[2], FILLC[3] = 0.9, p * 2 * 0.85, 0.2 end
    return FILLC
end

local flags_ok = nil              -- does AddRectFilled take the corner flags? learned on first use
local function rect(dl, x0, y0, x1, y1, col, r, flags)
    P1[1], P1[2], P2[1], P2[2] = x0, y0, x1, y1
    if flags and r > 0 and flags_ok ~= false then
        if flags_ok then dl:AddRectFilled(P1, P2, col, r, flags); return end
        flags_ok = pcall(dl.AddRectFilled, dl, P1, P2, col, r, flags)
        if flags_ok then return end
    end
    dl:AddRectFilled(P1, P2, col, r)
end

-- Gloss over the part of the bar from x0 to x1 (strength s, 0-1).
local function gloss(dl, kind, x0, y0, x1, y1, r, s, mult)
    if x1 - x0 < 1 or kind == 'none' then return end
    local h = y1 - y0
    local mid = y0 + h * 0.5
    local rr = math.min(r, h / 2, (x1 - x0) / 2)
    if kind == 'gradient' then
        rect(dl, x0, y0, x1, mid, white(0.30 * s * mult), rr, TOP)
        rect(dl, x0, mid, x1, y1, black(0.30 * s * mult), rr, BOTTOM)
    elseif kind == 'glossy' then
        rect(dl, x0 + 1, y0 + 1, x1 - 1, mid, white(0.42 * s * mult), math.max(0, rr - 1), TOP)
        rect(dl, x0 + 1, mid, x1 - 1, y1 - 1, black(0.12 * s * mult), math.max(0, rr - 1), BOTTOM)
        rect(dl, x0 + rr, y0 + 1, x1 - rr, y0 + 2, white(0.55 * s * mult), 0)
    elseif kind == 'shine' then
        rect(dl, x0 + rr, y0 + 1, x1 - rr, y0 + 2.5, white(0.65 * s * mult), 0)
    end
end

-- Remembers the last higher health for the damage trail: holds for a moment after a hit, then drains.
local function trail_value(d, hp)
    if d.idx == nil or d.now == nil then return hp end
    local now = d.now
    local t = M.trail[d.idx]
    if t == nil or t.name ~= d.name then t = { name = d.name, v = hp, hp = hp, hold = 0, last = now }; M.trail[d.idx] = t end
    if hp > t.v then t.v = hp end
    if hp < t.hp then t.hold = now + 0.4 end
    t.hp = hp
    if t.v > hp and now >= t.hold then
        t.v = math.max(hp, t.v - 55 * math.min(0.1, math.max(0, now - t.last)))
    end
    t.last = now
    return t.v
end

-- The health bar is the party list's bar (pxilist.bar_ext): the same finish, rounded left end / flat growing edge,
-- sheen and comet at 100%, outline and border. This module keeps its smoothed fill and the sheen / comet start times.
local AD = { dx = 0, dy = 0, auto_len = true }
local ABAR = nil
local function bar_state(d, hp)
    local id = d.idx or 0
    local st = M.bst[id]
    local f = hp / 100
    local now = d.now or 0
    if st == nil or st.name ~= d.name then
        st = { name = d.name, disp = f, last = now, full = f >= 0.995, rdy = f >= 0.995 }
        M.bst[id] = st
    end
    local dt = math.min(0.1, math.max(0, now - st.last))
    st.last = now
    local diff = f - st.disp
    if math.abs(diff) < 0.002 then st.disp = f else st.disp = st.disp + diff * math.min(1, dt * (diff > 0 and 7 or 22)) end
    local full = st.disp >= 0.995
    if st.full == false and full then st.sh = now end
    st.full = full
    if st.rdy == false and full then st.cm = now end
    st.rdy = full
    return st
end

local function draw_bar(dl, b, x, y, d)
    local w, h = tonumber(b.width) or 100, tonumber(b.height) or 9
    local x0 = x + ox('bar', b) + GX - w / 2
    local y0 = y + oy('bar', b) + GY - h / 2
    local x1, y1 = x0 + w, y0 + h
    local hp = math.max(0, math.min(100, tonumber(d.hp) or 0))
    if ABAR == nil then ABAR = require('pxilist') end
    local st = bar_state(d, hp)
    AD.back, AD.rounding, AD.gloss, AD.gloss_strength = b.back, b.rounding, b.gloss, b.gloss_strength
    AD.border_on, AD.border, AD.border_w = b.border == true, b.border_color, b.border_width
    AD.outline_w, AD.outline = b.outline_width, b.outline_color
    AD.trail, AD.trail_color = b.trail == true, b.trail_color
    AD.sheen, AD.comet, AD.comet_color, AD.comet_speed = b.sheen, b.comet, b.comet_color, b.comet_speed
    local tv = nil
    if b.trail then tv = trail_value(d, hp) / 100 end
    ABAR.bar_ext(dl, AD, x0, y0, w, h, st.disp, d.tint or (b.by_hp and bar_color(hp)) or b.fill, tv, AL, d.now or 0, st)
    if b.ticks then
        local tl = math.min(tonumber(b.tick_len) or 5, h - 1)
        if tl > 0 then
            for k = 1, 3 do
                local tx = x0 + math.floor(w * k / 4)
                rect(dl, tx, y0 + 1, tx + 1, y0 + 1 + tl, white(0.5), 0)
            end
        end
    end
    return x0, y0, x1, y1
end

--[[
* x, y: the pointer position on screen.
* d = { name, hp (0-100), level, check, check_color (color table), idx, now }; level / check are strings
* or nil (unknown); idx / now are only needed for the damage trail.
* push(scale) returns true when it pushed a font (the caller's PopFont is done here).
--]]
local PCT = { scale = 0.8 }
local PCT_TXT = {}
local ST = { shadow = 0, outline = false, bold = false, ow = 1, oc = nil }

local function sized(push, base, el)
    if push then return push(base * (tonumber(el.scale) or 1)) end
    return false
end

M.text_at, M.ST, M.text_size = text_at, ST, tsize

-- 2.13.4: a player's name icons in a row centred over the name (bottom at by): the linkshell pearl, then short
-- labels on colored pills (LFP, AWAY, ANON, BAZ...). d.badges / badge_n / badge_px: see PartyramaXI.name_badges.
local BADGE_TXT = { 1, 1, 1, 1 }
function M.draw_badges(dl, cx, by, d, push)
    local hpx = math.max(8, tonumber(d.badge_px) or 16)
    local fs = tonumber(imgui.GetFontSize and imgui.GetFontSize()) or 14
    local pushed = push and push(hpx * 0.62 / math.max(1, fs)) or false
    local gap, pad, total = math.max(2, hpx * 0.2), hpx * 0.3, 0
    local W = d.badge_w
    if W == nil then W = {}; d.badge_w = W end
    for i = 1, d.badge_n do
        local b = d.badges[i]
        W[i] = b.t and (tsize(b.t) + 2 * pad) or hpx
        total = total + W[i] + (i > 1 and gap or 0)
    end
    local x, y0, y1 = cx - total / 2, by - hpx, by
    for i = 1, d.badge_n do
        local b = d.badges[i]
        local w = W[i]
        if b.t == nil then                                   -- linkshell pearl: its color, a rim and a highlight
            local r = hpx / 2
            dl:AddCircleFilled({ x + r, y0 + r }, r, rgba(b.c, 1), 20)
            dl:AddCircle({ x + r, y0 + r }, r, black(0.7), 20, 1.2)
            dl:AddCircleFilled({ x + r * 0.7, y0 + r * 0.65 }, r * 0.28, rgba(BADGE_TXT, 0.75), 10)
        else
            dl:AddRectFilled({ x, y0 }, { x + w, y1 }, rgba(b.c, 0.9), hpx * 0.3, 0)
            dl:AddRect({ x, y0 }, { x + w, y1 }, black(0.6), hpx * 0.3, 0, 1)
            local tw, th = tsize(b.t)
            put(dl, b.t, x + (w - tw) / 2 + 1, y0 + (hpx - th) / 2 + 1, black(0.6))
            put(dl, b.t, x + (w - tw) / 2, y0 + (hpx - th) / 2, rgba(BADGE_TXT, 1))
        end
        x = x + w + gap
    end
    Draw.hl_rect('info', 'name', cx - total / 2, y0, cx + total / 2, y1)
    if pushed then Fonts.pop() end
end

--[[
* Evasion / defense of the monster: "Eva" and "Def" followed by an arrow (red up = high, green down = low) or
* the word High / Low. Normal is left out unless asked for. Arrows are drawn as triangles so no special font is needed.
--]]
local DV = { { 'Eva', 0 }, { 'Def', 0 } }
local WORD = { [1] = 'High', [-1] = 'Low', [0] = 'Normal' }
local function tri(dl, cx, cy, h, up, col)
    local w = h * 0.5
    if up then
        P1[1], P1[2], P2[1], P2[2], P3[1], P3[2] = cx - w, cy + h / 2, cx + w, cy + h / 2, cx, cy - h / 2
    else
        P1[1], P1[2], P2[1], P2[2], P3[1], P3[2] = cx - w, cy - h / 2, cx + w, cy - h / 2, cx, cy + h / 2
    end
    dl:AddTriangleFilled(P1, P2, P3, col)
end

local function draw_defev(dl, dv, cfg, x, y, d, push, base)
    DV[1][2], DV[2][2] = d.eva, d.def
    local p = sized(push, base, dv)
    local _, th = tsize('Eg')
    local gap, pair_gap = 3, 10
    local arrows = dv.arrows ~= false
    -- first pass: width
    local total, n = 0, 0
    for i = 1, 2 do
        local v = DV[i][2]
        if v ~= nil and (v ~= 0 or dv.show_normal) then
            local lw = tsize(DV[i][1])
            local vw = arrows and (th * 0.5 + 2) or tsize(WORD[v])
            total = total + lw + gap + vw + (n > 0 and pair_gap or 0)
            n = n + 1
        end
    end
    if n > 0 then
        local cx = x + (tonumber(dv.dx) or 0) + GX - total / 2
        local cy = y + (tonumber(dv.dy) or 0) + GY
        Draw.hl_rect('info', 'defev', cx, cy - th / 2, cx + total, cy + th / 2)
        local first = true
        for i = 1, 2 do
            local v = DV[i][2]
            if v ~= nil and (v ~= 0 or dv.show_normal) then
                if not first then cx = cx + pair_gap end
                first = false
                local lw = tsize(DV[i][1])
                text_at(dl, DV[i][1], cx, cy, 'left', rgba(dv.color_label, 1), ST)
                cx = cx + lw + gap
                local col = v > 0 and dv.color_high or (v < 0 and dv.color_low or dv.color_label)
                if arrows then
                    local aw = th * 0.5 + 2
                    if v ~= 0 then
                        if cfg.shadow then tri(dl, cx + aw / 2 + 1, cy + 1, th * 0.7, v > 0, black(0.85)) end
                        tri(dl, cx + aw / 2, cy, th * 0.7, v > 0, rgba(col, 1))
                    else
                        rect(dl, cx, cy - 0.5, cx + aw - 2, cy + 1, rgba(col, 1), 0)
                    end
                    cx = cx + aw
                else
                    local word = WORD[v]
                    text_at(dl, word, cx, cy, 'left', rgba(col, 1), ST)
                    cx = cx + tsize(word)
                end
            end
        end
    end
    if p then Fonts.pop() end
end

function M.set_alpha(a) AL = a end

-- Easing curves for the battle glide (0..1 in, 0..1 out). Every curve starts slowly (ease in); they differ in how
-- they arrive. 'back', 'bounce' and 'spring' pass the target or rebound at the end. The way back to the normal
-- position always uses 'smooth' (see hpp.draw_info).
local function smooth(t) return t * t * (3 - 2 * t) end
local function bounce_out(t)
    if t < 1 / 2.75 then return 7.5625 * t * t
    elseif t < 2 / 2.75 then t = t - 1.5 / 2.75; return 7.5625 * t * t + 0.75
    elseif t < 2.5 / 2.75 then t = t - 2.25 / 2.75; return 7.5625 * t * t + 0.9375 end
    t = t - 2.625 / 2.75; return 7.5625 * t * t + 0.984375
end
local function back_out(t) local u = t - 1; return 1 + 2.70158 * u * u * u + 1.70158 * u * u end
local function spring_out(t)
    if t <= 0 then return 0 elseif t >= 1 then return 1 end
    return 2 ^ (-10 * t) * math.sin((10 * t - 0.75) * (2 * math.pi / 3)) + 1
end
M.EASE = {
    smooth   = smooth,
    smoother = function (t) return t * t * t * (t * (6 * t - 15) + 10) end,
    ease_in  = function (t) return t * t * t end,
    back     = function (t) return back_out(t * t) end,
    bounce   = function (t) return bounce_out(t * t) end,
    spring   = function (t) return spring_out(t * t) end,
}
M.EASE_LIST = { 'smooth', 'smoother', 'ease_in', 'back', 'bounce', 'spring' }
M.EASE_LABELS = { smooth = 'Smooth (ease in and out)', smoother = 'Softer (gentle in and out)', ease_in = 'Ease in (speeds up)',
    back = 'Ease in, overshoot', bounce = 'Ease in, bounce', spring = 'Ease in, spring' }

-- Elements are drawn back to front by their layer number (z): lower = behind. Ties keep the order below.
local KEYS = { 'bar', 'name', 'level', 'check', 'defev', 'fx', 'dist', 'weak', 'mob' }
M.LAYER_KEYS = KEYS
M.LAYER_DEF = { bar = 1, name = 2, level = 3, check = 4, defev = 5, fx = 6, dist = 7, weak = 8, mob = 9 }
M.LAYER_LABEL = { bar = 'Health bar', name = 'Name', level = 'Level', check = 'Check', defev = 'Evasion / Defense', fx = 'Effect icons', dist = 'Distance', weak = 'Weaknesses', mob = 'Monster info' }
local ORD, ORZ = { 'bar', 'name', 'level', 'check', 'defev', 'fx', 'dist', 'weak', 'mob' }, { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local NKEYS = #KEYS

-- Distance text, cached per tenth of a yalm and format (no string.format per frame).
M.DIST_FORMATS = { 'short', 'long', 'plain', 'whole' }
M.DIST_LABELS = { short = '12.3y', long = '12.3 yalms', plain = '12.3', whole = '12y' }
local DIST_TXT = { short = {}, long = {}, plain = {}, whole = {} }
local DIST_FMT = { short = '%.1fy', long = '%.1f yalms', plain = '%.1f', whole = '%dy' }
local function dist_text(fmt, d)
    local cache = DIST_TXT[fmt] or DIST_TXT.short
    local k = math.floor(d * 10 + 0.5)
    if k > 9999 then k = 9999 end
    local t = cache[k]
    if t == nil then
        if fmt == 'whole' then t = ('%dy'):format(math.floor(k / 10 + 0.5)) else t = (DIST_FMT[fmt] or DIST_FMT.short):format(k / 10) end
        cache[k] = t
    end
    return t
end
M.dist_text = dist_text

function M.draw(dl, cfg, x, y, d, push)
    Fonts.update(cfg)
    GX, GY = d.gx or 0, d.gy or 0
    OFF = d.off
    local base = tonumber(cfg.text_size) or 1
    ST.shadow = cfg.shadow and 0.85 or 0
    ST.outline = cfg.outline == true
    ST.ow, ST.oc = tonumber(cfg.outline_w) or 1, cfg.outline_color
    ST.bold = Fonts.faux_bold == true
    local n, b, lv, ck = cfg.name, cfg.bar, cfg.level, cfg.check
    local dv = cfg.defev
    local ds = cfg.dist

    -- order by z (insertion sort over nine entries, no garbage)
    for i = 1, NKEYS do
        local k = KEYS[i]
        local el = (k == 'bar' and b) or (k == 'name' and n) or (k == 'level' and lv) or (k == 'check' and ck) or (k == 'defev' and dv) or (k == 'dist' and ds) or (k == 'weak' and cfg.weak) or (k == 'mob' and cfg.mob) or cfg.fx
        local z = el and tonumber(el.z) or M.LAYER_DEF[k]
        local j = i - 1
        while j >= 1 and ORZ[j] > z do ORZ[j + 1], ORD[j + 1] = ORZ[j], ORD[j]; j = j - 1 end
        ORZ[j + 1], ORD[j + 1] = z, k
    end
    for i = 1, NKEYS do
        local k = ORD[i]
        if k == 'bar' then
            AL = d.a_bar or 1
            if b.show and AL > 0.01 and not d.nobar then          -- NPCs / objects (and players, if switched off) have no bar
                local bx0, by0, bx1, by1 = draw_bar(dl, b, x, y, d)
                Draw.hl_rect('info', 'bar', bx0, by0, bx1, by1)
                if b.percent and not d.nopct then
                    PCT.scale = tonumber(b.percent_scale) or 0.8
                    local p = sized(push, base, PCT)
                    local pct = math.floor(math.max(0, math.min(100, tonumber(d.hp) or 0)) + 0.5)
                    local ptxt = PCT_TXT[pct]
                    if ptxt == nil then ptxt = ('%d%%'):format(pct); PCT_TXT[pct] = ptxt end
                    local po = OFF and OFF.pct      -- 2.9.1: players' / NPCs' own number position
                    text_at(dl, ptxt, (bx0 + bx1) / 2 + (tonumber(po and po.dx or b.pct_dx) or 0), (by0 + by1) / 2 + (tonumber(po and po.dy or b.pct_dy) or 0), 'center', rgba(WHITE, 1), ST)
                    if p then Fonts.pop() end
                end
            end
        elseif k == 'name' then
            AL = d.a_name or 1
            if n.show and d.name and not d.noname and AL > 0.01 then
                local p = sized(push, base, n)
                local tx0, ty0, tx1, ty1 = text_at(dl, d.name, x + ox('name', n) + GX, y + oy('name', n) + GY, 'center', rgba(d.tint or n.color, 1), ST)
                Draw.hl_rect('info', 'name', tx0, ty0, tx1, ty1)
                if p then Fonts.pop() end
                if (d.badge_n or 0) > 0 then M.draw_badges(dl, (tx0 + tx1) / 2, ty0 - 3, d, push) end
            end
        elseif k == 'level' then
            AL = d.a_level or 1
            if lv.show and d.mob ~= false and AL > 0.01 then
                local t = d.level or ((lv.unknown and d.mob ~= false) and 'Lv ?' or nil)
                if t then
                    local p = sized(push, base, lv)
                    local col = rgba(lv.color, d.level and 1 or 0.55)
                    local tx0, ty0, tx1, ty1 = text_at(dl, t, x + (tonumber(lv.dx) or 0) + GX, y + (tonumber(lv.dy) or 0) + GY, 'right', col, ST)
                    Draw.hl_rect('info', 'level', tx0, ty0, tx1, ty1)
                    if p then Fonts.pop() end
                end
            end
        elseif k == 'check' then
            AL = d.a_check or 1
            if ck.show and d.mob ~= false and AL > 0.01 then
                local t = d.check or ((ck.unknown and d.mob ~= false) and '?' or nil)
                if t then
                    local p = sized(push, base, ck)
                    local col
                    if d.check then col = rgba(ck.by_diff and d.check_color or ck.color, d.inferred and 0.7 or 1)
                    else col = rgba(ck.color, 0.55) end
                    local tx0, ty0, tx1, ty1 = text_at(dl, t, x + (tonumber(ck.dx) or 0) + GX, y + (tonumber(ck.dy) or 0) + GY, 'center', col, ST)
                    Draw.hl_rect('info', 'check', tx0, ty0, tx1, ty1)
                    if p then Fonts.pop() end
                end
            end
        elseif k == 'defev' then
            AL = d.a_defev or 1
            if dv and dv.show and AL > 0.01 and (d.eva ~= nil or d.def ~= nil) then
                draw_defev(dl, dv, cfg, x, y, d, push, base)
            end
        elseif k == 'dist' then
            AL = d.a_dist or 1
            if ds and ds.show and AL > 0.01 and d.dist ~= nil and not d.nodist then
                local p = sized(push, base, ds)
                local col = (ds.far and d.dist > (tonumber(ds.far_at) or 21)) and ds.far_color or ds.color
                local tx0, ty0, tx1, ty1 = text_at(dl, dist_text(ds.format, d.dist), x + ox('dist', ds) + GX, y + oy('dist', ds) + GY, 'left', rgba(col, 1), ST)
                Draw.hl_rect('info', 'dist', tx0, ty0, tx1, ty1)
                if p then Fonts.pop() end
            end
        elseif k == 'fx' and d.fx_draw ~= nil then
            AL = 1
            d.fx_draw(dl, d)
        elseif k == 'weak' and d.weak_draw ~= nil then
            AL = 1
            d.weak_draw(dl, d)
        elseif k == 'mob' and d.mob_draw ~= nil then
            AL = 1
            d.mob_draw(dl, d)
        end
    end
    AL = 1
    OFF = nil
end

return M
