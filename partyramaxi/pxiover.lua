--[[
* PartyramaXI - health bars over party members' heads (2.7.6; enemy's-target mark 2.8.1).
*
* Each member in the zone who is drawn on screen gets a small bar a set height above their feet. The point is projected
* with the game's own camera (the same projection the pointer uses), and the bar is scaled by its distance from the
* camera: 1:1 at "Full size at", smaller farther away, larger closer, within the min / max sizes. Bars are drawn on
* ImGui's background list, under every window, farthest first so nearer bars sit in front.
--]]
local imgui = require('imgui')
local Draw  = require('pxidraw')
local Fonts = require('pxifonts')
local PL                        -- pxilist (its bar_ext draws the Health bar look), loaded on first use

local M = {}

local PT = { x = 0, y = 0, depth = 0 }
local ROWS = {}                 -- reused per frame: { idx, hpp, mpp, x, y, depth }
local SHOWN = {}                -- member key -> displayed health share (eases toward the real one)
local V1, V2, V3 = { 0, 0 }, { 0, 0 }, { 0, 0 }
local BLACK = { 0, 0, 0, 1 }

local function vec(v, x, y) v[1], v[2] = x, y; return v end

-- Health color: the party list's own health colors (fill / warning / low at its thresholds).
local function hp_col(H, p)
    if not H.by_hp then return H.fill end
    local A = tonumber(H.warn_at) or 0.5
    local B = math.min(tonumber(H.low_at) or 0.25, A - 0.01)
    if p >= A then return H.fill end
    if p >= B then return H.warn end
    return H.low
end

local function bg_list()
    local f = imgui.GetBackgroundDrawList
    if type(f) == 'function' then
        local ok, dl = pcall(f)
        if ok and dl ~= nil then return dl end
    end
    return imgui.GetForegroundDrawList()
end

local function bar(dl, x0, y0, w, h, p, col, back, r, border, a)
    dl:AddRectFilled(vec(V1, x0, y0), vec(V2, x0 + w, y0 + h), Draw.u32(back, a), r)
    if p > 0 then dl:AddRectFilled(vec(V1, x0, y0), vec(V2, x0 + math.max(1, w * p), y0 + h), Draw.u32(col, a), r) end
    if border then dl:AddRect(vec(V1, x0 - 0.5, y0 - 0.5), vec(V2, x0 + w + 0.5, y0 + h + 0.5), Draw.u32(BLACK, 0.85 * a), r, 0, 1) end
end

local STATE = {}                -- member key -> sheen / comet start times for the Health bar look
local NUMS = {}
local function fmt_hp(H, r, O)
    local mode = H.text or 'current'
    local f = O and O.num_fmt
    if f ~= nil and f ~= 'list' then mode = f end      -- 2.9.2: its own format (e.g. percent)
    if mode == 'none' then mode = 'current' end
    local pct = math.floor(r.hpp * 100 + 0.5)
    local cur = r.hp or 0
    local key = mode .. cur .. ':' .. pct
    local t = NUMS[key]
    if t ~= nil then return t end
    if mode == 'percent' then t = pct .. '%'
    elseif mode == 'current_max' then t = cur .. '/' .. ((r.hpp > 0) and math.floor(cur / r.hpp + 0.5) or cur)
    elseif mode == 'both' then t = cur .. ' (' .. pct .. '%)'
    else t = tostring(cur) end
    NUMS[key] = t
    return t
end
-- 2.9.0: the health number on the bar, in the party list's Health number format, color and size.
local function number(dl, H, O, x0, y0, w, h, r, sc, a, ctx)
    local t = fmt_hp(H, r, O)
    local p = ctx.push and ctx.push(math.max(0.3, (tonumber(H.text_scale) or 0.8) * (tonumber(O.num_scale) or 1) * sc)) or false
    local ok, tw, th = pcall(imgui.CalcTextSize, t)
    if ok and type(tw) == 'table' then tw, th = tw.x or tw[1], tw.y or tw[2] end
    tw, th = tonumber(tw) or #t * 6, tonumber(th) or 12
    local x = math.floor(x0 + w / 2 - tw / 2 + (tonumber(O.num_dx) or 0) * sc + 0.5)
    local y = math.floor(y0 + h / 2 - th / 2 + (tonumber(O.num_dy) or 0) * sc + 0.5)
    dl:AddText(vec(V1, x + 1, y + 1), Draw.u32(BLACK, 0.85 * a), t)
    dl:AddText(vec(V1, x, y), Draw.u32(H.text_color or { 1, 1, 1, 1 }, a), t)
    if p then Fonts.pop() end
end

-- The "enemy is after this one" mark: a pulsing outline around the bar and / or a bobbing arrow above it.
-- kind = 'main' (your enemy's target) or 'other' (another monster's, drawn fainter).
function M.mark(dl, O, kind, x0, y0, w, yb, sc, a, now)
    local style = O.aggro_style or 'both'
    local col = O.aggro_color or { 1, 0.3, 0.22, 1 }
    local k = (kind == 'main') and 1 or 0.55
    local pulse = 0.6 + 0.4 * math.sin(now * 6)
    if style ~= 'arrow' then
        local t = math.max(1.5, 2 * sc)
        dl:AddRect(vec(V1, x0 - t - 0.5, y0 - t - 0.5), vec(V2, x0 + w + t + 0.5, yb + t + 0.5), Draw.u32(col, a * k * pulse), (tonumber(O.rounding) or 2) * sc + t, 0, t)
    end
    if style ~= 'outline' then
        local aw, ah = math.max(6, 11 * sc), math.max(5, 8 * sc)
        local bob = (kind == 'main') and 2.5 * sc * (0.5 + 0.5 * math.sin(now * 5)) or 0
        local cx, tip = x0 + w / 2, y0 - 3 * sc - bob
        vec(V1, cx - aw / 2, tip - ah); vec(V2, cx + aw / 2, tip - ah); vec(V3, cx, tip)
        dl:AddTriangleFilled(V1, V2, V3, Draw.u32(col, a * k))
        dl:AddTriangle(V1, V2, V3, Draw.u32(BLACK, 0.85 * a * k), 1)
    end
end

-- ctx: { party = Ashita party, screen = function (idx, up, out) -> bool, test = bool, now = seconds, dt = seconds,
--        marks = { [member target index] = 'main' | 'other' } }
function M.draw(L, O, ctx)
    local party = ctx.party
    if party == nil then return end
    local n = 0
    local myzone = party:GetMemberZone(0) or 0
    local last = (O.alliance and 17) or 5
    for i = (O.self and 0 or 1), last do
        if party:GetMemberIsActive(i) == 1 and (party:GetMemberZone(i) or 0) == myzone then
            local idx = party:GetMemberTargetIndex(i) or 0
            if idx ~= 0 and ctx.screen(idx, tonumber(O.head) or 2.4, PT) then
                n = n + 1
                local r = ROWS[n] or {}; ROWS[n] = r
                r.key, r.idx, r.hpp, r.mpp = i, idx, (party:GetMemberHPPercent(i) or 0) / 100, (party:GetMemberMPPercent(i) or 0) / 100
                local okh, hv = pcall(party.GetMemberHP, party, i)
                r.hp = okh and tonumber(hv) or 0
                if (party:GetMemberMP(i) or 0) <= 0 and r.mpp <= 0 then r.mpp = nil end      -- no mana pool: no MP bar
                r.x, r.y, r.depth = PT.x, PT.y, PT.depth or 10
            end
        end
    end
    -- Test: a bar over you with a sample health that falls and refills, so the look can be set up alone
    if ctx.test and n == 0 then
        local idx = party:GetMemberTargetIndex(0) or 0
        if idx ~= 0 and ctx.screen(idx, tonumber(O.head) or 2.4, PT) then
            n = 1
            local r = ROWS[1] or {}; ROWS[1] = r
            r.key, r.idx, r.hpp, r.mpp = 'test', -1, 0.55 + 0.45 * math.cos(ctx.now * 0.8), 0.7
            r.hp = math.floor(1500 * r.hpp + 0.5)
            r.x, r.y, r.depth = PT.x, PT.y, PT.depth or 10
        end
    end
    for i = n + 1, #ROWS do ROWS[i] = nil end
    if n == 0 then return end
    table.sort(ROWS, function (a, b) return a.depth > b.depth end)      -- farthest first

    local dl = bg_list()
    local ref = math.max(1, tonumber(O.ref) or 8)
    local far = tonumber(O.max_dist) or 40
    local W, H = tonumber(O.width) or 60, tonumber(O.height) or 6
    -- 2.10.1: the largest size is set in px (the bar's width when nearest); never smaller than the set width
    local smin, smax = tonumber(O.min_scale) or 0.4, math.max(1, (tonumber(O.max_px) or 90) / math.max(1, W))
    local rr = tonumber(O.rounding) or 2
    local back = O.back or { 0, 0, 0, 0.6 }
    local k = math.min(1, (ctx.dt or 0) * 6)
    for j = 1, n do
        local r = ROWS[j]
        if r.depth <= far then
            local sc = ref / math.max(0.5, r.depth)
            if sc < smin then sc = smin elseif sc > smax then sc = smax end
            -- fades out over the last 15% before the far limit
            local a = math.min(1, (far - r.depth) / (far * 0.15)) * (tonumber(O.alpha) or 1)
            local shown = SHOWN[r.key] or r.hpp
            shown = shown + (r.hpp - shown) * k
            SHOWN[r.key] = shown
            local w, h = W * sc, math.max(2, H * sc)
            local x0 = math.floor(r.x - w / 2 + (tonumber(O.dx) or 0) * sc + 0.5)
            local y0 = math.floor(r.y - h + (tonumber(O.dy) or 0) * sc + 0.5)
            local col = hp_col(L.hp, r.hpp)
            if O.hp_look then
                -- 2.9.0: the party list's Health bar look (finish, border, rounding, trail, sheen and comet)
                if PL == nil then PL = require('pxilist') end
                local st = STATE[r.key]
                if st == nil then st = {}; STATE[r.key] = st end
                local full = r.hpp >= 0.995
                if st.full == false and full then st.sh, st.cm = ctx.now or 0, ctx.now or 0 end
                st.full = full
                pcall(PL.bar_ext, dl, L.hp, x0, y0, w, h, r.hpp, col, L.hp.trail and shown > r.hpp + 0.005 and shown or nil, a, ctx.now or 0, st)
            elseif shown > r.hpp + 0.005 then         -- the lost part trails behind in the trail color
                bar(dl, x0, y0, w, h, shown, L.hp.trail_color or col, back, rr * sc, false, a)
                dl:AddRectFilled(vec(V1, x0, y0), vec(V2, x0 + math.max(1, w * r.hpp), y0 + h), Draw.u32(col, a), rr * sc)
                dl:AddRect(vec(V1, x0 - 0.5, y0 - 0.5), vec(V2, x0 + w + 0.5, y0 + h + 0.5), Draw.u32(BLACK, 0.85 * a), rr * sc, 0, 1)
            else
                bar(dl, x0, y0, w, h, r.hpp, col, back, rr * sc, true, a)
            end
            if O.hp_num then number(dl, L.hp, O, x0, y0, w, h, r, sc, a, ctx) end
            local yb = y0 + h
            if O.mp and r.mpp ~= nil then
                local mh = math.max(2, (tonumber(O.mp_height) or 3) * sc)
                bar(dl, x0, y0 + h + 1, w, mh, r.mpp, L.mp.fill, back, rr * sc, true, a)
                yb = y0 + h + 1 + mh
            end
            -- 2.8.1: the enemy is after this member (the test bar shows the mark too)
            local mk = (r.idx == -1) and 'main' or (ctx.marks and ctx.marks[r.idx])
            if mk then M.mark(dl, O, mk, x0, y0, w, yb, sc, a, ctx.now or 0) end
        end
    end
end

return M
