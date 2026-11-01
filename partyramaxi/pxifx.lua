--[[
* PartyramaXI - status effects on the target (icons with a countdown).
*
* The game does not tell the client what effects an enemy has. This module learns them the way the
* Windower "Debuffed" addon by Xathe does (same message ids; the code here is written from scratch): from the action packets (0x0028) of spells that landed, and from the
* "effect wears off" / "defeated" messages (0x0029). The spell table (which status a spell applies, its
* base duration, which spells it replaces) is in pxifxdata.lua, generated from the Windower Resources
* project. What this can see: effects from spells cast by you and by anyone else you can see, and (2.7.3) any
* status the game names in a message: blue magic, abilities and weapon skills that report "<target> is
* <status>", and "Additional effect: <status>" (melee, ranged, weapon skills, physical blue magic). What it
* cannot see: effects the game never reports (most weapon skill debuffs such as Armor Break), and anything
* applied before you zoned in or before the addon loaded. Durations are the base values of the spell table, so
* they are estimates; a status from anything else has no known duration (no countdown) until it wears off.
*
* Icons: <status id>.png (also 3 / 5 / 8 digit names, e.g. 00134.png) in the chosen icon pack
* (addons\partyramaxi\icons\packs\<Pack>\), then the fallback pack, then the loose files in icons\status\.
--]]
local imgui = require('imgui')
local Draw  = require('pxidraw')
local Data  = require('pxifxdata')
local Lsb   = require('pxifxlsb')     -- 2.7.4: LandSandBoat's spell -> status table (fallback)
local Info  = require('pxiinfo')
local Fonts = require('pxifonts')

local M = {}

M.fx = {}            -- target server id -> { [status id] = { status, spell, actor, t0, dur, exp } }
M.me = 0             -- the player's server id (for "only mine")
M.SORTS = { 'soonest', 'oldest', 'newest' }
M.SORT_LABELS = { soonest = 'Ending soonest first', oldest = 'Oldest first', newest = 'Newest first' }
M.RINGS = { 'none', 'ring', 'bar', 'top' }
M.RING_LABELS = {
    none  = 'None',
    top   = 'Shade: the icon darkens from the top down as it runs out',
    ring  = 'Ring: a ring around the icon drains counter-clockwise from 12 o\'clock',
    bar   = 'Bar: a thin bar under the icon shrinks',
}
M.SHAPES = { 'circle', 'square' }
M.SHAPE_LABELS = { circle = 'Circle (best for round icons)', square = 'Square (follows the icon edge)' }
M.TEXTS = { 'below', 'inside', 'off' }
M.TEXT_LABELS = { below = 'Under the icon', inside = 'On the icon', off = 'No number' }
M.ALIGNS = { 'center', 'left', 'right' }
M.ALIGN_LABELS = { center = 'Centred on the point', left = 'Starts at the point', right = 'Ends at the point' }

local DMG   = { [2] = true, [252] = true, [264] = true, [185] = true }   -- 264: an area move's other targets; 185: a monster move's damage                               -- spell hit and applied its effect
local GAIN  = { [230] = true, [236] = true, [237] = true, [266] = true, [268] = true, [271] = true } -- "gains / receives the effect of" (param = status); 230 = most buffs cast on a player
-- 2.7.3: ability / weapon skill / blue magic messages "<target> is <status>" / "receives the effect of <status>" (param = status)
local STATUS_MSG = { [127] = true, [141] = true, [186] = true, [194] = true, [242] = true, [243] = true, [277] = true, [278] = true }
-- additional effect messages whose param is a status ("Additional effect: <status>")
M.ADD_STATUS = { [160] = true, [164] = true, [166] = true }
local WEAR  = { [64] = true, [204] = true, [206] = true, [350] = true, [531] = true }
local DEAD  = { [6] = true, [20] = true, [113] = true, [406] = true, [605] = true, [646] = true }
local GRACE, UNKNOWN_MAX, MAX_TARGETS = 3, 900, 64     -- GRACE: seconds an ended effect stays on screen (dimmed) before it disappears

function M.reset() M.fx = {} end

local function has(list, v)
    for i = 1, #list do if list[i] == v then return true end end
    return false
end

local function add(target, status, spell, actor, now, scale, dur_known)
    local list = M.fx[target]
    if list == nil then list = {}; M.fx[target] = list end
    local sd = Data.spells[spell]
    for st, e in pairs(list) do
        if (e.exp > 0 and now > e.exp + GRACE) or (e.gone ~= nil and now - e.gone > GRACE) then
            list[st] = nil
        elseif e.gone ~= nil then
            -- an ended effect lingers dimmed; it neither blocks nor is replaced by a new one
        else
            local old = Data.spells[e.spell]
            if old and sd and has(old[3], spell) then return end     -- a stronger version is still active
            if sd and has(sd[3], e.spell) then list[st] = nil end    -- this one replaces a weaker version
        end
    end
    local dur = dur_known or (sd and sd[2]) or 0
    if dur > 0 then dur = dur * scale end
    list[status] = { status = status, spell = spell, actor = actor, t0 = now, dur = dur, exp = dur > 0 and (now + dur) or 0 }
end

-- One action packet target. message / param are the first action's.
-- Where a spell's status and duration come from (2.7.4), first found wins:
--   1. the Windower table (pxifxdata.lua): one status per spell, base duration, which spells it replaces
--   2. LandSandBoat's scripts (pxifxlsb.lua): every status the spell can apply (blue magic often several), base duration
--   3. the message itself: "<target> is <status>" names the status (no duration)
-- A damage message ("takes N damage") names no status, so 1 and 2 give it; an effect a spell adds on top of its damage
-- can still be resisted on its own, which the game does not report: such an icon may show for an effect that missed.
local function lsb_dur(spell, status)
    local l = Lsb.lsb[spell]
    if l == nil then return nil end
    for i = 1, #l do if l[i][1] == status then return l[i][2] end end
    return nil
end
local function spell_dur(spell, status)
    local sd = Data.spells[spell]
    if sd ~= nil and sd[1] == status and (sd[2] or 0) > 0 then return sd[2] end
    local d = lsb_dur(spell, status)
    if d ~= nil and d > 0 then return d end
    return 0
end
M.spell_dur = spell_dur

-- 2.7.5: monster moves (mob skill id): every status LandSandBoat's script for the move applies, and its duration
local MISS = { [0] = true, [188] = true, [189] = true, [282] = true, [283] = true, [284] = true, [85] = true, [31] = true }
function M.on_mob_move(actor, skill, target, message, param, now, scale)
    if MISS[message] then return end
    local l = Lsb.mob[skill]
    if (GAIN[message] or STATUS_MSG[message]) and Data.names[tonumber(param) or -1] ~= nil then
        local st, d = tonumber(param), 0
        if l ~= nil then for i = 1, #l do if l[i][1] == st then d = l[i][2] end end end
        add(target, st, -1, actor, now, scale or 1, d)
        return
    end
    -- a damage message, or a move used on itself (self buffs: whatever message the server picked for it)
    if l ~= nil and (DMG[message] or target == actor) then
        for i = 1, #l do add(target, l[i][1], -1, actor, now, scale or 1, l[i][2]) end
    end
end

function M.on_action(actor, spell, target, message, param, now, scale)
    if DMG[message] then
        local sd = Data.spells[spell]
        if sd ~= nil and sd[1] ~= nil then add(target, sd[1], spell, actor, now, scale or 1, spell_dur(spell, sd[1])) end
        local l = Lsb.lsb[spell]
        if l ~= nil then
            for i = 1, #l do
                if sd == nil or l[i][1] ~= sd[1] then add(target, l[i][1], spell, actor, now, scale or 1, spell_dur(spell, l[i][1])) end
            end
        end
    elseif GAIN[message] or STATUS_MSG[message] then
        local st = tonumber(param) or -1
        if spell ~= nil and spell >= 0 and (spell_dur(spell, st) > 0 or lsb_dur(spell, st) ~= nil) then
            if Data.names[st] ~= nil then add(target, st, spell, actor, now, scale or 1, spell_dur(spell, st)) end
        else
            M.on_status(actor, target, st, now, scale, nil)
        end
    end
end

-- 2.7.3: a status from anything else the game reports: an ability's or weapon skill's own message, or an
-- "Additional effect" (melee, ranged, weapon skills, physical blue magic). Unknown duration unless spell is given.
function M.on_status(actor, target, status, now, scale, spell)
    status = tonumber(status) or -1
    if status <= 0 or status >= 1024 or Data.names[status] == nil then return end
    if spell ~= nil then add(target, status, spell, actor, now, scale or 1, spell_dur(spell, status)); return end
    local list = M.fx[target]
    local e = list and list[status]
    if e ~= nil and e.gone == nil and e.dur > 0 then             -- re-applied: keep the known duration, restart it
        e.t0, e.exp, e.actor, e.faded = now, now + e.dur, actor, nil
        return
    end
    add(target, status, -1, actor, now, 1)
end

-- Packet 0x0029: wears off / defeated. param is the status id for wear-off.
function M.on_message(target, param, message)
    if DEAD[message] then M.fx[target] = nil
    elseif WEAR[message] then
        local list = M.fx[target]
        local e = list and list[param]
        if e and e.gone == nil then e.gone = M.now or 0 end
    end
end

local last_sweep = 0
function M.tick(now)
    M.now = now
    if now - last_sweep < 10 then return end
    last_sweep = now
    local n = 0
    for t, list in pairs(M.fx) do
        local keep = false
        for st, e in pairs(list) do
            if (e.exp > 0 and now > e.exp + GRACE) or (e.gone ~= nil and now - e.gone > GRACE) or (e.exp == 0 and now - e.t0 > UNKNOWN_MAX) then list[st] = nil else keep = true end
        end
        if keep then n = n + 1 else M.fx[t] = nil end
    end
    if n > MAX_TARGETS then M.fx = {} end
end

local function by_soonest(a, b)
    local ea, eb = a.exp > 0 and a.exp or 1e12, b.exp > 0 and b.exp or 1e12
    if ea ~= eb then return ea < eb end
    return a.status < b.status
end
local function by_oldest(a, b) if a.t0 ~= b.t0 then return a.t0 < b.t0 end return a.status < b.status end
local function by_newest(a, b) if a.t0 ~= b.t0 then return a.t0 > b.t0 end return a.status < b.status end
local SORTFN = { soonest = by_soonest, oldest = by_oldest, newest = by_newest }

-- Fills out[1..n] with the effects to show on target, and returns n.
function M.active(target, now, cfg, out)
    local n = 0
    local list = M.fx[target]
    if list then
        for st, e in pairs(list) do
            if (e.exp > 0 and now > e.exp + GRACE) or (e.gone ~= nil and now - e.gone > GRACE) or (e.exp == 0 and now - e.t0 > UNKNOWN_MAX) then
                list[st] = nil
            elseif e.faded then                -- worn off and faded out: no longer drawn, the rest close the gap
            elseif (not cfg.mine_only or e.actor == M.me) and (e.exp > 0 or cfg.show_unknown) then
                n = n + 1; out[n] = e
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    if n > 1 then table.sort(out, SORTFN[cfg.sort] or by_soonest) end
    return n
end

--------------------------------------------------------------------------- icons
local resolved = {}      -- status id -> { png, file } | false
local sources = {}     -- Png objects in priority order: pack 1, pack 2, pack 3, the effects folder itself
function M.set_sources(list) sources = list or {}; resolved = {} end
function M.forget() resolved = {} end

local function candidates(id)
    return { ('%d.png'):format(id), ('%03d.png'):format(id), ('%05d.png'):format(id), ('%08d.png'):format(id) }
end

local function find_icon(id)
    local r = resolved[id]
    if r ~= nil then return r end
    r = false
    for _, png in ipairs(sources) do
        for _, f in ipairs(candidates(id)) do
            if png:has(f) then r = { png = png, file = f }; break end
        end
        if r then break end
    end
    resolved[id] = r
    return r
end

-- Placeholder look: a color from the status id and a short label from its name.
local look = {}
local function hsv(h, s, v)
    local i = math.floor(h * 6); local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v end
    return v, p, q
end
local function placeholder(id)
    local l = look[id]
    if l then return l end
    local name = Data.names[id] or tostring(id)
    local label
    local words = {}
    for w in name:gmatch('%a+') do words[#words + 1] = w end
    if #words >= 2 then
        label = ''
        for i = 1, math.min(3, #words) do label = label .. words[i]:sub(1, 1) end
    else label = name:sub(1, 3) end
    local r, g, b = hsv(((id * 47) % 360) / 360, 0.55, 0.6)
    l = { col = { r, g, b, 0.95 }, label = label:sub(1, 1):upper() .. label:sub(2), name = name }
    look[id] = l
    return l
end
function M.name_of(id) return placeholder(id).name end
M.find_icon, M.placeholder = find_icon, placeholder      -- used by the party list's status effect icons

--------------------------------------------------------------------------- drawing helpers
local P1, P2, P3 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local Q1, Q2, Q3, Q4 = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
local UV1, UV2, UV3, UV4 = { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }
local COL = { 0, 0, 0, 1 }
local BLACKB = { 0, 0, 0, 0.85 }
local WHITE = { 1, 1, 1, 1 }
local FA = 1       -- opacity of the whole effects row (battle fade)
local function u32(c, a) COL[1], COL[2], COL[3], COL[4] = c[1], c[2], c[3], (c[4] or 1) * (a or 1) * FA; return Draw.u32(COL) end
local function rectf(dl, x0, y0, x1, y1, col, r)
    P1[1], P1[2], P2[1], P2[2] = x0, y0, x1, y1
    dl:AddRectFilled(P1, P2, col, r or 0)
end

-- Point at fraction t (0..1) of the way round a square, clockwise from the top centre.
local function perim(t, x0, y0, s)
    local h, d = s / 2, t * s * 4
    if d <= h then return x0 + h + d, y0 end
    if d <= h + s then return x0 + s, y0 + (d - h) end
    if d <= h + 2 * s then return x0 + s - (d - h - s), y0 + s end
    if d <= h + 3 * s then return x0, y0 + s - (d - h - 2 * s) end
    return x0 + (d - h - 3 * s), y0
end
local BREAK = { 0.125, 0.375, 0.625, 0.875 }     -- corner positions (fractions) of the walk

-- Walks from fraction a to b, calling fn(xa, ya, xb, yb) for every straight piece.
local function walk(a, b, x0, y0, s, fn)
    if b <= a then return end
    local ax, ay = perim(a, x0, y0, s)
    for i = 1, 4 do
        local c = BREAK[i]
        if c > a and c < b then
            local cx, cy = perim(c, x0, y0, s)
            fn(ax, ay, cx, cy); ax, ay = cx, cy
        end
    end
    local bx, by = perim(b, x0, y0, s)
    fn(ax, ay, bx, by)
end

local RING = { dl = nil, col = 0, w = 2 }
local function ring_piece(xa, ya, xb, yb)
    local w = RING.w / 2
    rectf(RING.dl, math.min(xa, xb) - w, math.min(ya, yb) - w, math.max(xa, xb) + w, math.max(ya, yb) + w, RING.col, 0)
end

local TWO_PI = math.pi * 2
local QA, QB, QC, QD = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
-- Arc of a ring from angle a0 to a1 (radians, clockwise from 12 o'clock), between radii r0 < r1.
local function arc(dl, cx, cy, r0, r1, a0, a1, col)
    local span = a1 - a0
    if span <= 0.0005 then return end
    local nseg = math.max(1, math.ceil(span / (TWO_PI / 48)))
    local sin, cos = math.sin, math.cos
    local pa, pb = a0, a0
    local sx, cx0 = sin(pa), cos(pa)
    for k = 1, nseg do
        pb = a0 + span * k / nseg
        local s1, c1 = sin(pb), cos(pb)
        QA[1], QA[2] = cx + r1 * sx, cy - r1 * cx0
        QB[1], QB[2] = cx + r1 * s1, cy - r1 * c1
        QC[1], QC[2] = cx + r0 * s1, cy - r0 * c1
        QD[1], QD[2] = cx + r0 * sx, cy - r0 * cx0
        dl:AddQuadFilled(QA, QB, QC, QD, col)
        sx, cx0 = s1, c1
    end
end

-- 2.10.0: the countdown as a shade over the icon that grows from the top down (keep = how much is left, 0..1), with a
-- line in the countdown color where it ends. shade / col: packed colors. Also used by the party list.
-- 2.10.2: tex / sil = the picture and its white copy: the shade and the edge then cover only the picture's own pixels
-- (the top part of the picture drawn again, tinted); without a picture (the colored tile) they are plain rectangles.
local DQ, DU = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }, { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
local function part(dl, id, x0, x1, ya, yb, va, vb, col)
    DQ[1][1], DQ[1][2], DQ[2][1], DQ[2][2], DQ[3][1], DQ[3][2], DQ[4][1], DQ[4][2] = x0, ya, x1, ya, x1, yb, x0, yb
    DU[1][1], DU[1][2], DU[2][1], DU[2][2], DU[3][1], DU[3][2], DU[4][1], DU[4][2] = 0, va, 1, va, 1, vb, 0, vb
    dl:AddImageQuad(id, DQ[1], DQ[2], DQ[3], DQ[4], DU[1], DU[2], DU[3], DU[4], col)
end
function M.drain(dl, x0, y0, size, keep, shade, col, tex, sil)
    keep = math.max(0, math.min(1, keep))
    local gone = 1 - keep
    local yb = y0 + size * gone
    if tex ~= nil then
        if yb > y0 then part(dl, tex, x0, x0 + size, y0, yb, 0, gone, shade) end
        if keep > 0 and keep < 1 and sil ~= nil then
            local h = math.min(1.5, size * keep)
            part(dl, sil, x0, x0 + size, yb, yb + h, gone, gone + h / size, col)
        end
        return
    end
    if yb > y0 then rectf(dl, x0, y0, x0 + size, yb, shade, 0) end
    if keep > 0 and keep < 1 then rectf(dl, x0, yb - 0.5, x0 + size, yb + 1, col, 0) end
end
-- The countdown ring around an icon at x0, y0 (size px): keep = how much is left (0..1), anchored at 12 o'clock and
-- draining counter-clockwise. track / col: packed colors of the empty track and the ring. Also used by the party list.
function M.ring(dl, x0, y0, size, keep, circle, pad, rw_px, track, col)
    if circle then
        local r0 = size / 2 + pad
        local r1 = r0 + rw_px
        local cx, cy = x0 + size / 2, y0 + size / 2
        arc(dl, cx, cy, r0, r1, 0, TWO_PI, track)
        arc(dl, cx, cy, r0, r1, 0, TWO_PI * keep, col)
    else
        RING.dl, RING.w = dl, rw_px
        local o = pad + rw_px / 2
        RING.col = track
        walk(0, 1, x0 - o, y0 - o, size + 2 * o, ring_piece)
        RING.col = col
        walk(0, keep, x0 - o, y0 - o, size + 2 * o, ring_piece)
    end
end

-- An effect that wore off never gets brighter again: if it was flashing on its way down, it follows the flash to the
-- dimmest point and fades from there to nothing; if the flash was on its way up (or it was not flashing), it fades to
-- nothing at once from where it is. Returns the opacity, 0 once it is gone. t_end = when it ended, warned = it was in
-- its warning (flashing) time, speed / fmin = the flash. Also used by the party list.
M.FADE_OUT = 0.5
function M.gone_alpha(now, t_end, warned, speed, fmin)
    if warned then
        local a0 = (1 + fmin) / 2 + (1 - fmin) / 2 * math.cos(t_end * TWO_PI * speed)
        if math.sin(t_end * TWO_PI * speed) >= 0 then                       -- on its way down: finish the dip first
            local tmin = (math.floor(t_end * speed - 0.5) + 1.5) / speed     -- the next dimmest point of the flash
            if now < tmin then return (1 + fmin) / 2 + (1 - fmin) / 2 * math.cos(now * TWO_PI * speed) end
            return math.max(0, fmin * (1 - (now - tmin) / M.FADE_OUT))
        end
        return math.max(0, a0 * (1 - (now - t_end) / M.FADE_OUT))
    end
    return math.max(0, 1 - (now - t_end) / M.FADE_OUT)
end

local MM = {}
local function mmss(sec)
    sec = (sec >= 3600) and math.floor(sec) or math.max(0, math.ceil(sec))   -- hours round down
    local t = MM[sec]
    if t == nil then
        if sec >= 3600 then t = ('%dh'):format(math.floor(sec / 3600))
        elseif sec >= 60 then t = ('%d:%02d'):format(math.floor(sec / 60), sec % 60)
        else t = tostring(sec) end
        if sec < 7200 then MM[sec] = t end
    end
    return t
end

--[[
* Draws the effects of one target. x, y = the pointer position. list[1..n] from M.active.
* push(scale) -> true when a font was pushed (popped here), base = the overall text size.
*
* Countdown ring: a ring slightly larger than the icon starts full and drains counter-clockwise from
* 12 o'clock, ending back at 12 o'clock when the time runs out. The last warn_secs seconds the number and
* ring change color and the icon flashes.
--]]
function M.draw(dl, cfg, x, y, list, n, now, push, base, fade, gx, gy)
    if n <= 0 then return end
    FA = fade or 1
    if FA <= 0.01 then return end
    Info.set_alpha(FA)
    local size = tonumber(cfg.size) or 22
    local gap = tonumber(cfg.spacing) or 2
    local cols = math.max(1, math.floor(tonumber(cfg.per_row) or 8))
    local tscale = (tonumber(cfg.text_scale) or 0.8)
    local text_mode = cfg.text or 'below'
    local ring_mode = cfg.ring or 'ring'
    local circle = (cfg.ring_shape or 'circle') == 'circle'
    local rw_px = tonumber(cfg.ring_width) or 2
    local pad = tonumber(cfg.ring_pad) or 3
    local m = (ring_mode == 'ring') and (pad + rw_px) or 0          -- room the ring needs around the icon
    local slot = size + 2 * m
    local bar_h = (ring_mode == 'bar') and math.max(2, math.floor(size * 0.12)) or 0
    local below_h = (text_mode == 'below') and math.ceil(size * 0.5) or 0
    local pitch = slot + gap + below_h + (bar_h > 0 and bar_h + 2 or 0) + ((text_mode == 'below') and 2 or 0)
    local up = cfg.rows_up == true
    local warn_at = tonumber(cfg.warn_secs) or 5
    local ST = Info.ST
    local fmin = math.max(0.1, math.min(1, tonumber(cfg.flash_min) or 0.6))
    local fspeed = tonumber(cfg.flash_speed) or 2.5
    for i = 1, n do
        local e = list[i]
        local r = math.floor((i - 1) / cols)
        local c = (i - 1) % cols
        local in_row = math.min(cols, n - r * cols)
        local rw = in_row * slot + (in_row - 1) * gap
        local left = x + (tonumber(cfg.dx) or 0) + (gx or 0)
        if cfg.align == 'center' then left = left - rw / 2 elseif cfg.align == 'right' then left = left - rw end
        local x0 = left + c * (slot + gap) + m
        local y0 = y + (tonumber(cfg.dy) or 0) + (gy or 0) - size / 2 + (up and -r or r) * pitch
        -- slide: each icon eases toward its place (relative to the row), so the rest close the gap when one ends
        if cfg.slide ~= false then
            local rx, ry = x0 - (x + (gx or 0)), y0 - (y + (gy or 0))
            local dt = math.min(0.1, math.max(0, now - (e.rt or now)))
            e.rt = now
            if e.rx == nil then e.rx, e.ry = rx, ry
            else
                local k = 1 - math.exp(-dt * 14)
                e.rx, e.ry = e.rx + (rx - e.rx) * k, e.ry + (ry - e.ry) * k
                if math.abs(rx - e.rx) < 0.3 then e.rx = rx end
                if math.abs(ry - e.ry) < 0.3 then e.ry = ry end
            end
            x0, y0 = x + (gx or 0) + e.rx, y + (gy or 0) + e.ry
        end
        local x1, y1 = x0 + size, y0 + size
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        Draw.hl_rect('info', 'fx', x0 - m, y0 - m, x1 + m, y1 + m + below_h)

        local remain, frac = nil, 0
        if e.exp > 0 then
            remain = e.exp - now
            frac = math.max(0, math.min(1, 1 - remain / e.dur))      -- 0 = just applied, 1 = gone
        end
        local ended = e.gone ~= nil or (remain ~= nil and remain < 0)     -- wore off: fades out (gone_alpha), then is dropped
        if ended then remain = nil end
        local warn = remain ~= nil and remain <= warn_at
        if not ended then e.warned = warn end
        -- the icon pulses during the last seconds (between "Flash dimmest" and full); once it has ended it finishes the
        -- pulse down to the dimmest point and fades to nothing from there
        local alpha = 1
        if ended then
            e.t_end = e.t_end or (e.gone or e.exp)
            alpha = M.gone_alpha(now, e.t_end, e.warned == true and cfg.flash ~= false, fspeed, fmin)
            if alpha <= 0 then e.faded = true end
        elseif warn and cfg.flash ~= false then alpha = (1 + fmin) / 2 + (1 - fmin) / 2 * math.cos(now * TWO_PI * fspeed) end

        -- the picture
        local ic = find_icon(e.status)
        local drew = false
        if ic then
            local t = ic.png:get(ic.file)
            if t.id ~= nil then
                Q1[1], Q1[2], Q2[1], Q2[2], Q3[1], Q3[2], Q4[1], Q4[2] = x0, y0, x1, y0, x1, y1, x0, y1
                dl:AddImageQuad(t.id, Q1, Q2, Q3, Q4, UV1, UV2, UV3, UV4, Draw.u32(WHITE, alpha * FA))
                drew = true
            end
        end
        if not drew then
            local l = placeholder(e.status)
            rectf(dl, x0, y0, x1, y1, u32(l.col, alpha), 3)
            local p = push and push(base * 0.62) or false
            Info.text_at(dl, l.label, cx, cy, 'center', Draw.u32(WHITE, alpha * FA), ST)
            if p then Fonts.pop() end
        end
        -- the countdown graphic
        local ccol = warn and cfg.warn_color or cfg.ring_color
        if remain ~= nil then
            if ring_mode == 'ring' then
                local keep = 1 - math.min(1, frac)                                    -- how much of the ring is left
                M.ring(dl, x0, y0, size, keep, circle, pad, rw_px, u32(BLACKB, 0.35), u32(ccol))
            elseif ring_mode == 'top' then
                local tid, sid = nil, nil
                if drew then
                    tid = ic.png:get(ic.file).id
                    local s = ic.png.silhouette and ic.png:silhouette(ic.file) or nil
                    sid = s and s.id or nil
                end
                M.drain(dl, x0, y0, size, 1 - math.min(1, frac), u32(BLACKB, 0.6), u32(ccol), tid, sid)
            elseif ring_mode == 'bar' then
                rectf(dl, x0, y1 + 1, x1, y1 + 1 + bar_h, u32({ 0, 0, 0, 0.7 }), 0)
                rectf(dl, x0, y1 + 1, x0 + size * (1 - frac), y1 + 1 + bar_h, u32(ccol), 0)
            end
        end

        -- the number
        if remain ~= nil and text_mode ~= 'off' then
            local p = push and push(base * tscale) or false
            local ty
            if text_mode == 'inside' then ty = cy
            else ty = y1 + m + (bar_h > 0 and bar_h + 5 or 3) + below_h * 0.4 end
            Info.text_at(dl, mmss(remain), cx, ty, 'center', u32(warn and cfg.warn_color or cfg.text_color), ST)
            if p then Fonts.pop() end
        end
    end
    Info.set_alpha(1)
    FA = 1
end

return M
