--[[
* PartyramaXI - status effect icons on the party list: what each icon knows (time left, when it was applied, its
* magic type), the per-icon motion (slide, fade in, the random flash on beneficial effects), the icon under the mouse
* (tooltip, click to cancel) and the retail-style cursor for cancelling your own effects from keys or a controller.
* pxilist.lua draws the icons; this module keeps the state, so pxilist stays under LuaJIT's local limit.
--]]
local imgui  = require('imgui')
local Fx     = require('pxifx')
local FxData = require('pxifxdata')
local Data   = require('pxilistdata')

local M = {}
local hpp
function M.init(h) hpp = h end

M.SORTS = { 'game', 'recent', 'soonest', 'longest', 'type' }      -- 2.10.1: 'id' gone (saved 'id' becomes 'type')
M.SORT_LABELS = { game = 'Game order', recent = 'Last applied first', soonest = 'Time left: ending soon first',
    longest = 'Time left: ending last first', type = 'By type (your order)' }
-- 2.10.1: pinned effects: 'top' (2.10.2: labelled Show) = first when active; 'hide' = never shown; 'party' = hidden on the other members' cards
M.PIN_MODES = { 'top', 'hide', 'party' }
M.PIN_LABELS = { top = 'Show', hide = 'Hide', party = 'Hide on party only' }
function M.pin_mode(B, id)
    local t = type(B.pin_mode) == 'table' and B.pin_mode['s' .. id]
    return (t == 'hide' or t == 'party') and t or 'top'
end
-- "Fit to the card": as many icons per row as fit in the card's inner width w (never more than "Per row").
function M.fit_per(B, w, pitch)
    local size, gap = tonumber(B.size) or 16, tonumber(B.gap) or 1
    local fits = math.floor((w + gap) / (pitch or (size + gap)))
    return math.max(1, math.min(fits, math.floor(tonumber(B.per_row) or 12)))
end
M.CANCELS = { 'confirm', 'click', 'off' }
M.CANCEL_LABELS = { confirm = 'Click, then confirm', click = 'Click cancels at once', off = 'Off' }

-- Magic types (spell skill ids) in the order "Type" sorts them; effects with no known spell come last.
M.SKILL_NAME = { [32] = 'Divine', [33] = 'Healing', [34] = 'Enhancing', [35] = 'Enfeebling', [36] = 'Elemental',
    [37] = 'Dark', [38] = 'Summoning', [39] = 'Ninjutsu', [40] = 'Singing', [41] = 'String', [42] = 'Wind',
    [43] = 'Blue', [44] = 'Geomancy', [45] = 'Handbell' }
-- 2.10.1: "By type" sorts by groups of magic types in the player's own order (B.type_order, dragged in the settings);
-- the default is the old fixed Type order. 'other' = effects with no known spell (or a type not listed here).
M.GROUPS = { 'enh', 'heal', 'song', 'geo', 'nin', 'blue', 'divine', 'enf', 'dark', 'elem', 'smn', 'other' }
M.GROUP_LABELS = { enh = 'Enhancing', heal = 'Healing', song = 'Songs (singing, string, wind)', geo = 'Geomancy (and handbell)',
    nin = 'Ninjutsu', blue = 'Blue magic', divine = 'Divine', enf = 'Enfeebling', dark = 'Dark', elem = 'Elemental',
    smn = 'Summoning', other = 'Unknown / other' }
local SKILL_GROUP = { [34] = 'enh', [33] = 'heal', [40] = 'song', [41] = 'song', [42] = 'song', [44] = 'geo', [45] = 'geo',
    [39] = 'nin', [43] = 'blue', [32] = 'divine', [35] = 'enf', [37] = 'dark', [36] = 'elem', [38] = 'smn' }
-- the order list made whole: unknown keys and repeats dropped, missing groups added at the end
function M.fix_order(t)
    local out, seen = {}, {}
    if type(t) == 'table' then
        for _, g in ipairs(t) do if M.GROUP_LABELS[g] and not seen[g] then seen[g] = true; out[#out + 1] = g end end
    end
    for _, g in ipairs(M.GROUPS) do if not seen[g] then out[#out + 1] = g end end
    return out
end
local RANK, RANK_SRC, RANK_N = {}, false, 0       -- false: not built yet

-- Harmful effects (no flash). Status ids from the game's buff list: the classic ailments 0-31, the elemental DoTs and
-- stat downs, Dia / Bio, the -down effects, Requiem / Lullaby / Elegy / Nocturne, and a few later ones.
M.DEBUFF = {}
for i = 0, 31 do M.DEBUFF[i] = true end
for i = 128, 149 do M.DEBUFF[i] = true end
for _, i in ipairs({ 156, 167, 168, 174, 175, 177, 186, 189, 192, 193, 194, 223, 259, 404, 540, 557, 558, 559, 560,
    561, 562, 563, 564, 565, 566, 567, 572, 597 }) do M.DEBUFF[i] = true end

-- status id -> the first spell in the effect data that gives it (for the magic type of effects we did not see cast)
local STATUS_SPELL = nil
local function status_spell(id)
    if STATUS_SPELL == nil then
        STATUS_SPELL = {}
        for sp, d in pairs(FxData.spells or {}) do
            local st = d[1]
            if st ~= nil and (STATUS_SPELL[st] == nil or sp < STATUS_SPELL[st]) then STATUS_SPELL[st] = sp end
        end
    end
    return STATUS_SPELL[id]
end

local function fx_entry(r, id)
    local l = Fx.fx and Fx.fx[r.sid]
    local e = l and l[id]
    if e ~= nil and e.gone == nil then return e end
    return nil
end

-- When the effect ends (clock time), or nil. Your own: the game's own timer; others: spells we saw land.
function M.exp(r, id)
    if r.slot == 0 then
        local s = Data.self[id]
        if s ~= nil and s.exp ~= nil then return s.exp end
    end
    local e = fx_entry(r, id)
    if e and e.exp and e.exp > 0 then return e.exp end
    return nil
end

-- The full length of the effect when it is known from a spell we saw land (others' effects, the sample party), or nil.
function M.dur(r, id)
    local e = fx_entry(r, id)
    if e and e.dur and e.dur > 0 and not (r.slot == 0 and Data.self[id] ~= nil) then return e.dur end
    return nil
end

-- When the effect was applied, as far as we know: first seen on the member (or when we saw the spell land).
local SEEN, SEEN_N = {}, 0
function M.seen(r, id, now)
    local per = SEEN[r.sid]
    if per == nil then per = {}; SEEN[r.sid] = per end
    local sn = per[id]
    if sn == nil or now - sn.last > 3 then
        SEEN_N = SEEN_N + 1
        if SEEN_N > 400 then SEEN = {}; SEEN_N = 0; per = {}; SEEN[r.sid] = per end
        sn = { t0 = now, last = now }; per[id] = sn
    end
    sn.last = now
    return sn
end
-- pxitimers: read and refill the first-seen times (kept across zoning and sessions).
function M.seen_table() return SEEN end
function M.seen_put(sid, id, t0, now)
    local per = SEEN[sid]
    if per == nil then per = {}; SEEN[sid] = per end
    if per[id] == nil then per[id] = { t0 = t0, last = now }; SEEN_N = SEEN_N + 1 end
end
function M.t0(r, id, now)
    local e = fx_entry(r, id)
    if e ~= nil then return e.t0 end
    if r.slot == 0 and Data.self[id] ~= nil then return Data.self[id].t0 end
    return M.seen(r, id, now).t0
end

-- Spell skill (magic type) of the effect, or nil.
function M.skill(r, id)
    local e = fx_entry(r, id)
    local sp = e and e.spell or status_spell(id)
    if sp == nil or Data.spell_skill == nil then return nil end
    return Data.spell_skill(sp)
end
function M.skill_rank(r, id, order)
    if order ~= RANK_SRC or (type(order) == 'table' and #order or 0) ~= RANK_N then      -- rebuilt when the order list (or its length) changes
        RANK_SRC, RANK_N = order, type(order) == 'table' and #order or 0
        for k in pairs(RANK) do RANK[k] = nil end
        for i, g in ipairs(M.fix_order(order)) do RANK[g] = i end
    end
    local sk = M.skill(r, id)
    return RANK[sk and SKILL_GROUP[sk] or 'other']
end
function M.rank_dirty() RANK_SRC = false end
-- 2.10.2: the effect's group key ('enh', 'enf'... 'other'), for hiding a whole type
function M.group_of(r, id)
    local sk = M.skill(r, id)
    return sk and SKILL_GROUP[sk] or 'other'
end

---------------------------------------------------------------------------
-- Per-icon motion: ST[server id][status id] = { x, y (position relative to the row), a (fade in), seen, nxt / f0 (flash) }
---------------------------------------------------------------------------
local ST, sweep_at = {}, 0
function M.icon(r, id, rx, ry, now, dt, slide)
    local per = ST[r.sid]
    if per == nil then per = {}; ST[r.sid] = per end
    local s = per[id]
    if s == nil or now - s.seen > 1 then
        s = { x = rx, y = ry, a = 0, seen = now, nxt = nil, f0 = -10 }; per[id] = s     -- a new (or returning) effect
    end
    s.seen = now
    if slide then
        local k = 1 - math.exp(-dt * 14)
        s.x, s.y = s.x + (rx - s.x) * k, s.y + (ry - s.y) * k
        if math.abs(rx - s.x) < 0.3 then s.x = rx end
        if math.abs(ry - s.y) < 0.3 then s.y = ry end
        s.a = math.min(1, s.a + dt / 0.2)
    else
        s.x, s.y, s.a = rx, ry, 1
    end
    if now - sweep_at > 10 then
        sweep_at = now
        for sid, p in pairs(ST) do
            local any = false
            for k, v in pairs(p) do if now - v.seen > 5 then p[k] = nil else any = true end end
            if not any then ST[sid] = nil end
        end
    end
    return s
end

-- Effects that just ended stay in the row, in their old place, while they fade out (Fx.gone_alpha: a flashing one finishes
-- its flash down to the dimmest point first); then the rest slide into the gap. order[1..n] = the current effects;
-- returns the new count with the fading ones put back in. s.idx / s.warn are set by the party list while drawing.
local CUR, GH, GHN = {}, {}, 0
local function by_idx(p, q) return p.idx < q.idx end
function M.with_gone(r, order, n, now, B)
    local per = ST[r.sid]
    if per == nil then return n end
    for k in pairs(CUR) do CUR[k] = nil end
    for i = 1, n do CUR[order[i]] = true end
    GHN = 0
    local speed = tonumber(B.warn_speed) or 2.5
    local fmin = math.max(0.1, math.min(1, tonumber(B.warn_min) or 0.6))
    for id, s in pairs(per) do
        if CUR[id] then s.gone, s.ga = nil, nil
        elseif s.idx ~= nil and now - s.seen < 3 then
            s.gone = s.gone or now
            s.ga = Fx.gone_alpha(now, s.gone, s.warn == true and B.warn_flash ~= false, speed, fmin)
            if s.ga <= 0 then per[id] = nil
            else GHN = GHN + 1; local g = GH[GHN]; if g == nil then g = {}; GH[GHN] = g end; g.id, g.idx = id, s.idx end
        end
    end
    if GHN == 0 then return n end
    for i = GHN + 1, #GH do GH[i].idx = 1e9 end
    table.sort(GH, by_idx)
    for k = 1, GHN do
        local pos = math.min(GH[k].idx, n + 1)
        for i = n, pos, -1 do order[i + 1] = order[i] end
        order[pos] = GH[k].id
        n = n + 1
    end
    return n
end

-- The flash on a beneficial effect: a sweep at a random moment every lo..hi seconds, each icon on its own clock.
-- Returns the sweep's progress 0..1 while it plays, else nil.
M.FLASH_DUR = 0.7
function M.flash(s, id, now, B)
    if M.DEBUFF[id] then return nil end
    local lo = tonumber(B.flash_min) or 30
    local hi = math.max(lo, tonumber(B.flash_max) or 60)
    if s.nxt == nil then s.nxt = now + lo * 0.25 + math.random() * (hi - lo * 0.25) end   -- first one somewhere in the window
    if now >= s.nxt then s.f0 = now; s.nxt = now + M.FLASH_DUR + lo + math.random() * (hi - lo) end
    local p = (now - s.f0) / M.FLASH_DUR
    if p > 0 and p < 1 then return p end
    return nil
end

---------------------------------------------------------------------------
-- The icon under the mouse (recorded while drawing, used the next frame), tooltip and click to cancel
---------------------------------------------------------------------------
M.hover = { f = -1, slot = -1, id = 0, x0 = 0, y0 = 0, x1 = 0, y1 = 0, sid = 0 }
M.mouse = { x = -1e9, y = -1e9 }
M.frame = 0
M.own = { n = 0 }                                       -- your own icons in display order (for the cursor)
M.cur = { on = false, i = 1, t = 0 }                    -- retail-style cursor on your own icons
M.ask = { id = 0, x = 0, y = 0, t = 0 }                 -- cancel question open for this status id (0 = none)

function M.begin(mx, my)
    M.frame = M.frame + 1
    M.mouse.x, M.mouse.y = mx or -1e9, my or -1e9
end

-- An icon was drawn at x0, y0 (size px) for member r: remember it if the mouse is on it.
function M.place(r, id, x0, y0, size)
    local m = M.mouse
    if m.x >= x0 and m.x < x0 + size and m.y >= y0 and m.y < y0 + size then
        local h = M.hover
        h.f, h.slot, h.id, h.sid, h.x0, h.y0, h.x1, h.y1 = M.frame, r.slot, id, r.sid, x0, y0, x0 + size, y0 + size
    end
end

-- Was the mouse on an icon in the last drawn frame? (the list then takes mouse input over it)
function M.hovering(slot)
    local h = M.hover
    if h.f < M.frame - 1 then return false end
    return slot == nil or h.slot == slot
end

local function cancellable(id)
    local B = hpp and hpp.s and hpp.s.list.buffs
    if B == nil or B.cancel == 'off' then return false end
    for i = 1, M.own.n do if M.own[i] == id then return true end end
    return false
end

-- Ask to cancel (or cancel at once). x, y: where the question appears.
function M.request(id, x, y, now)
    if not cancellable(id) then return end
    if hpp.s.list.buffs.cancel == 'click' then hpp.cancel_buff(id); M.ask.id = 0; return end
    local a = M.ask
    a.id, a.x, a.y, a.t = id, x, y, now
end

local function fmt_time(t)
    t = math.max(0, math.floor(t + 0.5))
    if t >= 3600 then return ('%d:%02d:%02d'):format(math.floor(t / 3600), math.floor(t / 60) % 60, t % 60) end
    return ('%d:%02d'):format(math.floor(t / 60), t % 60)
end

-- The tooltip text, rebuilt only when the icon or the shown second changes.
local TIP = { id = -1, sid = -1, sec = -1, text = '' }
local function tooltip(r, id, now)
    local ex = M.exp(r, id)
    local sec = ex and math.floor(ex - now) or -math.floor(now - M.t0(r, id, now))
    if TIP.id == id and TIP.sid == r.sid and TIP.sec == sec then return TIP.text end
    local lines = { Fx.name_of(id) }
    local desc = Data.buff_desc(id)
    if desc then lines[#lines + 1] = desc end
    local sk = M.skill(r, id)
    if sk and M.SKILL_NAME[sk] then lines[#lines + 1] = M.SKILL_NAME[sk] .. ' magic' end
    if ex then lines[#lines + 1] = 'Time left ' .. fmt_time(ex - now)
    else lines[#lines + 1] = 'On for ' .. fmt_time(now - M.t0(r, id, now)) .. ' (duration unknown)' end
    if r.slot == 0 and cancellable(id) then
        lines[#lines + 1] = hpp.s.list.buffs.cancel == 'click' and 'Click to cancel' or 'Click to cancel (asks first)'
    end
    TIP.id, TIP.sid, TIP.sec, TIP.text = id, r.sid, sec, table.concat(lines, '\n')
    return TIP.text
end

local ASK_POS, ASK_OPEN = { 0, 0 }, { true }
local ASK_FLAGS = nil
-- After the list is drawn: tooltip, clicks, the cancel question, the cursor timeout.
function M.after(now)
    local B = hpp.s.list.buffs
    local h = M.hover
    if h.f == M.frame and B.show then
        local r = nil
        for i = 1, 18 do local m = Data.m[i]; if m.active and m.slot == h.slot and m.sid == h.sid then r = m; break end end
        if r ~= nil then
            if B.tooltip ~= false then imgui.SetTooltip(tooltip(r, h.id, now)) end
            local okc, clicked = pcall(imgui.IsMouseClicked, 0)
            if okc and clicked and r.slot == 0 then M.request(h.id, h.x1 + 4, h.y0, now) end
        end
    end
    if M.cur.on and now - M.cur.t > 20 then M.cur.on = false end
    local a = M.ask
    if a.id ~= 0 then
        if now - a.t > 15 or not cancellable(a.id) then a.id = 0; return end
        if ASK_FLAGS == nil then
            ASK_FLAGS = bit.bor(ImGuiWindowFlags_NoDecoration or 0, ImGuiWindowFlags_AlwaysAutoResize or 0, ImGuiWindowFlags_NoSavedSettings or 0,
                ImGuiWindowFlags_NoFocusOnAppearing or 0, ImGuiWindowFlags_NoNav or 0)
        end
        ASK_POS[1], ASK_POS[2] = a.x, a.y
        imgui.SetNextWindowPos(ASK_POS, ImGuiCond_Always)
        ASK_OPEN[1] = true
        if imgui.Begin('##hpp_cancel_ask', ASK_OPEN, ASK_FLAGS) then
            imgui.Text('Cancel ' .. Fx.name_of(a.id) .. '?')
            if imgui.Button('Yes##hpp_ask_y') then hpp.cancel_buff(a.id); a.id = 0 end
            imgui.SameLine()
            if imgui.Button('No##hpp_ask_n') then a.id = 0 end
        end
        imgui.End()
    end
end

-- Keys / controller (bind them like the game's menu buttons): /pxi buffs [next|prev|ok|back]
--   (nothing) or a direction: the cursor appears on your first effect, or moves; ok: ask to cancel the effect under
--   the cursor, ok again: confirm; back: close the question, then the cursor.
function M.command(word, now)
    local c, a = M.cur, M.ask
    local n = M.own.n
    if word == 'back' or word == 'esc' then
        if a.id ~= 0 then a.id = 0 else c.on = false end
        return true
    end
    if n == 0 then c.on = false; return false end
    c.t = now
    if not c.on then c.on, c.i = true, 1; if word ~= 'ok' then return true end end
    if word == 'next' or word == 'right' then c.i = c.i % n + 1; a.id = 0
    elseif word == 'prev' or word == 'left' then c.i = (c.i - 2) % n + 1; a.id = 0
    elseif word == 'ok' or word == 'enter' then
        if c.i > n then c.i = n end
        local id = M.own[c.i]
        if a.id == id then hpp.cancel_buff(id); a.id = 0
        else M.request(id, M.own.x or 0, M.own.y or 0, now) end
    end
    return true
end

return M
