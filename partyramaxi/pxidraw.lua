--[[
* PartyramaXI - arrow shapes and the optional party list.
* Shapes are built in a local frame where the arrow points down (+y) with its tip at 0,0,
* then rotated (down / right) and moved into place. All point tables are preallocated.
--]]
local M = {}

M.STYLES = { 'triangle', 'chevron', 'crystal' }
M.WHITE = { 1, 1, 1, 1 }
M.STYLE_LABELS = { triangle = 'Triangle', chevron = 'Chevron', crystal = 'Rotating crystal' }

local P = {}
for i = 1, 6 do P[i] = { 0, 0 } end
local R1, R2 = { 0, 0 }, { 0, 0 }
local RX = { [0] = 0, 0, 0, 0 }
local ox, oy, rot = 0, 0, false

local function pt(i, lx, ly)
    local p = P[i]
    if rot then p[1], p[2] = ox + ly, oy - lx else p[1], p[2] = ox + lx, oy + ly end
    return p
end

-- Multiply the red / green / blue of a color by k (clamped), set its alpha.
local function shade_u32(r, g, b, a, k)
    local function f(v) v = math.floor(v * k + 0.5); if v > 255 then v = 255 elseif v < 0 then v = 0 end; return v end
    return a * 16777216 + f(b) * 65536 + f(g) * 256 + f(r)
end

-- Axis-aligned local rect -> screen rect (still axis aligned after a 90 degree turn).
local function rect(x1, y1, x2, y2)
    local a, b = pt(5, x1, y1), pt(6, x2, y2)
    R1[1], R1[2] = math.min(a[1], b[1]), math.min(a[2], b[2])
    R2[1], R2[2] = math.max(a[1], b[1]), math.max(a[2], b[2])
end

-- ImGui colors are 0xAABBGGRR. c = { r, g, b, a } in 0..1, mul scales alpha.
-- 2.9.1: called for every rectangle and text each frame, so numbers skip tonumber and the ends skip floor
local floor = math.floor
local function ch(v)
    if type(v) ~= 'number' then v = tonumber(v) or 0 end
    if v <= 0 then return 0 elseif v >= 1 then return 255 end
    return floor(v * 255 + 0.5)
end
function M.u32(c, mul)
    local a = c[4]
    if a == nil then a = 1 elseif type(a) ~= 'number' then a = tonumber(a) or 1 end
    if mul ~= nil then a = a * mul end
    return ch(a) * 16777216 + ch(c[3]) * 65536 + ch(c[2]) * 256 + ch(c[1])
end

function M.anim(st, now)
    local bob, alpha = 0, 1
    local f = (tonumber(st.anim_speed) or 1.5) * 2 * math.pi
    if st.bob then bob = (tonumber(st.bob_amount) or 6) * (0.5 + 0.5 * math.sin(now * f)) end
    if st.pulse then alpha = 0.7 + 0.3 * math.sin(now * f + 1.3) end
    return bob, alpha
end

--[[
* dl: ImDrawList. x, y: where the tip points. dir: 'down' | 'right'. size in pixels.
* fill / line: 0xAABBGGRR colors (line = 0 for no outline). thick: outline width.
--]]
function M.arrow(dl, style, x, y, dir, size, fill, line, thick, now)
    ox, oy, rot = x, y, dir == 'right'
    local w, h = size, size * 0.9
    if style == 'chevron' then
        local t = size * 0.3
        local a1, a2, a3, a4 = pt(1, 0, 0), pt(2, -w / 2, -h), pt(3, -w / 2 + t, -h), pt(4, 0, -t * 1.6)
        dl:AddQuadFilled(a1, a2, a3, a4, fill)
        if line ~= 0 then dl:AddQuad(a1, a2, a3, a4, line, thick) end
        a1, a2, a3, a4 = pt(1, 0, 0), pt(2, 0, -t * 1.6), pt(3, w / 2 - t, -h), pt(4, w / 2, -h)
        dl:AddQuadFilled(a1, a2, a3, a4, fill)
        if line ~= 0 then dl:AddQuad(a1, a2, a3, a4, line, thick) end
    elseif style == 'crystal' then
        -- A crystal (octahedron) turning about its upright axis, tip down on the point.
        local ch_, cw = size * 1.15, size * 0.38
        local ang = (tonumber(now) or 0) * 2.2
        local a0 = math.floor(fill / 16777216) % 256
        local cr, cg, cb = fill % 256, math.floor(fill / 256) % 256, math.floor(fill / 65536) % 256
        local function shade(k) return shade_u32(cr, cg, cb, a0, k) end
        local top, bot = pt(1, 0, -ch_), pt(2, 0, 0)
        for k = 0, 3 do RX[k] = math.sin(ang + k * math.pi / 2) * cw end
        for k = 0, 3 do
            local k2 = (k + 1) % 4
            local mid = ang + k * math.pi / 2 + math.pi / 4
            if math.cos(mid) > 0 then
                local lit = 0.55 + 0.45 * math.cos(mid - 0.7)
                local p3, p4 = pt(3, RX[k], -ch_ * 0.5), pt(4, RX[k2], -ch_ * 0.5)
                dl:AddTriangleFilled(top, p3, p4, shade(lit * 1.15))
                dl:AddTriangleFilled(bot, p3, p4, shade(lit * 0.7))
                if line ~= 0 then
                    dl:AddTriangle(top, p3, p4, line, thick); dl:AddTriangle(bot, p3, p4, line, thick)
                end
            end
        end
        -- a small bright glint that drifts with the turn
        local gx = math.sin(ang * 1.0) * cw * 0.35
        local gp = pt(5, gx, -ch_ * 0.62)
        dl:AddCircleFilled(gp, math.max(1, size * 0.06), shade_u32(255, 255, 255, math.floor(a0 * 0.8), 1), 8)
    else
        local a1, a2, a3 = pt(1, 0, 0), pt(2, -w / 2, -h), pt(3, w / 2, -h)
        dl:AddTriangleFilled(a1, a2, a3, fill)
        if line ~= 0 then dl:AddTriangle(a1, a2, a3, line, thick) end
    end
end


--[[ Sheen: a soft diagonal band of light sweeping across the arrow, clipped to its shape (convex pieces, clipped in the
  local frame). p = 0..1 progress of the sweep, strength = peak white alpha. Built-in shapes only. All buffers are
  preallocated; nothing is allocated per call. ]]
local CA, CB = {}, {}
for i = 1, 12 do CA[i] = { 0, 0 }; CB[i] = { 0, 0 } end
local SH = { n = 0 }
local CLIP = { tri = { { 0, 0 }, { 0, 0 }, { 0, 0 } }, q1 = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }, q2 = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } } }
local function setp(t, i, x, y) t[i][1], t[i][2] = x, y end
-- clip polygon src (n points) by the half plane left of edge a->b (for a counter-clockwise shape); returns new count
local function clip_edge(src, n, dst, ax, ay, bx, by)
    local m = 0
    local ex, ey = bx - ax, by - ay
    local function side(p) return ex * (p[2] - ay) - ey * (p[1] - ax) end
    for i = 1, n do
        local p, q = src[i], src[i % n + 1]
        local sp, sq = side(p), side(q)
        if sp >= 0 then m = m + 1; dst[m][1], dst[m][2] = p[1], p[2] end
        if (sp >= 0) ~= (sq >= 0) and m < 12 then
            local t = sp / (sp - sq)
            m = m + 1; dst[m][1], dst[m][2] = p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t
        end
    end
    return m
end
-- band (local x from bx0 to bx1 at the top, slanted) clipped by convex shape `shape` (k points), drawn as a fan
local function band_in(dl, shape, k, bx0, bx1, top, slant, col)
    setp(CA, 1, bx0, top); setp(CA, 2, bx1, top); setp(CA, 3, bx1 + slant, 0); setp(CA, 4, bx0 + slant, 0)
    local n, src, dst = 4, CA, CB
    -- orientation-independent: clip by each edge, choosing the inner side from the shape's centroid
    local cx, cy = 0, 0
    for i = 1, k do cx, cy = cx + shape[i][1], cy + shape[i][2] end
    cx, cy = cx / k, cy / k
    for i = 1, k do
        local a, b = shape[i], shape[i % k + 1]
        local ax, ay, bx, by = a[1], a[2], b[1], b[2]
        if (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) < 0 then ax, ay, bx, by = bx, by, ax, ay end
        n = clip_edge(src, n, dst, ax, ay, bx, by)
        src, dst = dst, src
        if n < 3 then return end
    end
    local p1 = pt(1, src[1][1], src[1][2])
    local x1, y1 = p1[1], p1[2]
    for i = 2, n - 1 do
        local a = pt(2, src[i][1], src[i][2])
        local b = pt(3, src[i + 1][1], src[i + 1][2])
        local f = P[1]; f[1], f[2] = x1, y1
        dl:AddTriangleFilled(f, a, b, col)
    end
end
function M.sheen(dl, style, x, y, dir, size, p, strength, now)
    if p <= 0 or p >= 1 or style == nil or style:sub(1, 4) == 'png:' then return end
    ox, oy, rot = x, y, dir == 'right'
    local w, h = size, size * 0.9
    local k1, k2, shape1, shape2 = 3, 0, CLIP.tri, nil
    if style == 'chevron' then
        local t = size * 0.3
        local q1, q2 = CLIP.q1, CLIP.q2
        setp(q1, 1, 0, 0); setp(q1, 2, -w / 2, -h); setp(q1, 3, -w / 2 + t, -h); setp(q1, 4, 0, -t * 1.6)
        setp(q2, 1, 0, 0); setp(q2, 2, 0, -t * 1.6); setp(q2, 3, w / 2 - t, -h); setp(q2, 4, w / 2, -h)
        shape1, k1, shape2, k2 = q1, 4, q2, 4
    elseif style == 'square' then                -- a status icon: x, y = the middle of its bottom edge
        h = size
        local q1 = CLIP.q1
        setp(q1, 1, -w / 2, -h); setp(q1, 2, w / 2, -h); setp(q1, 3, w / 2, 0); setp(q1, 4, -w / 2, 0)
        shape1, k1 = q1, 4
    elseif style == 'crystal' then
        h = size * 1.15
        local q1 = CLIP.q1
        -- the turning crystal's outline right now (same angle as M.arrow)
        local ang, hw = (tonumber(now) or 0) * 2.2, 0
        for k = 0, 3 do hw = math.max(hw, math.abs(math.sin(ang + k * math.pi / 2))) end
        hw = hw * size * 0.38
        setp(q1, 1, 0, -h); setp(q1, 2, -hw, -h * 0.5); setp(q1, 3, 0, 0); setp(q1, 4, hw, -h * 0.5)
        shape1, k1 = q1, 4
        w = hw * 2
    else
        local tri = CLIP.tri
        setp(tri, 1, 0, 0); setp(tri, 2, -w / 2, -h); setp(tri, 3, w / 2, -h)
    end
    -- the band travels from beyond the left edge to beyond the right edge, leaning like the bar sheen
    local slant = -math.min(h, w) * 0.45      -- the band's bottom sits this much further right (-slant) than its top
    local bw = w * 0.22
    local k = -slant
    local s0, s1 = -w / 2 - bw - k, w / 2 + bw   -- top x where the band is fully left / fully right of the shape
    local s = s0 + (s1 - s0) * p
    local a = math.min(1, math.max(0, strength or 0.5)) * math.sin(p * math.pi)
    local soft, core = M.u32(M.WHITE, a * 0.45), M.u32(M.WHITE, a)
    for pass = 1, 2 do
        local x0, x1 = s - bw, s + bw
        local col = soft
        if pass == 2 then x0, x1, col = s - bw * 0.35, s + bw * 0.35, core end
        band_in(dl, shape1, k1, x0, x1, -h, -slant, col)
        if shape2 ~= nil then band_in(dl, shape2, k2, x0, x1, -h, -slant, col) end
    end
end

-- The same sweep over a picture, masked to its visible pixels: wht = a white copy of the picture (alpha kept, see
-- pxipng silhouette), drawn only inside the band, at x0, y0 with size px. The band is clipped to the square and drawn
-- as a fan of textured triangles whose UVs follow their screen position, so only opaque pixels light up.
local SQ = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
local IP = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
local IU = { { 0, 0 }, { 0, 0 }, { 0, 0 } }
function M.sheen_image(dl, wht, x0, y0, size, p, strength)
    if p <= 0 or p >= 1 or wht == nil then return end
    local w, h = size, size
    local slant = -size * 0.45
    local bw = w * 0.22
    local k = -slant
    local s0, s1 = -bw - k, w + bw
    local s = s0 + (s1 - s0) * p
    local a = math.min(1, math.max(0, strength or 0.5)) * math.sin(p * math.pi)
    setp(SQ, 1, 0, 0); setp(SQ, 2, w, 0); setp(SQ, 3, w, h); setp(SQ, 4, 0, h)
    for pass = 1, 2 do
        local bx0, bx1, al = s - bw, s + bw, a * 0.45
        if pass == 2 then bx0, bx1, al = s - bw * 0.35, s + bw * 0.35, a end
        -- the band (top edge at y = 0, leaning by -slant at the bottom), clipped to the square
        setp(CA, 1, bx0, 0); setp(CA, 2, bx1, 0); setp(CA, 3, bx1 + k, h); setp(CA, 4, bx0 + k, h)
        local n, src, dst = 4, CA, CB
        for i = 1, 4 do
            local pa, pb = SQ[i], SQ[i % 4 + 1]
            n = clip_edge(src, n, dst, pa[1], pa[2], pb[1], pb[2])
            src, dst = dst, src
            if n < 3 then break end
        end
        if n >= 3 then
            local col = M.u32(M.WHITE, al)
            for i = 2, n - 1 do
                local q1, q2, q3 = src[1], src[i], src[i + 1]
                IP[1][1], IP[1][2], IU[1][1], IU[1][2] = x0 + q1[1], y0 + q1[2], q1[1] / w, q1[2] / h
                IP[2][1], IP[2][2], IU[2][1], IU[2][2] = x0 + q2[1], y0 + q2[2], q2[1] / w, q2[2] / h
                IP[3][1], IP[3][2], IU[3][1], IU[3][2] = x0 + q3[1], y0 + q3[2], q3[1] / w, q3[2] / h
                dl:AddImageQuad(wht, IP[1], IP[2], IP[3], IP[3], IU[1], IU[2], IU[3], IU[3], col)
            end
        end
    end
end

-- PNG arrow. The image is drawn pointing down by default (its bottom edge centre at the tip).
-- rotation (0/90/180/270, clockwise) turns the picture first, for images drawn another way.
local UV = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
local Q = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
function M.image(dl, tex_id, x, y, dir, size, img_w, img_h, rotation, col)
    ox, oy, rot = x, y, dir == 'right'
    local r = math.floor(((tonumber(rotation) or 0) % 360) / 90 + 0.5) % 4
    local iw, ih = tonumber(img_w) or 64, tonumber(img_h) or 64
    if r % 2 == 1 then iw, ih = ih, iw end
    if ih <= 0 then ih = 1 end
    local h = size
    local w = size * iw / ih
    -- screen corners of the box (local frame: TL, TR, BR, BL; the tip is the bottom centre)
    local a, b, c, d = pt(1, -w / 2, -h), pt(2, w / 2, -h), pt(3, w / 2, 0), pt(4, -w / 2, 0)
    Q[1][1], Q[1][2] = a[1], a[2]; Q[2][1], Q[2][2] = b[1], b[2]
    Q[3][1], Q[3][2] = c[1], c[2]; Q[4][1], Q[4][2] = d[1], d[2]
    -- turning the picture clockwise by r quarters = taking the UVs from r corners further back
    dl:AddImageQuad(tex_id, Q[1], Q[2], Q[3], Q[4],
        UV[(0 - r) % 4 + 1], UV[(1 - r) % 4 + 1], UV[(2 - r) % 4 + 1], UV[(3 - r) % 4 + 1], col)
end

---------------------------------------------------------------------------
-- Settings highlight: while a setting is hovered in the settings window, HL names the screen element it changes
-- (mod = 'arrow' | 'info' | 'list', el = element key, '*' = the whole module). Each renderer reports where it drew
-- that element with hl_rect; the boxes are joined into one and framed at the end of the frame. No allocation.
---------------------------------------------------------------------------
M.HL = { mod = nil, el = nil, t = -10 }
M.HLR = { x0 = 0, y0 = 0, x1 = 0, y1 = 0, n = 0 }
-- 2.9.5: the main target's info box as drawn (all its layers), with the glide it was drawn with; on = recording
-- 2.10.0: rects the target bar must not cover (the addon's windows, pointer arrows): OB this frame, OBP last frame
M.OB, M.OBP = { n = 0 }, { n = 0 }
function M.obst(x0, y0, x1, y1)
    x0, y0, x1, y1 = tonumber(x0), tonumber(y0), tonumber(x1), tonumber(y1)
    if not (x0 and y0 and x1 and y1) or x1 <= x0 or y1 <= y0 then return end
    local O = M.OB
    local i = O.n * 4
    O[i + 1], O[i + 2], O[i + 3], O[i + 4] = x0, y0, x1, y1
    O.n = O.n + 1
end
function M.obst_swap() M.OB, M.OBP = M.OBP, M.OB; M.OB.n = 0 end
M.IB = { x0 = 0, y0 = 0, x1 = 0, y1 = 0, n = 0, gx = 0, gy = 0, on = false }
local HL_A, HL_B, HL_COL = { 0, 0 }, { 0, 0 }, { 1.00, 0.78, 0.20, 1 }

function M.hl_on(mod) return M.HL.mod == mod end
function M.hl_set(mod, el, now) local H = M.HL; H.mod, H.el, H.t = mod, el, now end
function M.hl_rect(mod, el, x0, y0, x1, y1)
    local B = M.IB
    if B.on and mod == 'info' and x0 ~= nil and x1 ~= nil and x0 <= x1 then
        if B.n == 0 then B.x0, B.y0, B.x1, B.y1 = x0, y0, x1, y1
        else
            if x0 < B.x0 then B.x0 = x0 end
            if y0 < B.y0 then B.y0 = y0 end
            if x1 > B.x1 then B.x1 = x1 end
            if y1 > B.y1 then B.y1 = y1 end
        end
        B.n = B.n + 1
    end
    local H = M.HL
    if H.mod ~= mod or (H.el ~= el and H.el ~= '*') then return end
    local R = M.HLR
    if R.n == 0 then R.x0, R.y0, R.x1, R.y1 = x0, y0, x1, y1
    else
        if x0 < R.x0 then R.x0 = x0 end
        if y0 < R.y0 then R.y0 = y0 end
        if x1 > R.x1 then R.x1 = x1 end
        if y1 > R.y1 then R.y1 = y1 end
    end
    R.n = R.n + 1
end
-- Start of a frame: forget last frame's box, and the element once the mouse has left its setting.
function M.hl_begin(now)
    M.HLR.n = 0
    if M.HL.mod ~= nil and now - M.HL.t > 0.15 then M.HL.mod, M.HL.el = nil, nil end
end
-- End of a frame: a pulsing amber frame around everything reported.
function M.hl_draw(dl, now)
    local R = M.HLR
    if R.n == 0 or M.HL.mod == nil then return end
    HL_A[1], HL_A[2] = R.x0 - 4, R.y0 - 4
    HL_B[1], HL_B[2] = R.x1 + 4, R.y1 + 4
    local a = 0.65 + 0.35 * math.sin(now * 8)
    dl:AddRect(HL_A, HL_B, M.u32(HL_COL, a), 3, 0, 2)
end

return M
