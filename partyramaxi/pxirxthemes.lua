--[[
* RecastXI - rxthemes.lua
* Five themes, their crests, header ornaments and bar styles, all drawn with ImGui draw-list
* primitives (rxdraw) in window-local coordinates. No font glyphs or images are needed.
--]]

local D = require('pxirxdraw');
local FX = require('pxirxfx');
local M = {};
local floor, sin, cos, pi, max, min = math.floor, math.sin, math.cos, math.pi, math.max, math.min;

-- Dragoon Forever palettes (sampled from the Drachen / Wyrm item icons, brightened for UI).
M.DRAGOON = {
    Drachen = { hd1 = { 112, 92, 160 }, hd2 = { 46, 38, 70 }, bg1 = { 36, 30, 52 }, bg2 = { 16, 13, 22 },
                text = { 240, 234, 255 }, dim = { 172, 158, 206 }, glow = { 150, 120, 230 }, border = { 184, 148, 96 },
                plate = { 96, 84, 112 }, plate_hi = { 136, 112, 192 }, plate_dk = { 53, 45, 70 }, abyss = { 32, 29, 36 },
                stud = { 136, 112, 192 }, bevel_rim = { 206, 210, 228 }, bevel_hi = { 248, 248, 255 } },   -- silver
    Wyrm    = { hd1 = { 74, 68, 160 }, hd2 = { 24, 22, 46 }, bg1 = { 24, 24, 44 }, bg2 = { 10, 10, 16 },
                text = { 232, 234, 255 }, dim = { 152, 152, 205 }, glow = { 110, 110, 240 }, border = { 190, 135, 95 },
                plate = { 88, 80, 176 }, plate_hi = { 136, 136, 240 }, plate_dk = { 40, 40, 51 }, abyss = { 24, 24, 29 },
                stud = { 141, 133, 179 }, bevel_rim = { 200, 146, 98 }, bevel_hi = { 255, 214, 170 } },    -- bronze
};

M.LIST = {
    { name = "San d'Oria Regalia", short = 'regalia', radius = 4, crest = 'shield', ornate = true, bar = 'gem',
      bg1 = { 38, 14, 22 }, bg2 = { 18, 10, 26 }, hd1 = { 140, 28, 40 }, hd2 = { 40, 24, 80 }, border = { 214, 175, 90 },
      glow = { 230, 180, 90 }, text = { 245, 232, 210 }, dim = { 190, 165, 140 }, acc_sp = { 235, 195, 105 }, acc_ab = { 225, 120, 110 },
      bar1 = { 250, 215, 120 }, bar2 = { 160, 100, 30 },
      bevel_rim = { 224, 184, 96 }, bevel_hi = { 255, 238, 176 },     -- gold
      fonts = { title = 'Cinzel-Bold.ttf', body = 'Inter-Regular.ttf', num = 'Inter-SemiBold.ttf' } },
    { name = 'Bastok Steam', short = 'bastok', radius = 2, crest = 'gear', rivets = true, bar = 'segment',
      bg1 = { 15, 22, 36 }, bg2 = { 8, 12, 22 }, hd1 = { 60, 92, 150 }, hd2 = { 24, 44, 84 }, border = { 214, 170, 92 },
      glow = { 110, 160, 240 }, text = { 232, 236, 242 }, dim = { 142, 156, 180 }, acc_sp = { 236, 196, 120 }, acc_ab = { 120, 190, 230 },
      bar1 = { 236, 196, 120 }, bar2 = { 176, 106, 44 },
      bevel_rim = { 214, 170, 92 }, bevel_hi = { 250, 230, 168 },     -- brass
      fonts = { title = 'BarlowSemiCondensed-SemiBold.ttf', body = 'BarlowSemiCondensed-Regular.ttf', num = 'BarlowSemiCondensed-SemiBold.ttf' } },
    { name = 'Windurst Verdant', short = 'windurst', radius = 12, crest = 'none', bar = 'pill',
      bg1 = { 18, 32, 26 }, bg2 = { 9, 18, 16 }, hd1 = { 84, 138, 110 }, hd2 = { 30, 70, 62 }, border = { 190, 170, 110 },
      glow = { 150, 220, 170 }, text = { 246, 246, 232 }, dim = { 168, 190, 172 }, acc_sp = { 190, 225, 140 }, acc_ab = { 250, 200, 120 },
      bar1 = { 236, 214, 130 }, bar2 = { 96, 162, 92 },
      bevel_rim = { 200, 182, 124 }, bevel_hi = { 250, 240, 200 },    -- pale leaf
      fonts = { title = 'Fredoka-SemiBold.ttf', body = 'Fredoka-SemiBold.ttf', num = 'Fredoka-SemiBold.ttf' } },
    { name = 'Voidwatch', short = 'voidwatch', radius = 3, crest = 'hex', caps = true, bar = 'line',
      bg1 = { 10, 11, 15 }, bg2 = { 6, 7, 10 }, hd1 = { 16, 18, 26 }, hd2 = { 10, 11, 16 }, border = { 60, 70, 90 },
      glow = { 80, 220, 255 }, text = { 220, 228, 240 }, dim = { 120, 130, 150 }, acc_sp = { 90, 215, 255 }, acc_ab = { 200, 140, 255 },
      bar1 = { 90, 215, 255 }, bar2 = { 90, 215, 255 },
      bevel_rim = { 120, 170, 200 }, bevel_hi = { 190, 240, 255 },    -- cold steel
      fonts = { title = 'Inter-SemiBold.ttf', body = 'Inter-Regular.ttf', num = 'JetBrainsMono-Regular.ttf' } },
    { name = 'Dragoon Forever', short = 'dragoon', radius = 4, crest = 'holy', dragoon = true, bar = 'banded',
      acc_sp = { 196, 176, 240 }, acc_ab = { 136, 136, 240 },
      fonts = { title = 'MarcellusSC-Regular.ttf', body = 'Exo2-SemiBold.ttf', num = 'Exo2-SemiBold.ttf' } },
};
M.DEFAULT = 'Dragoon Forever';
M.ALIASES = { regalia = "San d'Oria Regalia", sandoria = "San d'Oria Regalia", bastok = 'Bastok Steam', windurst = 'Windurst Verdant', voidwatch = 'Voidwatch', void = 'Voidwatch', dragoon = 'Dragoon Forever', drg = 'Dragoon Forever' };

function M.find(name)
    if (type(name) ~= 'string') then return nil; end
    local a = M.ALIASES[name:lower()]; if (a ~= nil) then name = a; end
    for _, t in ipairs(M.LIST) do if (t.name == name or t.name:lower() == name:lower()) then return t; end end
    return nil;
end

-- Resolved theme with u32 colors (cached per name+palette).
local cache = {};
local COLS = { 'bg1', 'bg2', 'hd1', 'hd2', 'border', 'glow', 'text', 'dim', 'acc_sp', 'acc_ab', 'bar1', 'bar2',
               'plate', 'plate_hi', 'plate_dk', 'abyss', 'stud' };
function M.resolve(name, palette)
    local t = M.find(name) or M.find(M.DEFAULT);
    local key = t.name .. '|' .. ((t.dragoon and palette) or '');
    local r = cache[key];
    if (r ~= nil) then return r; end
    local src = {};
    for k, v in pairs(t) do src[k] = v; end
    if (t.dragoon) then
        local p = M.DRAGOON[palette] or M.DRAGOON.Drachen;
        for k, v in pairs(p) do src[k] = v; end
        src.bar1, src.bar2 = src.plate_hi, src.plate;
        src.palette = (M.DRAGOON[palette] and palette) or 'Drachen';
    end
    r = { def = t, name = t.name, src = src, u = {} };
    for _, k in ipairs(COLS) do if (src[k] ~= nil) then r.u[k] = D.col(src[k]); end end
    local u = r.u;
    u.black60 = D.rgba(0, 0, 0, 150); u.black30 = D.rgba(0, 0, 0, 80); u.white = D.rgba(255, 255, 255, 255);
    u.sheen = D.rgba(255, 255, 255, 34); u.white10 = D.rgba(255, 255, 255, 22);
    u.gold = D.rgba(255, 220, 120, 255); u.flash = D.rgba(110, 255, 150, 255); u.flash_fill = D.rgba(90, 230, 130, 60);
    u.pin = D.rgba(255, 215, 90, 255); u.pin_dark = D.rgba(40, 25, 0, 255);
    u.badge_bg = D.rgba(0, 0, 0, 105); u.rivet = D.rgba(230, 180, 92, 255);
    u.shield_red = D.rgba(120, 20, 32, 255); u.gear = D.rgba(150, 105, 50, 255); u.gear_in = D.rgba(45, 40, 36, 255);
    u.gear_rim = D.rgba(240, 190, 110, 255); u.star_bg = D.rgba(40, 100, 60, 255); u.star = D.rgba(255, 235, 150, 255);
    u.hex_bg = D.rgba(12, 14, 20, 255); u.clear = D.rgba(255, 255, 255, 0);
    u.gem_bg = D.rgba(30, 15, 20, 255); u.seg_bg = D.rgba(18, 16, 15, 255); u.seg_rim = D.rgba(90, 80, 70, 255);
    u.pill_bg = D.rgba(18, 42, 28, 255); u.pill_end = D.rgba(255, 255, 240, 230); u.line_bg = D.rgba(40, 46, 58, 255);
    u.band_hi = D.rgba(255, 255, 255, 70);
    u.border_soft = D.mul(u.border, 0.35);
    -- SP badges (v1.1.0): ready = accent fill + bright text + glow; muted = grey and dim
    local bc = M.badge_contrast(src);
    r.badge_samples = bc;
    u.badge_on_fill = D.col(bc.fill); u.badge_on_top = D.col(bc.top);
    u.badge_on_text = D.col(bc.text); u.badge_on_shadow = D.col(bc.shadow, bc.shadow[4]);
    u.badge_on_glow1 = D.mul(D.col(src.acc_sp), 0.45); u.badge_on_glow2 = D.mul(D.col(src.acc_sp), 0.2);
    u.badge_off_fill = D.rgba(40, 40, 46, 170); u.badge_off_border = D.rgba(120, 120, 130, 110);
    u.badge_off_text = D.col(bc.muted_text, 255); u.badge_off_time = D.col(bc.muted_text, 255);
    -- Badge bevel (v1.1.1): embossed when ready, debossed/pressed when muted. Rim = theme trim metal.
    local rim, hi = src.bevel_rim or src.border, src.bevel_hi or { 255, 255, 255 };
    u.bv_rim_on = D.col(rim, 165);                           -- thin inner rim
    u.bv_hi_on = D.col(hi, 185);                             -- top-edge highlight line
    u.bv_lo_on = D.rgba(0, 0, 0, 115);                       -- bottom inner shadow
    u.bv_out_on = D.lerp_col(rim, { 0, 0, 0 }, 0.45);        -- dark outer edge under the rim
    u.bv_sheen_top = D.rgba(255, 255, 255, 58); u.bv_sheen_bot = D.rgba(255, 255, 255, 0);   -- specular sheen
    u.bv_shimmer = D.rgba(255, 255, 255, 30); u.bv_shimmer_soft = D.rgba(255, 255, 255, 12);
    u.bv_off_top = D.rgba(24, 24, 29, 200); u.bv_off_bot = D.rgba(44, 44, 50, 175);         -- darker at the top: pressed in
    u.bv_off_inner = D.rgba(0, 0, 0, 105);                   -- inner shadow along the top edge
    u.bv_off_lip = D.rgba(255, 255, 255, 20);                -- faint lit lip along the bottom edge
    local g = (rim[1] + rim[2] + rim[3]) / 3;
    u.bv_rim_off = D.rgba(g * 0.55 + rim[1] * 0.15, g * 0.55 + rim[2] * 0.15, g * 0.55 + rim[3] * 0.15, 60);
    u.badge_off_deboss = D.rgba(255, 255, 255, 16);          -- text: faint light 1 px below = engraved
    u.badge_off_outline = D.rgba(0, 0, 0, 150);              -- v1.3.0: dark outline keeps muted text legible
    u.acc_sp_soft = D.mul(u.acc_sp, 0.35); u.acc_ab_soft = D.mul(u.acc_ab, 0.35);
    u.acc_sp_tint = D.mul(u.acc_sp, 0.09); u.acc_ab_tint = D.mul(u.acc_ab, 0.09);
    u.glow1 = D.mul(u.glow, 0.28); u.glow2 = D.mul(u.glow, 0.14); u.glow3 = D.mul(u.glow, 0.06);
    if (src.plate ~= nil) then u.trim_soft = D.mul(u.border, 0.5); u.abyss_soft = D.mul(u.abyss, 0.8); u.plate_dk_soft = D.mul(u.plate_dk, 0.8); end
    u.border_half = D.mul(u.border, 0.5);
    u.acc_sp_30, u.acc_ab_30 = D.mul(u.acc_sp, 0.3), D.mul(u.acc_ab, 0.3);
    u.acc_sp_55, u.acc_ab_55 = D.mul(u.acc_sp, 0.55), D.mul(u.acc_ab, 0.55);
    u.bar_hi = D.lerp_col(src.bar1, { 255, 255, 255 }, 0.3); u.bar_lo = D.lerp_col(src.bar2, { 0, 0, 0 }, 0.2);
    cache[key] = r;
    return r;
end
function M.clear_cache() cache = {}; end

--[[
* SP badge text contrast (v1.3.0). WCAG 2 relative luminance / contrast ratio. The ready text is
* white or near-black, whichever reads better on the badge (top with sheen, gradient, flat fill);
* if neither reaches 4.5:1 the fill is darkened until white does. The muted text is an opaque grey
* lightened until it reaches 3:1 on the pressed-in fill over the header. Samples are kept on the
* theme (th.badge_samples) so the tests can check the ratios independently.
--]]
local function chan(c) c = c / 255; if (c <= 0.03928) then return c / 12.92; end return ((c + 0.055) / 1.055) ^ 2.4; end
function M.luminance(rgb) return 0.2126 * chan(rgb[1]) + 0.7152 * chan(rgb[2]) + 0.0722 * chan(rgb[3]); end
function M.contrast(a, b)
    local la, lb = M.luminance(a), M.luminance(b);
    if (la < lb) then la, lb = lb, la; end
    return (la + 0.05) / (lb + 0.05);
end
local function over(fg, a, bg) local k = a / 255; return { fg[1] * k + bg[1] * (1 - k), fg[2] * k + bg[2] * (1 - k), fg[3] * k + bg[3] * (1 - k) }; end
local function min_ratio(txt, samples) local m = math.huge; for i = 1, #samples do local r = M.contrast(txt, samples[i]); if (r < m) then m = r; end end return m; end
M.TEXT_LIGHT, M.TEXT_DARK = { 255, 255, 255 }, { 14, 12, 18 };
M.READY_MIN, M.MUTED_MIN = 4.5, 3.0;
function M.badge_contrast(src)
    local fill = D.lerp_rgb(src.acc_sp, src.hd2 or { 0, 0, 0 }, 0.35);
    local top = D.lerp_rgb(src.acc_sp, { 255, 255, 255 }, 0.25);
    local function on_samples(f, t) return { over({ 255, 255, 255 }, 58, t), t, f }; end
    local samples = on_samples(fill, top);
    local txt, shadow;
    for _ = 1, 20 do
        local rl, rd = min_ratio(M.TEXT_LIGHT, samples), min_ratio(M.TEXT_DARK, samples);
        if (rd >= M.READY_MIN and rd >= rl) then txt, shadow = M.TEXT_DARK, { 255, 255, 255, 110 }; break; end
        if (rl >= M.READY_MIN) then txt, shadow = M.TEXT_LIGHT, { 0, 0, 0, 160 }; break; end
        fill = D.lerp_rgb(fill, { 0, 0, 0 }, 0.12); top = D.lerp_rgb(top, { 0, 0, 0 }, 0.12);   -- darken until white reads
        samples = on_samples(fill, top);
    end
    if (txt == nil) then txt, shadow = M.TEXT_LIGHT, { 0, 0, 0, 200 }; end
    local bgs = { src.hd1 or { 0, 0, 0 }, src.hd2 or { 0, 0, 0 }, src.bg1 or { 0, 0, 0 } };
    local off = {};
    for _, bgc in ipairs(bgs) do
        off[#off + 1] = over({ 24, 24, 29 }, 200, bgc); off[#off + 1] = over({ 44, 44, 50 }, 175, bgc); off[#off + 1] = over({ 40, 40, 46 }, 170, bgc);
    end
    local mt = { 150, 150, 160 };
    for _ = 1, 30 do
        if (min_ratio(mt, off) >= M.MUTED_MIN + 0.15) then break; end
        mt = D.lerp_rgb(mt, { 255, 255, 255 }, 0.08);
    end
    return { fill = fill, top = top, text = txt, shadow = shadow, muted_text = mt, on = samples, off = off,
             ready_ratio = min_ratio(txt, samples), muted_ratio = min_ratio(mt, off) };
end


--[[ ---------------- crests (cx, cy = center, r = radius) ---------------- ]]
local SHIELD = { -1, -0.9, 1, -0.9, 1, 0.1, 0, 1.05, -1, 0.1 };
local KITE = { -0.78, -0.74, 0.78, -0.74, 0.78, 0.06, 0, 0.98, -0.78, 0.06 };
local KITE_IN = { -0.6, -0.6, 0.6, -0.6, 0.6, 0.02, 0, 0.76, -0.6, 0.02 };

function M.crest_shield(th, cx, cy, r)
    local u = th.u;
    D.circlef(cx, cy, r * 1.15, u.glow2, 20);
    D.poly(SHIELD, 5, u.shield_red, cx, cy, r);
    D.polyline(SHIELD, 5, u.border, 2, cx, cy, r, true);
    D.line(cx, cy - r * 0.7, cx, cy + r * 0.78, u.border, 2);
    D.line(cx - r * 0.7, cy - r * 0.15, cx + r * 0.7, cy - r * 0.15, u.border, 2);
end
function M.crest_gear(th, cx, cy, r)
    local u = th.u;
    local tooth = u.gear;
    for i = 0, 9 do
        local a = i * pi / 5;
        local ca, sa = cos(a), sin(a);
        local w = 0.2;
        local x1, y1 = cx + r * 0.72 * cos(a - w), cy + r * 0.72 * sin(a - w);
        local x2, y2 = cx + r * 0.72 * cos(a + w), cy + r * 0.72 * sin(a + w);
        local x3, y3 = cx + r * cos(a + w * 0.7), cy + r * sin(a + w * 0.7);
        local x4, y4 = cx + r * cos(a - w * 0.7), cy + r * sin(a - w * 0.7);
        D.quad(x1, y1, x2, y2, x3, y3, x4, y4, tooth);
    end
    D.circlef(cx, cy, r * 0.8, tooth, 24);
    D.circlef(cx, cy, r * 0.55, u.gear_in, 24);
    D.circle(cx, cy, r * 0.55, u.gear_rim, 24, 1.5);
end
function M.crest_star(th, cx, cy, r)
    local u = th.u;
    D.circlef(cx, cy, r + 3, u.glow2, 24);
    D.circlef(cx, cy, r, u.star_bg, 24);
    D.circle(cx, cy, r, u.border, 24, 2);
    D.star(cx, cy - 1, r * 0.62, r * 0.27, u.star, 5);
end
local HEX = {};
for i = 0, 5 do local a = pi / 3 * i - pi / 2; HEX[2 * i + 1], HEX[2 * i + 2] = cos(a), sin(a); end
function M.crest_hex(th, cx, cy, r)
    local u = th.u;
    D.poly(HEX, 6, u.hex_bg, cx, cy, r);
    D.polyline(HEX, 6, u.glow2, 4, cx, cy, r, true);
    D.polyline(HEX, 6, u.glow, 1.5, cx, cy, r, true);
    D.polyline(HEX, 6, u.glow2, 1, cx, cy, r * 0.55, true);
end
--[[
* The Holy Crest (Dragoon Forever): an original heraldic emblem inspired by the DRG unlock quest
* "The Holy Crest" - a San d'Oria kite shield, a lance rising through it, spread wyvern wings and a
* wyvern-egg gem (the egg you dig up in the quest). Drawn from shapes only; not game art.
--]]
function M.crest_holy(th, cx, cy, r)
    local u = th.u;
    D.circlef(cx, cy, r * 1.05, u.glow3, 24);
    -- wings behind the shield (three feathers per side)
    for side = -1, 1, 2 do
        local bx, by = cx + side * r * 0.1, cy - r * 0.12;
        D.tri(bx, by, cx + side * r * 1.18, cy - r * 0.78, cx + side * r * 0.92, cy - r * 0.32, u.plate_hi);
        D.tri(bx, by, cx + side * r * 1.22, cy - r * 0.36, cx + side * r * 0.95, cy + r * 0.02, u.plate);
        D.tri(bx, by + r * 0.08, cx + side * r * 1.05, cy + r * 0.06, cx + side * r * 0.72, cy + r * 0.3, u.plate_dk);
        D.line(bx, by, cx + side * r * 1.18, cy - r * 0.78, u.trim_soft or u.border, 1);
    end
    -- shield
    D.poly(KITE, 5, u.plate_dk, cx, cy, r);
    D.poly(KITE_IN, 5, u.plate, cx, cy, r);
    D.polyline(KITE, 5, u.border, 1.6, cx, cy, r, true);
    -- lance through the shield
    D.line(cx, cy + r * 0.8, cx, cy - r * 0.62, u.border, max(1.5, r * 0.09));
    D.line(cx - r * 0.18, cy - r * 0.6, cx + r * 0.18, cy - r * 0.6, u.border, max(1.2, r * 0.07));
    D.tri(cx, cy - r * 1.12, cx + r * 0.15, cy - r * 0.62, cx - r * 0.15, cy - r * 0.62, u.text);
    -- wyvern-egg gem
    D.circlef(cx, cy + r * 0.16, r * 0.25, u.border, 16);
    D.circlef(cx, cy + r * 0.16, r * 0.19, u.acc_sp, 16);
    D.circlef(cx - r * 0.06, cy + r * 0.09, r * 0.06, u.white, 8);
    -- holy glint at the spear tip
    D.star(cx, cy - r * 1.12, r * 0.2, r * 0.05, u.white, 4);
end
function M.crest_none() end
M.CRESTS = { none = M.crest_none, shield = M.crest_shield, gear = M.crest_gear, star = M.crest_star, hex = M.crest_hex, holy = M.crest_holy };

function M.draw_crest(th, cx, cy, r)
    local f = M.CRESTS[th.def.crest] or M.crest_hex;
    f(th, cx, cy, r);
end

--[[ ---------------- window frame ---------------- ]]
M.GLOW_SIZE = 10;   -- px the outer glow reaches outside the frame (the caller reserves this margin)

--[[
* Outer glow (v1.1.0): a soft halo of nested rounded outlines whose alpha falls off with distance,
* plus a bright 1 px inner rim. k = intensity 0..1. v1.0.0 drew three 2 px outlines at 28/14/6 %
* alpha, which was nearly invisible on a dark game background.
--]]
function M.draw_glow(th, w, h, k)
    local u, R = th.u, th.def.radius;
    local n = 7;
    for i = n, 1, -1 do
        local d = i * (M.GLOW_SIZE / n);
        local f = 1 - (i - 1) / n;
        D.rect(-d, -d, w + d, h + d, D.mul(u.glow, k * 0.62 * f * f), R + d, 2.2);
    end
    D.rect(-0.5, -0.5, w + 0.5, h + 0.5, D.mul(u.glow, 0.9 * k), R, 1.5);
end

--[[
* Header texture (v1.1.0), clipped to the header. One pattern per theme:
*   Regalia: gold diamond lattice   Bastok: rivet rows + plate seams   Windurst: offset dot weave
*   Voidwatch: scanlines + hex cells   Dragoon Forever: overlapping dragon scales
* k = intensity 0..1. (v1.0.0 only drew tiny body studs for Dragoon Forever and nothing for the others.)
--]]
local function tex_regalia(u, w, hb, k)
    local c = D.mul(u.border, 0.42 * k);
    local step = 12;
    local x = -hb;
    while (x < w + hb) do
        D.seg(x, 1, x + hb, hb, c, 1, 1, 1, w - 1, hb);
        D.seg(x + hb, 1, x, hb, c, 1, 1, 1, w - 1, hb);
        x = x + step;
    end
    local cd = D.mul(u.border, 0.7 * k);
    x = step / 2;
    while (x < w) do D.circlef(x, hb / 2, 1.4, cd, 6); x = x + step * 2; end
end
local function tex_bastok(u, w, hb, k)
    local c = D.mul(u.rivet, 0.95 * k);
    local seam = D.mul(u.black60, 0.9 * k);
    local hi = D.mul(u.white, 0.25 * k);
    local x = 34;
    while (x < w - 10) do D.line(x, 2, x, hb - 1, seam, 1.5); D.line(x + 1.5, 2, x + 1.5, hb - 1, hi, 1); x = x + 46; end
    x = 12;
    while (x < w - 6) do
        D.circlef(x, 4.5, 1.9, c, 8); D.circlef(x, hb - 4.5, 1.9, c, 8);
        D.circlef(x - 0.5, 4, 0.7, hi, 6); D.circlef(x - 0.5, hb - 5, 0.7, hi, 6);
        x = x + 14;
    end
end
-- Vector fallback (only used when icons\\fx\\windurst_*.png are missing): a cheap linen weave,
-- dark warp threads every 6 px and pale weft threads every 6 px (~60 lines). The real cloth weave is
-- the pre-rendered tile pair below (tex_windurst_tiles).
local function tex_windurst(u, w, hb, k)
    local warp = D.mul(u.black60, 0.7 * k);
    local weft = D.mul(u.white, 0.16 * k);
    local y = 3;
    while (y < hb) do D.line(1, y, w - 1, y, warp, 1.5); y = y + 6; end
    local x = 3;
    while (x < w) do D.line(x, 1, x, hb - 1, weft, 2); x = x + 6; end
end
local HEXT = {};
for i = 0, 5 do local a = pi / 3 * i; HEXT[2 * i + 1], HEXT[2 * i + 2] = cos(a), sin(a); end
local function tex_voidwatch(u, w, hb, k)
    local sl = D.mul(u.glow, 0.10 * k);
    local y = 2;
    while (y < hb) do D.line(1, y, w - 1, y, sl, 1); y = y + 3; end
    local hc = D.mul(u.glow, 0.30 * k);
    local r = 7;
    local col = 0;
    local x = w * 0.45;
    while (x < w + r) do
        local yy = (col % 2 == 0) and (hb * 0.5) or (hb * 0.5 - r * 0.87);
        while (yy < hb + r) do D.polyline(HEXT, 6, hc, 1, x, yy, r, true); yy = yy + r * 1.74; end
        x = x + r * 1.5; col = col + 1;
    end
end
local function tex_dragoon(u, w, hb, k)
    local c = D.mul(u.plate_hi, 0.55 * k);
    local cd = D.mul(u.plate_dk, 0.55 * k);
    local r = 7;
    local row = 0;
    local y = 2;
    while (y < hb + r) do
        local x = (row % 2 == 0) and 0 or r;
        while (x < w + r) do
            D.circle(x, y, r, cd, 14, 2);
            D.circle(x, y - 0.8, r, c, 14, 1);
            x = x + 2 * r;
        end
        y = y + r * 0.9; row = row + 1;
    end
end
--[[
* v1.3.2 pre-rendered header textures. The vector patterns cost up to ~1 ms per frame (Dragoon: ~430
* circle outlines). Each pattern is baked into small seamless white+alpha PNG tiles in
* addons\\recastxi\\icons\\fx\\ and tinted here with theme colors (D.image_uv), so a header is a couple
* of dozen image quads. A theme can have several STYLES (first one is the default); the caller
* (recastxi.lua) loads the tiles of the chosen style and passes { style = <name>, <file> = texture id }
* to draw_frame. If a file is missing or not loaded yet, the theme draws its vector pattern instead.
*   regalia   lattice : regalia_lat 48x48
*   bastok    brushed : bastok_brush_sh / _hi 128x32       brushed steel grain
*             rust    : bastok_rust_sh / _hi / _rs 192x96  rusted steel (grain + corrosion patches)
*             rivets  : bastok_riv / bastok_hi 56x10       the original rivet rows + seams
*   windurst  cloth   : windurst_sh / _hi 72x48            plain-weave cloth
*   voidwatch hex     : voidwatch_hex 63x61
*   dragoon   keeled  : dragoon_keel_dk / _hi 32x40        overlapping keeled scales
*             scales  : dragoon_dk / _hi 56x25             the original round scales
--]]
M.STYLE_LIST = {
    regalia = { 'lattice' }, bastok = { 'works', 'mines', 'brushed', 'rust', 'rivets', 'white' }, windurst = { 'tower', 'sea', 'cloth' },
    voidwatch = { 'hex' }, dragoon = { 'keeled', 'scales' },
};
M.STYLE_KEY = { bastok = 'bastok_style', windurst = 'windurst_style', dragoon = 'dragoon_style' };    -- setting that stores the choice
M.FX_STYLES = {
    regalia = { lattice = { 'regalia_lat' } },
    bastok = { works = { 'bastok_works' }, mines = { 'bastok_mines' }, brushed = { 'bastok_brush_sh', 'bastok_brush_hi' }, rust = { 'bastok_rust_sh', 'bastok_rust_hi', 'bastok_rust_rs' },
               rivets = { 'bastok_riv', 'bastok_hi' }, white = { 'bastok_riv', 'bastok_hi' } },
    windurst = { tower = { 'windurst_tower' }, sea = { 'windurst_sea' }, cloth = { 'windurst_sh', 'windurst_hi' } },
    voidwatch = { hex = { 'voidwatch_hex' } },
    dragoon = { keeled = { 'dragoon_keel_dk', 'dragoon_keel_hi' }, scales = { 'dragoon_dk', 'dragoon_hi' } },
};
-- The style to use for a theme: the stored choice if valid, else the theme's first style. No allocation.
function M.style_for(short, s)
    local list = M.STYLE_LIST[short];
    if (list == nil) then return nil; end
    local key = M.STYLE_KEY[short];
    local v = (key ~= nil and s ~= nil) and s[key] or nil;
    if (v ~= nil and M.FX_STYLES[short][v] ~= nil) then return v; end
    return list[1];
end
function M.fx_files(short, style)
    local st = M.FX_STYLES[short];
    return st ~= nil and style ~= nil and st[style] or nil;
end
-- Repeats a tile from (ox, oy) to (x1, y1) (whole pixels, so tiles stay crisp).
local function tile_fill(tex, ox, oy, x1, y1, tw, th, c)
    local y = oy;
    while (y < y1) do
        local x = ox;
        while (x < x1) do
            D.image_uv(tex, x, y, x + tw, y + th, 0, 0, 1, 1, c);
            x = x + tw;
        end
        y = y + th;
    end
end
-- Full-colour scene styles (one 960x128 picture per style, aspect SCENE_AR). Drawn "cover" style: the
-- picture fills the header, cropping the sides (or top/bottom) through its UVs.
local SCENE_AR = 7.5;
M.SCENES = { works = 'bastok_works', mines = 'bastok_mines', tower = 'windurst_tower', sea = 'windurst_sea' };
local TILES = {};
TILES.bastok = {}; TILES.bastok.works = true; TILES.bastok.mines = true; TILES.bastok.white = true;
TILES.windurst = {}; TILES.windurst.tower = true; TILES.windurst.sea = true;
local function draw_scene(tex, x0, y0, x1, y1, R, flags, k, u)
    local aw, ah = x1 - x0, y1 - y0;
    if (aw <= 2 or ah <= 2) then return; end
    local u0, v0, u1, v1 = 0, 0, 1, 1;
    if (aw / ah > SCENE_AR) then
        local f = ah * SCENE_AR / aw; v0 = (1 - f) * 0.5; v1 = v0 + f;      -- wide header: crop top/bottom
    else
        local f = aw / (ah * SCENE_AR); u0 = (1 - f) * 0.5; u1 = u0 + f;    -- tall header: crop the sides
    end
    local a = 0.45 + k; if (a > 1) then a = 1; end
    D.image_uv_round(tex, x0, y0, x1, y1, u0, v0, u1, v1, D.mul(u.white, a), R, flags);
    -- soft scrim on the left so the title stays readable over bright artwork
    D.hgrad(x0, y0, x0 + math.floor(aw * 0.55), y1, D.mul(u.black60, 0.55 * a), u.clear);
end

local function fx_ok(short, fx)
    if (fx == nil) then return false; end
    local names = M.fx_files(short, fx.style);
    local set = TILES[short];
    if (names == nil or set == nil or set[fx.style] == nil) then return false; end
    for i = 1, #names do if (fx[names[i]] == nil) then return false; end end
    return true;
end
TILES.regalia = {};
TILES.regalia.lattice = function (u, w, hb, k, fx)
    tile_fill(fx.regalia_lat, 0, 0, w, hb, 48, 48, D.mul(u.border, 0.42 * k));
    local cd = D.mul(u.border, 0.7 * k);                      -- the little dots stay vector (~14 calls)
    local x = 6;
    while (x < w) do D.circlef(x, hb / 2, 1.4, cd, 6); x = x + 24; end
end
-- (TILES.bastok created above with the scene styles)
local function bastok_rivet_rows(u, w, hb, k, fx, rivet_col)
    local seam = D.mul(u.black60, 0.9 * k);
    local hi = D.mul(u.white, 0.25 * k);
    local x = 34;
    while (x < w - 10) do D.line(x, 2, x, hb - 1, seam, 1.5); D.line(x + 1.5, 2, x + 1.5, hb - 1, hi, 1); x = x + 46; end
    local c = D.mul(rivet_col, min(1, 0.6 + k));                -- rivets stay bright even at low intensity
    local hi2 = D.mul(u.white, min(1, 0.45 * (0.5 + k)));
    local by = floor(hb) - 9;                                   -- bottom rivet row (tile centre 4.5 px down)
    tile_fill(fx.bastok_riv, 0, 0, w, 10, 56, 10, c);   tile_fill(fx.bastok_hi, 0, 0, w, 10, 56, 10, hi2);
    tile_fill(fx.bastok_riv, 0, by, w, by + 10, 56, 10, c); tile_fill(fx.bastok_hi, 0, by, w, by + 10, 56, 10, hi2);
end
TILES.bastok.rivets = function (u, w, hb, k, fx) bastok_rivet_rows(u, w, hb, k, fx, u.rivet); end         -- brass
TILES.bastok.white = function (u, w, hb, k, fx) bastok_rivet_rows(u, w, hb, k, fx, u.white); end          -- white
TILES.bastok.brushed = function (u, w, hb, k, fx)
    tile_fill(fx.bastok_brush_sh, 0, 0, w, hb, 128, 32, D.mul(u.black60, 1.7 * k));
    tile_fill(fx.bastok_brush_hi, 0, 0, w, hb, 128, 32, D.mul(u.white, 0.8 * k));
end
local RUST = D.rgba(176, 86, 38, 255);
TILES.bastok.rust = function (u, w, hb, k, fx)
    tile_fill(fx.bastok_rust_sh, 0, 0, w, hb, 192, 96, D.mul(u.black60, 1.7 * k));      -- grain shadow, pits, dark cores
    tile_fill(fx.bastok_rust_hi, 0, 0, w, hb, 192, 96, D.mul(u.white, 0.8 * k));        -- grain highlights on clean steel
    tile_fill(fx.bastok_rust_rs, 0, 0, w, hb, 192, 96, D.mul(RUST, 1.4 * k));           -- corrosion
end
TILES.windurst.cloth = function (u, w, hb, k, fx)
    -- plain-weave cloth: shadow layer (gaps and the underside of every thread), then the highlight
    tile_fill(fx.windurst_sh, 0, 0, w, hb, 72, 48, D.mul(u.black60, 1.7 * k));
    tile_fill(fx.windurst_hi, 0, 0, w, hb, 72, 48, D.mul(u.white, k));
end
TILES.voidwatch = {};
TILES.voidwatch.hex = function (u, w, hb, k, fx)
    local sl = D.mul(u.glow, 0.10 * k);
    local y = 2;
    while (y < hb) do D.line(1, y, w - 1, y, sl, 1); y = y + 3; end   -- scanlines stay vector (~17 calls)
    tile_fill(fx.voidwatch_hex, floor(w * 0.45) - 8, 0, w, hb, 63, 61, D.mul(u.glow, 0.30 * k));
end
TILES.dragoon = {};
TILES.dragoon.scales = function (u, w, hb, k, fx)
    tile_fill(fx.dragoon_dk, 0, 0, w, hb, 56, 25, D.mul(u.plate_dk, 0.55 * k));
    tile_fill(fx.dragoon_hi, 0, 0, w, hb, 56, 25, D.mul(u.plate_hi, 0.55 * k));
end
TILES.dragoon.keeled = function (u, w, hb, k, fx)
    -- keeled dragon scales: dark outlines/right facets in the abyss tone, lit left facets and keel in plate_hi
    tile_fill(fx.dragoon_keel_dk, 0, 0, w, hb, 32, 40, D.mul(u.abyss, 1.25 * k));
    tile_fill(fx.dragoon_keel_hi, 0, 0, w, hb, 32, 40, D.mul(u.plate_hi, 1.4 * k));
end
M.TEXTURES = { regalia = tex_regalia, bastok = tex_bastok, windurst = tex_windurst, voidwatch = tex_voidwatch, dragoon = tex_dragoon };

-- w, h local frame size; hh = header height; header_only = collapsed bar; glow/texture intensities 0..1 (0 = off).
function M.draw_frame(th, w, h, hh, header_only, glow_k, tex_k, fx)
    local u, R = th.u, th.def.radius;
    local def = th.def;
    glow_k = (glow_k == true) and 0.7 or (glow_k or 0);
    tex_k = (tex_k == true) and 0.6 or (tex_k or 0);
    if (glow_k > 0) then M.draw_glow(th, w, h, glow_k); end
    -- body
    D.rectf(0, 0, w, h, u.bg2, R);
    if (h - hh > 2 * R) then D.vgrad(0, hh, w, h - R, u.bg1, u.bg2); end
    -- header (PartyramaXI: hh = 0 when the header is hidden)
    local hb = header_only and h or hh;
    if (hb > 0) then
    D.rectf(1, 1, w - 1, hb, u.hd2, R, header_only and 0 or 48);
    D.hgrad(1, R + 1, w - 1, hb - (header_only and R or 0), u.hd1, u.hd2);
    D.hgrad(1 + R, 1, w - 1 - R, R + 1, u.hd1, u.hd2);
    -- corner pieces: tinted with the local gradient colour so the rounded corners match the
    -- header (the base rect is hd2, which showed as a dark rounded square at the left end)
    do
        local s2 = R + 2;
        local f = (R * 0.5) / max(1, w - 2);
        local cl = D.lerp_col(th.src.hd1, th.src.hd2, f);
        local cr = D.lerp_col(th.src.hd1, th.src.hd2, 1 - f);
        D.rectf(1, 1, 1 + s2, 1 + s2, cl, R, 16);
        D.rectf(w - 1 - s2, 1, w - 1, 1 + s2, cr, R, 32);
        if (header_only) then
            D.hgrad(1 + R, hb - R - 1, w - 1 - R, hb, u.hd1, u.hd2);
            D.rectf(1, hb - 1 - s2, 1 + s2, hb, cl, R, 64);
            D.rectf(w - 1 - s2, hb - 1 - s2, w - 1, hb, cr, R, 128);
        end
    end
    local scene = (tex_k > 0 and fx ~= nil) and M.SCENES[fx.style] or nil;
    if (scene ~= nil and fx_ok(def.short, fx)) then
        draw_scene(fx[scene], 1, 1, w - 1, hb, max(0, R - 1), header_only and 0 or 48, tex_k, u);
    elseif (tex_k > 0) then
        local f = M.TEXTURES[def.short];
        if (f ~= nil and D.clip_push(1, 1, w - 1, hb - 1)) then
            if (fx_ok(def.short, fx)) then TILES[def.short][fx.style](u, w, hb, tex_k, fx);
            else f(u, w, hb, tex_k); end
            D.clip_pop();
        end
    end
    D.vgrad(1, 1, w - 1, min(hb, 26), u.sheen, u.clear);
    if (def.dragoon) then
        -- polished plate sheen
        D.quad(w * 0.30, 2, w * 0.42, 2, w * 0.30, hb - 1, w * 0.18, hb - 1, u.white10);
        D.quad(w * 0.45, 2, w * 0.49, 2, w * 0.37, hb - 1, w * 0.33, hb - 1, u.white10);
    end
    end
    D.rect(0, 0, w, h, u.border, R, 1.6);
    if (def.dragoon) then D.rect(3, 3, w - 3, h - 3, u.abyss_soft, max(0, R - 2), 1); end
    if (not header_only and hh > 0) then
        D.line(1, hh, w - 1, hh, u.border, 1.5);
        if (def.ornate) then
            D.line(1, hh + 3, w - 1, hh + 3, u.border_soft, 1);
            D.quad(w / 2, hh - 5, w / 2 + 6, hh + 1.5, w / 2, hh + 7, w / 2 - 6, hh + 1.5, u.border);
        end
        if (def.dragoon) then
            -- layered pauldron lames hanging from the header
            local n = max(3, floor((w - 20) / 30));
            local pw = (w - 20) / n;
            for kk = 0, n - 1 do
                local px = 10 + kk * pw;
                local dep = 6 + 3 * sin(pi * (kk + 0.5) / n);
                D.tri(px, hh, px + pw, hh, px + pw * 0.5, hh + dep, u.plate_dk);
                D.line(px, hh, px + pw * 0.5, hh + dep, u.trim_soft, 1);
                D.line(px + pw * 0.5, hh + dep, px + pw, hh, u.trim_soft, 1);
            end
            if (tex_k > 0) then
                local sc = D.mul(u.border, 0.6 * tex_k);
                local yy = hh + 16;
                while (yy < h - 6) do
                    D.circlef(5, yy, 1.5, sc, 6); D.circlef(w - 5, yy, 1.5, sc, 6);
                    yy = yy + 16;
                end
            end
        end
    end
    if (def.ornate) then
        for i = 1, 2 do local cx = (i == 1) and 6 or (w - 6); D.quad(cx, 3, cx + 3, 6, cx, 9, cx - 3, 6, u.border); end
    end
    if (def.rivets or def.dragoon) then
        local c1 = def.rivets and u.rivet or u.stud;
        for i = 1, 4 do
            local cx = (i % 2 == 1) and 7 or (w - 7);
            local cy = (i <= 2) and 7 or (h - 7);
            D.circlef(cx, cy, 2.5, c1, 8);
            D.circlef(cx - 0.6, cy - 0.8, 0.9, u.white, 6);
        end
    end
end

--[[ ---------------- bars ---------------- ]]
-- fx (optional): FX.B when bar effects are on (gloss, shine, spark, heat shift), drawn over the filled part.
function M.draw_bar(th, x0, y, x1, frac, acc, bh, fx)
    local u, def = th.u, th.def;
    bh = bh or 5;
    if (frac < 0) then frac = 0; elseif (frac > 1) then frac = 1; end
    local kind = def.bar;
    if (kind == 'gem') then
        D.rectf(x0, y, x1, y + bh, u.gem_bg, bh / 2);
        D.rect(x0, y, x1, y + bh, u.border_soft, bh / 2, 1);
        if (frac > 0) then
            local ex = x0 + 1 + (x1 - x0 - 2) * frac;
            D.vgrad(x0 + 1, y + 1, ex, y + bh - 1, u.bar_hi, u.bar_lo);
            if (fx) then FX.bar(x0 + 1, y + 1, ex, y + bh - 1, bh / 2, x1); end
        end
    elseif (kind == 'segment') then
        D.rectf(x0, y, x1, y + bh + 1, u.seg_bg, 1);
        D.rect(x0, y, x1, y + bh + 1, u.seg_rim, 1, 1);
        local n = 24;
        local sw = (x1 - x0 - 2) / n;
        local filled = floor(frac * n + 0.5);      -- segments with (i + 0.5) / n <= frac
        if (sw < 3) then
            -- v1.2.0: gaps under ~1 px are invisible: one fill instead of 24 segments
            if (filled > 0) then D.vgrad(x0 + 1, y + 1.2, x0 + 1 + filled * sw, y + bh - 0.2, u.bar_hi, u.bar_lo); end
        else
            for i = 0, filled - 1 do D.vgrad(x0 + 1 + i * sw + 0.6, y + 1.2, x0 + 1 + (i + 1) * sw - 0.6, y + bh - 0.2, u.bar_hi, u.bar_lo); end
        end
        if (fx and filled > 0) then FX.bar(x0 + 1, y + 1.2, x0 + 1 + filled * sw, y + bh - 0.2, 0, x1); end
    elseif (kind == 'pill') then
        D.rectf(x0, y, x1, y + bh + 1, u.pill_bg, (bh + 1) / 2);
        if (frac > 0) then
            local ex = x0 + max(bh, (x1 - x0) * frac);
            D.rectf(x0, y, ex, y + bh + 1, u.bar1, (bh + 1) / 2);
            D.hgrad(x0 + bh / 2, y + 1, ex - bh / 2, y + bh, u.bar1, u.bar2);
            D.circlef(ex - 1.5, y + (bh + 1) / 2, (bh + 1) / 2 + 0.5, u.pill_end, 10);
            if (fx) then FX.bar(x0 + 1, y + 1, ex - 1, y + bh, (bh + 1) / 2, x1); end
        end
    elseif (kind == 'line') then
        local cy = y + bh / 2;
        D.line(x0, cy, x1, cy, u.line_bg, 1);
        if (frac > 0) then
            local ex = x0 + (x1 - x0) * frac;
            D.line(x0, cy, ex, cy, (acc == u.acc_sp) and u.acc_sp_30 or u.acc_ab_30, 4);
            D.line(x0, cy, ex, cy, acc, 1.5);
            D.circlef(ex, cy, 2, u.white, 8);
            if (fx) then FX.bar(x0, cy - 1, ex, cy + 1, 0, x1, true); end
        end
    else -- banded (Dragoon): greave-style lames + gauntlet-tip cap
        D.rectf(x0, y, x1, y + bh + 1, u.abyss or u.bg2, 1.5);
        D.rect(x0, y, x1, y + bh + 1, u.border_half, 1.5, 1);
        if (frac > 0) then
            local ex = x0 + 1 + (x1 - x0 - 9) * frac;
            if (ex - x0 >= 2) then
                D.hgrad(x0 + 1, y + 1, ex, y + bh, (acc == u.acc_sp) and u.acc_sp_55 or u.acc_ab_55, acc);
                -- v1.2.0: sub-details only where they are visible (bar 3+ px tall), and at most
                -- ~12 lames per bar (spacing grows on wide bars instead of 20+ thin lines)
                if (bh >= 3) then
                    D.line(x0 + 2, y + 1.6, ex, y + 1.6, u.band_hi, 1);
                    local step = max(10, (x1 - x0) / 12);
                    local bx = x0 + step;
                    local c = u.plate_dk_soft or u.bg2;
                    while (bx < ex - 2) do D.line(bx, y + 1, bx, y + bh, c, 1); bx = bx + step; end
                end
            end
            if (fx) then FX.bar(x0 + 1, y + 1, ex, y + bh, 0, x1); end
            D.quad(ex - 1, y - 1.5, ex + 6, y + (bh + 1) / 2, ex - 1, y + bh + 2.5, ex + 1.5, y + (bh + 1) / 2, u.border);
        end
    end
end

return M;
