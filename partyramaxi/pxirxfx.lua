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
* RecastXI - rxfx.lua
* Polish effects drawn on top of the timer bars, rows and icons. Everything is built from the same
* draw-list primitives as the rest of the window (rxdraw), so there are no new image files, nothing
* is allocated per frame, and the window-bounds guard applies to every shape.
*
*   Bars    gloss (highlight + lower shade), moving shine, leading-edge spark, heat shift
*   Ready   a light sweep across the row, an icon pop with an expanding ring
*
* Settings (see recastxi.lua): fx_level 'off' | 'subtle' | 'full' and per-effect switches.
*   subtle: gloss, heat shift and the Ready sweep, a bit softer.  full: everything switched on.
*   Safe drawing (/rxi safe) and 'off' draw nothing here. With "Animate" off the effects that move are off too.
--]]

local D = require('pxirxdraw');

local M = {};
local floor, sin, cos, pi, min, max = math.floor, math.sin, math.cos, math.pi, math.min, math.max;

M.gloss, M.heat, M.shine, M.spark, M.sweep, M.ping = false, false, false, false, false, false;
M.bar_on = false;          -- any bar effect on
M.row_on = false;          -- any Ready effect on
M.k = 0.7;                 -- overall strength 0..1
M.period = 5;              -- seconds between shine passes on a bar
M.now = 0;
M.sk, M.ss = 1.0, 1.0;     -- spark strength and size multipliers
M.B = { rem = 0, frac = 0, ph = 0, hot = 0xFFFFFFFF, heat = 0 };   -- filled per bar by the caller (one shared table)

local stamp = nil;
-- Called once per frame (cheap when called again with the same time).
function M.update(s, now)
    if (stamp == now) then return; end
    stamp = now;
    M.now = now;
    local lvl = s.fx_level;
    local off = s.safe_mode or lvl == 'off' or lvl == nil;
    local full = lvl == 'full';
    local anim = s.animate ~= false;
    M.k = (tonumber(s.fx_strength) or 0.7) * (full and 1 or 0.65);
    M.period = tonumber(s.fx_shine_period) or 5;
    M.sk = (tonumber(s.fx_spark_strength) or 0.35) * 1.25;
    M.ss = tonumber(s.fx_spark_size) or 0.55;
    M.gloss = not off and s.fx_gloss ~= false;
    M.heat = not off and s.fx_heat ~= false;
    M.sweep = not off and anim and s.fx_sweep ~= false;
    M.shine = not off and full and anim and s.fx_shine ~= false;
    M.spark = not off and full and anim and s.fx_spark ~= false;
    M.ping = not off and full and anim and s.fx_ping ~= false;
    M.bar_on = M.gloss or M.heat or M.shine or M.spark;
    M.row_on = M.sweep or M.ping;
end

local TR, TG, TB = 255, 255, 255;      -- tint used by white() (set around tinted draws)
local function white(a)            -- a: 0..1 -> u32
    if (a < 0) then a = 0; elseif (a > 1) then a = 1; end
    return D.rgba(TR, TG, TB, a * 255);
end
local function plain(a)            -- always white
    if (a < 0) then a = 0; elseif (a > 1) then a = 1; end
    return D.rgba(255, 255, 255, a * 255);
end
local function black(a)
    if (a < 0) then a = 0; elseif (a > 1) then a = 1; end
    return D.rgba(0, 0, 0, a * 255);
end
local function smooth(t) return t * t * (3 - 2 * t); end

-- A soft vertical band of light centered on cx, hw wide on each side, clipped to [xa, xb].
-- The two halves are gradients; a clipped edge gets the brightness the band has at that x.
local function hband(xa, xb, ya, yb, cx, hw, a)
    local lo, hi = cx - hw, cx + hw;
    if (hi <= xa or lo >= xb or yb <= ya) then return; end
    -- rising half: lo -> cx
    local x0, x1 = max(lo, xa), min(cx, xb);
    if (x1 - x0 >= 0.5) then
        D.hgrad(x0, ya, x1, yb, white(a * (x0 - lo) / hw), white(a * (x1 - lo) / hw));
    end
    -- falling half: cx -> hi
    x0, x1 = max(cx, xa), min(hi, xb);
    if (x1 - x0 >= 0.5) then
        D.hgrad(x0, ya, x1, yb, white(a * (1 - (x0 - cx) / hw)), white(a * (1 - (x1 - cx) / hw)));
    end
end

-- Eases a row's heat toward its target (call once per row per frame with the row's own state table r).
-- Rises over about a second and a half, falls back a little faster.
function M.heat_step(r, frac, now)
    local tgt = 0;
    if (frac < 0.35) then local u = (0.35 - frac) / 0.35; tgt = smooth(u > 1 and 1 or u); end
    local dt = now - (r.fx_hn or now);
    r.fx_hn = now;
    if (dt > 0.25) then dt = 0.25; elseif (dt < 0) then dt = 0; end
    local h = r.fx_heat or 0;
    h = h + (tgt - h) * min(1, dt * (tgt > h and 2.0 or 3.5));
    r.fx_heat = h;
    return h;
end

-- Four thin spikes (a plus sign) of length len and base half-width wd, turned by ang radians.
local function spike4(cx, cy, len, wd, ang, c)
    for i = 0, 3 do
        local t = ang + i * pi * 0.5;
        local dx, dy = cos(t), sin(t);
        local px, py = -dy * wd, dx * wd;
        D.tri(cx + dx * len, cy + dy * len, cx - px, cy - py, cx + px, cy + py, c);
    end
end

--[[
* Bar effects over the filled part (xa, ya) - (xb, yb). round = the bar's corner rounding.
* xmax = right end of the whole bar (the spark never goes past it). thin = a line-style bar
* (only the spark applies). Uses M.B: rem (seconds left), frac (0..1 left), ph (phase offset in
* seconds, so rows don't shine in step) and hot (u32 color to warm toward, the Ready color).
--]]
function M.bar(xa, ya, xb, yb, round, xmax, thin)
    local w, h = xb - xa, yb - ya;
    if (w < 2 or h < 1) then return; end
    local B, k, now = M.B, M.k, M.now;
    round = round or 0;
    local ix = min(round * 0.5, w * 0.4);          -- keep overlays off rounded corners
    local xi0, xi1 = xa + ix, xb - ix;

    -- Heat shift. B.heat is 0..1 and already eased in over time by the caller (M.heat_step), so the
    -- bar warms gradually instead of snapping when it crosses 35%. Fixed warm colors keep it visible
    -- whatever the bar color is.
    local H = B.heat;
    if (M.heat and H > 0.01) then
        local ar, ag, ab = 255, 200 - 120 * H, 70 - 40 * H;
        local pulse = 0;
        if (B.rem > 0 and B.rem <= 5) then
            pulse = (0.5 + 0.5 * sin(now * (5 + (5 - B.rem) * 2.2))) * min(1, (5 - B.rem) / 1.5) * H;
        end
        if (thin) then
            local cy = (ya + yb) / 2;
            D.line(xa, cy, xb, cy, D.rgba(ar, ag, ab, H * 0.45 * k * 255), 4);
            D.line(xa, cy, xb, cy, D.rgba(255, 215 - 60 * H, 120, (0.55 * H + 0.4 * pulse) * k * 255), 1.5);
        else
            D.rectf(xa, ya, xb, yb, D.rgba(ar, ag, ab, H * 0.75 * k * 255), round);
            if (pulse > 0.01) then D.rectf(xa, ya, xb, yb, D.rgba(255, 235, 170, pulse * 0.40 * k * 255), round); end
        end
    end

    if (not thin) then
        if (M.gloss and xi1 > xi0) then
            D.vgrad(xi0, ya, xi1, ya + h * 0.5, white(0.42 * k), white(0.07 * k));
            if (h >= 3) then
                D.vgrad(xi0, yb - h * 0.34, xi1, yb, black(0), black(0.30 * k));
                D.line(xi0 + 0.5, ya + 0.7, xi1 - 0.5, ya + 0.7, white(0.45 * k), 1);
            end
        end
        if (M.shine) then
            local P = max(2, M.period);
            local t = (now + B.ph) % P;
            local dur = 0.9;
            if (t < dur) then
                local u = smooth(t / dur);
                local hw = max(8, h * 2.4);
                local cx = xa - hw + (w + 2 * hw) * u;
                hband(xi0, xi1, ya, yb, cx, hw, 0.6 * k);
            end
        end
    end

    -- Leading-edge star spark (same look and behavior as zztick): a slowly turning eight-point star with a
    -- breathing halo, a shimmer on its brightness and two tiny glints orbiting it. Gone once the bar is full.
    if (M.spark and B.frac > 0.02 and (xmax == nil or xb < xmax - 1)) then
        local cy = (ya + yb) / 2;
        local ex = xb;
        local a = k * M.sk;
        local WH = 0xFFFFFFFF;
        local hot = B.hot;
        local tw = 0.72 + 0.16 * sin(now * 7.3) + 0.12 * sin(now * 11.9 + 1.3);      -- shimmer
        local br = 0.5 + 0.5 * sin(now * 2.6);                                        -- halo breathing
        local rr = (h * 1.1 + 3) * M.ss;
        D.circlef(ex, cy, rr * (1.7 + 0.25 * br), D.mul(hot, (0.16 + 0.08 * br) * a), 16);
        D.circlef(ex, cy, rr * 1.05, D.mul(hot, 0.26 * a * tw), 14);
        D.circlef(ex, cy, rr * 0.55, plain(0.55 * a * tw), 12);
        local ang = now * 0.9;                                                        -- slow turn
        spike4(ex, cy, rr * 2.0, rr * 0.16, ang, plain(0.80 * a * tw));
        spike4(ex, cy, rr * 1.25, rr * 0.12, -ang * 0.7 + 0.785, plain(0.45 * a * tw));
        D.circlef(ex, cy, rr * 0.26, plain(0.95 * a), 10);
        for i = 0, 1 do                                                               -- two orbiting glints
            local oa = now * 1.7 + i * pi;
            D.circlef(ex + cos(oa) * rr * 1.15, cy + sin(oa) * rr * 0.85, max(1, rr * 0.11),
                plain(0.7 * a * (0.5 + 0.5 * sin(now * 5 + i * 2))), 6);
        end
    end
end

--[[
* Diagonal glint shared by the Ready sweep and the icon swipe. A soft band, built from thin horizontal
* strips each shifted along the diagonal, eases in and out across the rectangle (x0,y0)-(x1,y1) and
* is clipped to it. t = seconds since the start, dur = length, a = peak brightness (0..1),
* hwk = band half-width as a fraction of the longer side, hwmax = cap on that half-width in px.
--]]
local function glint(x0, y0, x1, y1, t, dur, col, a, hwk, hwmax)
    if (t < 0 or t > dur) then return; end
    local w, h = x1 - x0, y1 - y0;
    if (w < 4 or h < 4) then return; end
    local u = t / dur;
    local e = u * u * (3 - 2 * u);                       -- ease in and out
    local env = sin(pi * u) ^ 0.8;
    local hw = min(hwmax or 1e9, max(4, max(w, h) * hwk));
    local slant = h * 0.8;                               -- how far the top leads the bottom
    local cx0 = x0 - hw - slant * 0.5 + (w + 2 * hw + slant) * e;
    local n = max(3, min(24, floor(h / 1.5)));
    local sh = h / n;
    a = a * env;
    if (a <= 0.004) then return; end
    TR, TG, TB = 255, 255, 255;
    if (col) then
        local c = col % 16777216;
        TR, TG, TB = (255 * 2 + c % 256) / 3, (255 * 2 + floor(c / 256) % 256) / 3, (255 * 2 + floor(c / 65536) % 256) / 3;
    end
    for i = 0, n - 1 do
        local ya = y0 + i * sh;
        local inset = (i == 0 or i == n - 1) and 1 or 0;
        hband(x0 + inset, x1 - inset, ya, ya + sh, cx0 + (0.5 - (i + 0.5) / n) * slant, hw, a);
    end
    TR, TG, TB = 255, 255, 255;
end

-- Ready gloss (when a timer fills): a highly diffused, ultra-subtle translucent light sweep at a 30 degree
-- tilt. Two stacked soft bands (a broad veil and a narrower core) with a faint cool, metallic-glass tint;
-- the combined peak never exceeds GLOSS_MAX (0.12) opacity. Eases in and out, clipped to the row.
local SWEEP_DUR = 1.4;
local GLOSS_MAX = 0.12;
local TAN30 = 0.57735;
function M.sweep_row(x0, y0, x1, y1, t, col)
    if (t < 0 or t > SWEEP_DUR) then return; end
    local w, h = x1 - x0, y1 - y0;
    if (w < 8 or h < 4) then return; end
    local u = t / SWEEP_DUR;
    local e = u * u * u * (u * (u * 6 - 15) + 10);                -- smootherstep
    local env = sin(pi * u); env = env * env;                      -- soft fade in/out
    local pk = GLOSS_MAX * min(1, M.k / 0.7) * env;
    if (pk <= 0.003) then return; end
    local hw = max(10, min(w * 0.28, h * 3.2));                    -- broad, diffused half-width
    local slant = h * TAN30;                                       -- 30 degrees from vertical
    local cx0 = x0 - hw - slant * 0.5 + (w + 2 * hw + slant) * e;
    local n = max(3, min(16, floor(h / 2)));
    local sh = h / n;
    TR, TG, TB = 236, 243, 255;                                    -- cool, brushed-metal white
    for i = 0, n - 1 do
        local ya = y0 + i * sh;
        local cx = cx0 + (0.5 - (i + 0.5) / n) * slant;
        hband(x0 + 1, x1 - 1, ya, ya + sh, cx, hw, pk * 0.62);          -- veil
        hband(x0 + 1, x1 - 1, ya, ya + sh, cx, hw * 0.45, pk * 0.38);   -- core (sum = pk at the center)
    end
    TR, TG, TB = 255, 255, 255;
end

-- Icon pop: how many px to grow the icon on each side at time t after Ready (0 outside the pop).
local POP_DUR = 0.4;
function M.pop(t, size)
    if (t < 0 or t > POP_DUR) then return 0; end
    return size * 0.09 * sin(pi * t / POP_DUR);
end


-- Icon swipe: a quick diagonal glint across the icon image (t = seconds since Ready). The band is
-- built from thin horizontal strips, each shifted along the diagonal, and every strip is clipped to
-- the icon's own drawn rectangle (x0,y0)-(x1,y1) - the aspect-fitted image, so wide, tall or small
-- icons all get a band that stays inside their frame. The outer rows are inset a further pixel so
-- nothing pokes past the rounded corners. col: u32 theme color (the band is mostly white, a bit tinted).
local SWIPE_DUR = 0.5;
function M.swipe(x0, y0, x1, y1, t, col)
    glint(x0 + 1, y0 + 1, x1 - 1, y1 - 1, t, SWIPE_DUR, col, 0.85 * M.k, 0.30);
end

-- Border flash: a bright head runs once around the icon's border (clockwise from the top-left)
-- trailing a fading tail, while the whole border glows softly and fades. col: u32 theme color.
local RING_DUR = 1.0;
local TRAIL = 0.38;                                   -- tail length as a fraction of the border
local NSEG = 22;
local function perim(ix, iy, sz, p)                   -- p 0..1 around the square -> x, y
    p = p % 1;
    local q = p * 4;
    if (q < 1) then return ix + sz * q, iy; end
    if (q < 2) then return ix + sz, iy + sz * (q - 1); end
    if (q < 3) then return ix + sz - sz * (q - 2), iy + sz; end
    return ix, iy + sz - sz * (q - 3);
end
function M.ring(ix, iy, size, t, col)
    if (t < 0 or t > RING_DUR) then return; end
    local u = t / RING_DUR;
    local fade_all = (1 - u) ^ 1.2;
    local o = 1;                                       -- draw just outside the icon
    local x0, y0, s2 = ix - o, iy - o, size + 2 * o;
    D.rect(x0, y0, x0 + s2, y0 + s2, D.mul(col, 0.35 * M.k * fade_all), 2, 1.2);   -- soft full border
    local head = u * 1.15;                              -- runs a bit past one lap, then settles
    local ax, ay = perim(x0, y0, s2, head);
    for i = 1, NSEG do
        local f0 = (i - 1) / NSEG;
        local f1 = i / NSEG;
        local bx, by = perim(x0, y0, s2, head - f0 * TRAIL);
        local cx, cy = perim(x0, y0, s2, head - f1 * TRAIL);
        local k = (1 - f0) ^ 1.6;
        D.line(bx, by, cx, cy, D.mul(col, min(1, 1.1 * k) * M.k * fade_all + 0), 2.2 - 0.9 * f0);
    end
    D.circlef(ax, ay, 2.2, D.mul(0xFFFFFFFF, 0.9 * M.k * fade_all), 8);        -- bright head
end

M.SWEEP_DUR, M.POP_DUR, M.RING_DUR, M.SWIPE_DUR = SWEEP_DUR, POP_DUR, RING_DUR, SWIPE_DUR;
return M;
