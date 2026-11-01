--[[
* RecastXI - rxdraw.lua
* Draw-list helpers in WINDOW-LOCAL coordinates. The origin is captured right after Begin as
*   GetCursorScreenPos() - GetCursorPos()   (window padding is pushed to 0 for the main window)
* and never from GetWindowPos/GetWindowSize (those misbehaved under dgVoodoo).
* All ImVec2 arguments use preallocated tables, so drawing allocates nothing per frame.
*
* Safety guard (v1.1.2): every primitive is checked against the window rect (window-local bounds
* set right after Begin, plus SLACK px). Anything outside it, or with a NaN/inf coordinate, is
* skipped and counted (M.skipped). Clip rects are always intersected with the current one and
* clamped to the same bounds. Under Ashita's Direct3D 8 renderer a clip rect is applied as a
* viewport + projection; a clip rect the back buffer can't hold is rejected by D3D8 and the
* projection then stretches that draw command across the whole screen (the 1.1.0/1.1.1 bug).
--]]

local M = {};
local floor, sin, cos, pi, min, max = math.floor, math.sin, math.cos, math.pi, math.min, math.max;

M.dl, M.ox, M.oy, M.alpha = nil, 0, 0, 1;
local A, B, C, D = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 };
local UV0, UV1 = { 0, 0 }, { 1, 1 };
M.calls = 0;
M.SLACK = 2;
local HUGE = 1e6;
M.bx0, M.by0, M.bx1, M.by1 = -HUGE, -HUGE, HUGE, HUGE;
M.skipped, M.skipped_total, M.clips = 0, 0, 0;
M.no_clip = false;   -- /rxi safe: no custom clip rects at all

-- ImGui packs colors as ABGR in a u32.
function M.rgba(r, g, b, a)
    a = a or 255;
    return floor(a + 0.5) * 16777216 + floor(b + 0.5) * 65536 + floor(g + 0.5) * 256 + floor(r + 0.5);
end
function M.col(t, a) return M.rgba(t[1], t[2], t[3], a or t[4] or 255); end
-- Multiplies the alpha of a u32 color by k (and the global window alpha).
function M.fade(c, k)
    local a = floor(c / 16777216);
    local rgb = c - a * 16777216;
    a = floor(a * k * M.alpha + 0.5);
    if (a > 255) then a = 255; elseif (a < 0) then a = 0; end
    return a * 16777216 + rgb;
end
local fade = M.fade;
-- Same as fade but without the window alpha (for colors precomputed outside a frame).
function M.mul(c, k)
    local a = floor(c / 16777216);
    local rgb = c - a * 16777216;
    a = floor(a * k + 0.5);
    if (a > 255) then a = 255; elseif (a < 0) then a = 0; end
    return a * 16777216 + rgb;
end
function M.lerp_rgb(c1, c2, t)   -- tables {r,g,b} -> table (theme setup only)
    return { c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t };
end
function M.lerp_col(c1, c2, t)   -- tables {r,g,b}
    return M.rgba(c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t, 255);
end

-- bx0..by1: the window rect in window-local coordinates (omit = unbounded, offline tools only).
function M.begin(dl, ox, oy, alpha, bx0, by0, bx1, by1)
    M.dl, M.ox, M.oy, M.alpha = dl, ox, oy, alpha or 1;
    local sl = M.SLACK;
    if (bx0 ~= nil) then M.bx0, M.by0, M.bx1, M.by1 = bx0 - sl, by0 - sl, bx1 + sl, by1 + sl;
    else M.bx0, M.by0, M.bx1, M.by1 = -HUGE, -HUGE, HUGE, HUGE; end
    M.skipped, M.clips = 0, 0;
end
-- true when both points lie inside the window bounds (NaN fails every comparison -> skipped;
-- raw coordinates on purpose: math.min/max would silently drop a NaN)
local function inb(x0, y0, x1, y1)
    local a, b, c, e = M.bx0, M.by0, M.bx1, M.by1;
    if (x0 >= a and x0 <= c and x1 >= a and x1 <= c and y0 >= b and y0 <= e and y1 >= b and y1 <= e) then return true; end
    M.skipped = M.skipped + 1; M.skipped_total = M.skipped_total + 1;
    local L = M.last_skip; L[1], L[2], L[3], L[4] = x0, y0, x1, y1;   -- for /rxi debug rect
    return false;
end
M.inb = inb;
M.last_skip = { 0, 0, 0, 0 };
local function P(v, x, y) v[1], v[2] = M.ox + x, M.oy + y; return v; end
M.P = P;

function M.rectf(x0, y0, x1, y1, c, r, flags)
    local dl = M.dl; if (dl == nil or not inb(x0, y0, x1, y1)) then return; end
    dl:AddRectFilled(P(A, x0, y0), P(B, x1, y1), fade(c, 1), r or 0, flags or 0);
end
function M.rect(x0, y0, x1, y1, c, r, th, flags)
    local dl = M.dl; if (dl == nil or not inb(x0, y0, x1, y1)) then return; end
    dl:AddRect(P(A, x0, y0), P(B, x1, y1), fade(c, 1), r or 0, flags or 0, th or 1);
end
-- Gradient: c_tl, c_tr, c_br, c_bl (u32). Square corners (ImGui limitation).
function M.grad(x0, y0, x1, y1, ctl, ctr, cbr, cbl)
    local dl = M.dl; if (dl == nil or x1 <= x0 or y1 <= y0 or not inb(x0, y0, x1, y1)) then return; end
    dl:AddRectFilledMultiColor(P(A, x0, y0), P(B, x1, y1), fade(ctl, 1), fade(ctr, 1), fade(cbr, 1), fade(cbl, 1));
end
function M.hgrad(x0, y0, x1, y1, cl, cr) M.grad(x0, y0, x1, y1, cl, cr, cr, cl); end
function M.vgrad(x0, y0, x1, y1, ct, cb) M.grad(x0, y0, x1, y1, ct, ct, cb, cb); end
function M.line(x0, y0, x1, y1, c, th)
    local dl = M.dl; if (dl == nil or not inb(x0, y0, x1, y1)) then return; end
    dl:AddLine(P(A, x0, y0), P(B, x1, y1), fade(c, 1), th or 1);
end
-- Line clipped to a rect first (Liang-Barsky), for patterns whose lines run past an edge.
function M.seg(x0, y0, x1, y1, c, th, rx0, ry0, rx1, ry1)
    local dx, dy = x1 - x0, y1 - y0;
    local t0, t1 = 0, 1;
    local p1, q1, p2, q2, p3, q3, p4, q4 = -dx, x0 - rx0, dx, rx1 - x0, -dy, y0 - ry0, dy, ry1 - y0;
    -- unrolled so nothing is allocated
    if (p1 == 0) then if (q1 < 0) then return; end else local r = q1 / p1; if (p1 < 0) then if (r > t1) then return; elseif (r > t0) then t0 = r; end else if (r < t0) then return; elseif (r < t1) then t1 = r; end end end
    if (p2 == 0) then if (q2 < 0) then return; end else local r = q2 / p2; if (p2 < 0) then if (r > t1) then return; elseif (r > t0) then t0 = r; end else if (r < t0) then return; elseif (r < t1) then t1 = r; end end end
    if (p3 == 0) then if (q3 < 0) then return; end else local r = q3 / p3; if (p3 < 0) then if (r > t1) then return; elseif (r > t0) then t0 = r; end else if (r < t0) then return; elseif (r < t1) then t1 = r; end end end
    if (p4 == 0) then if (q4 < 0) then return; end else local r = q4 / p4; if (p4 < 0) then if (r > t1) then return; elseif (r > t0) then t0 = r; end else if (r < t0) then return; elseif (r < t1) then t1 = r; end end end
    M.line(x0 + dx * t0, y0 + dy * t0, x0 + dx * t1, y0 + dy * t1, c, th);
end
function M.tri(x0, y0, x1, y1, x2, y2, c)
    local dl = M.dl; if (dl == nil or not inb(x0, y0, x1, y1) or not inb(x2, y2, x2, y2)) then return; end
    dl:AddTriangleFilled(P(A, x0, y0), P(B, x1, y1), P(C, x2, y2), fade(c, 1));
end
function M.quad(x0, y0, x1, y1, x2, y2, x3, y3, c)
    M.tri(x0, y0, x1, y1, x2, y2, c); M.tri(x0, y0, x2, y2, x3, y3, c);
end
function M.circlef(cx, cy, r, c, seg)
    local dl = M.dl; if (dl == nil or not inb(cx - r, cy - r, cx + r, cy + r)) then return; end
    dl:AddCircleFilled(P(A, cx, cy), r, fade(c, 1), seg or 0);
end
function M.circle(cx, cy, r, c, seg, th)
    local dl = M.dl; if (dl == nil or not inb(cx - r, cy - r, cx + r, cy + r)) then return; end
    dl:AddCircle(P(A, cx, cy), r, fade(c, 1), seg or 0, th or 1);
end
function M.text(x, y, c, s)
    local dl = M.dl; if (dl == nil or s == nil or not inb(x, y, x, y)) then return; end
    dl:AddText(P(A, x, y), fade(c, 1), s);
end
-- Pie (remaining fraction from 12 o'clock, clockwise) as a triangle fan.
function M.pie(cx, cy, r, frac, c, seg)
    if (frac <= 0) then return; end
    if (frac >= 0.999) then M.circlef(cx, cy, r, c, seg or 24); return; end
    seg = seg or 24;
    local n = max(1, floor(seg * frac + 0.5));
    local a0 = -pi / 2;
    local step = (2 * pi * frac) / n;
    local px, py = cx + r * cos(a0), cy + r * sin(a0);
    for i = 1, n do
        local a = a0 + step * i;
        local nx, ny = cx + r * cos(a), cy + r * sin(a);
        M.tri(cx, cy, px, py, nx, ny, c);
        px, py = nx, ny;
    end
end
-- Star polygon (filled, as a triangle fan from the center).
function M.star(cx, cy, R, r, c, n, rot)
    n, rot = n or 5, rot or -pi / 2;
    local step = pi / n;
    local px, py = cx + R * cos(rot), cy + R * sin(rot);
    for i = 1, 2 * n do
        local rad = (i % 2 == 0) and R or r;
        local a = rot + step * i;
        local nx, ny = cx + rad * cos(a), cy + rad * sin(a);
        M.tri(cx, cy, px, py, nx, ny, c);
        px, py = nx, ny;
    end
end
-- Convex polygon fan from a flat coordinate list {x1,y1,x2,y2,...} (preallocated by the caller).
function M.poly(pts, n, c, ox, oy, s)
    ox, oy, s = ox or 0, oy or 0, s or 1;
    local x0, y0 = ox + pts[1] * s, oy + pts[2] * s;
    for i = 2, n - 1 do
        M.tri(x0, y0, ox + pts[2 * i - 1] * s, oy + pts[2 * i] * s, ox + pts[2 * i + 1] * s, oy + pts[2 * i + 2] * s, c);
    end
end
function M.polyline(pts, n, c, th, ox, oy, s, closed)
    ox, oy, s = ox or 0, oy or 0, s or 1;
    for i = 1, n - 1 do
        M.line(ox + pts[2 * i - 1] * s, oy + pts[2 * i] * s, ox + pts[2 * i + 1] * s, oy + pts[2 * i + 2] * s, c, th);
    end
    if (closed) then M.line(ox + pts[2 * n - 1] * s, oy + pts[2 * n] * s, ox + pts[1] * s, oy + pts[2] * s, c, th); end
end
-- Image with optional rounding (circle mask = rounding of half the size). Falls back to AddImage.
function M.image(tex, x0, y0, x1, y1, rounding)
    local dl = M.dl; if (dl == nil or tex == nil or not inb(x0, y0, x1, y1)) then return false; end
    local white = fade(0xFFFFFFFF, 1);
    if (rounding ~= nil and rounding > 0 and dl.AddImageRounded ~= nil) then
        local ok = pcall(dl.AddImageRounded, dl, tex, P(A, x0, y0), P(B, x1, y1), UV0, UV1, white, rounding, 0);
        if (ok) then return true; end
    end
    local ok = pcall(dl.AddImage, dl, tex, P(A, x0, y0), P(B, x1, y1), UV0, UV1, white);
    return ok;
end
-- Image with explicit UVs and a tint color (u32). No window-bounds check on purpose: the caller has
-- pushed a clip rect that lies inside the window, so only the visible part is drawn.
local UVA, UVB = { 0, 0 }, { 1, 1 };
function M.image_uv(tex, x0, y0, x1, y1, u0, v0, u1, v1, c)
    local dl = M.dl; if (dl == nil or tex == nil) then return false; end
    UVA[1], UVA[2], UVB[1], UVB[2] = u0, v0, u1, v1;
    return (pcall(dl.AddImage, dl, tex, P(A, x0, y0), P(B, x1, y1), UVA, UVB, fade(c, 1)));
end
-- Image with explicit UVs, a tint and rounded corners (flags: 0 = all corners, 48 = top two, ...).
-- Falls back to a square image when AddImageRounded is missing.
function M.image_uv_round(tex, x0, y0, x1, y1, u0, v0, u1, v1, c, rounding, flags)
    local dl = M.dl; if (dl == nil or tex == nil) then return false; end
    UVA[1], UVA[2], UVB[1], UVB[2] = u0, v0, u1, v1;
    if (rounding ~= nil and rounding > 0 and dl.AddImageRounded ~= nil) then
        if (pcall(dl.AddImageRounded, dl, tex, P(A, x0, y0), P(B, x1, y1), UVA, UVB, fade(c, 1), rounding, flags or 0)) then return true; end
    end
    return (pcall(dl.AddImage, dl, tex, P(A, x0, y0), P(B, x1, y1), UVA, UVB, fade(c, 1)));
end
-- Always intersected with the current clip rect (the window's own) and clamped to the window
-- bounds, so a clip rect can never reach outside the window. `intersect` is ignored (v1.1.2:
-- intersect=false was the full-screen stretch bug). Returns false when nothing was pushed.
function M.clip_push(x0, y0, x1, y1, _intersect)
    local dl = M.dl; if (dl == nil or dl.PushClipRect == nil or M.no_clip) then return false; end
    if (x0 < M.bx0) then x0 = M.bx0; end
    if (y0 < M.by0) then y0 = M.by0; end
    if (x1 > M.bx1) then x1 = M.bx1; end
    if (y1 > M.by1) then y1 = M.by1; end
    if (not (x1 > x0 and y1 > y0)) then return false; end   -- empty or NaN
    dl:PushClipRect(P(A, x0, y0), P(B, x1, y1), true);
    M.clips = M.clips + 1;
    return true;
end
function M.clip_pop() local dl = M.dl; if (dl ~= nil and dl.PopClipRect ~= nil and not M.no_clip) then dl:PopClipRect(); end end

return M;
