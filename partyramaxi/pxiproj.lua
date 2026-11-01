--[[
* PartyramaXI - turning game positions into screen positions.
*
* Two independent sources, so one can back up the other:
*  1. Projection: the entity's world position run through the Direct3D view and projection
*     matrices (read from the device with preallocated buffers, so nothing is allocated per frame).
*  2. Native: the screen position the game itself computed for its arrows, stored in the target
*     window object (Ashita SDK ffxi/target.h, targetwindow_t: m_AnkX/m_AnkY at +0xBC/+0xBE,
*     m_SubAnkX/m_SubAnkY at +0xC0/+0xC2). Those are in the game's menu resolution, so they are
*     scaled to the window resolution (CYmdb object, same scan Ashita's libs/scaling.lua uses).
--]]
local M = {}

M.D3DTS_VIEW, M.D3DTS_PROJECTION = 2, 3
M.OFF_ANK_X, M.OFF_ANK_Y, M.OFF_SUB_X, M.OFF_SUB_Y = 0xBC, 0xBE, 0xC0, 0xC2
M.SIG_YMDB = 'A1????????85C05E74????80'

-- Row-vector (Direct3D) world -> screen. m = view, p = projection (fields _11.._44),
-- vp = { X, Y, Width, Height }. Writes out.x/out.y/out.depth; returns false when behind the camera.
function M.project(v, p, vp, x, y, z, out)
    local vx = x * v._11 + y * v._21 + z * v._31 + v._41
    local vy = x * v._12 + y * v._22 + z * v._32 + v._42
    local vz = x * v._13 + y * v._23 + z * v._33 + v._43
    local vw = x * v._14 + y * v._24 + z * v._34 + v._44
    local cx = vx * p._11 + vy * p._21 + vz * p._31 + vw * p._41
    local cy = vx * p._12 + vy * p._22 + vz * p._32 + vw * p._42
    local cw = vx * p._14 + vy * p._24 + vz * p._34 + vw * p._44
    if cw <= 0.05 then return false end
    out.x = vp.X + (cx / cw + 1) * 0.5 * vp.Width
    out.y = vp.Y + (1 - cy / cw) * 0.5 * vp.Height
    out.depth = cw
    return true
end

-- A perspective projection has _44 = 0 and a non-zero _34 (+1 left-handed, -1 right-handed, or scaled); an
-- orthographic one (the UI's) has _34 = 0 and _44 = 1.
function M.is_perspective(p)
    return p ~= nil and math.abs(p._34) > 0.01 and math.abs(p._44) < 0.01 and math.abs(p._11) > 1e-4
end

--[[ Device-backed camera. dev_fn() returns the IDirect3DDevice8 (Ashita's d3d8.get_device).

  The device only holds the 3D camera while the game draws the world. By d3d_present something has usually set a
  flat UI projection (in game, 1.9.5 read "camera matrix not available" on every frame), so capture() is called at
  several points of the frame (tag = 'beginscene' / 'endscene' / 'present'). A read that is not a perspective camera
  never overwrites the last good one; cam.ok says whether a good one is recent (cam.MAX_AGE frames). ]]
local FIELDS = { '_11', '_12', '_13', '_14', '_21', '_22', '_23', '_24',
                 '_31', '_32', '_33', '_34', '_41', '_42', '_43', '_44' }

function M.camera(ffi, dev_fn)
    local cam = {
        ok = false, why = 'not read yet',
        view = ffi.new('D3DMATRIX[1]'), proj = ffi.new('D3DMATRIX[1]'),
        vpbuf = ffi.new('D3DVIEWPORT8[1]'),
        vp = { X = 0, Y = 0, Width = 0, Height = 0 },
        v = {}, p = {},      -- plain Lua copies, so the math below never creates cdata
        good_f = nil,        -- frame number of the last good capture
        src = nil,           -- which capture point gave it
        seen = {},           -- per capture point: 'camera' / 'flat _34=.. _44=..' / 'failed' (for /pxi info)
        MAX_AGE = 2,
    }
    for i = 1, 16 do cam.v[FIELDS[i]], cam.p[FIELDS[i]] = 0, 0 end
    -- Raw views of the buffers (made once): reading through them allocates nothing.
    local fv = ffi.cast('float*', cam.view)
    local fp = ffi.cast('float*', cam.proj)
    local vpu = ffi.cast('uint32_t*', cam.vpbuf)
    local v, p = cam.v, cam.p
    -- The device and its function pointers are looked up once; touching them every frame
    -- would create new cdata objects each time.
    local dev, get_transform, get_viewport
    local function fail(tag, why) cam.seen[tag] = why; return false end
    -- Reads the device now. Returns true when it held a perspective camera (then copied into cam.v / cam.p / cam.vp).
    function cam.capture(tag, fno)
        tag = tag or 'present'
        if dev == nil then
            local ok, d = pcall(dev_fn)
            if not ok or d == nil then return fail(tag, 'no device') end
            local vt = d.lpVtbl
            dev, get_transform, get_viewport = d, vt.GetTransform, vt.GetViewport
        end
        if get_transform(dev, M.D3DTS_PROJECTION, cam.proj) ~= 0 then return fail(tag, 'device call failed') end
        -- checked on the raw buffer, so a flat UI projection never replaces the last good camera
        local p11, p34, p44 = fp[0], fp[11], fp[15]
        if not (math.abs(p34) > 0.01 and math.abs(p44) < 0.01 and math.abs(p11) > 1e-4) then
            cam.flat34, cam.flat44 = p34, p44      -- formatted only when the reason text is rebuilt (no per-frame strings)
            return fail(tag, 'flat')
        end
        if get_transform(dev, M.D3DTS_VIEW, cam.view) ~= 0 or get_viewport(dev, cam.vpbuf) ~= 0 then
            return fail(tag, 'device call failed')
        end
        if vpu[2] == 0 or vpu[3] == 0 then return fail(tag, 'empty viewport') end
        for i = 1, 16 do local k = FIELDS[i]; v[k] = fv[i - 1]; p[k] = fp[i - 1] end
        local vp = cam.vp
        vp.X, vp.Y, vp.Width, vp.Height = vpu[0], vpu[1], vpu[2], vpu[3]
        cam.seen[tag], cam.good_f, cam.src = 'camera', fno or 0, tag
        return true
    end
    -- Called once per frame before anything projects: is the last good camera recent enough to use?
    function cam.update(fno)
        if cam.good_f ~= nil and (fno or 0) - cam.good_f <= cam.MAX_AGE then
            cam.ok, cam.why, cam.why_f = true, 'ok (' .. tostring(cam.src) .. ')', nil
        else
            cam.ok = false
            if cam.why_f ~= nil and (fno or 0) - cam.why_f < 30 then return false end     -- reason text rebuilt twice a second
            cam.why_f = fno or 0
            local parts = {}
            for _, tag in ipairs({ 'beginscene', 'endscene', 'present' }) do
                local seen = cam.seen[tag]
                if seen == 'flat' then seen = ('flat _34=%.2f _44=%.2f'):format(cam.flat34 or 0, cam.flat44 or 0) end
                if seen ~= nil then parts[#parts + 1] = tag .. ' ' .. seen end
            end
            cam.why = 'camera matrix not available' .. (#parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or '')
        end
        return cam.ok
    end
    return cam
end

--[[ Menu -> window scale for the game's own UI coordinates. ]]
function M.ui_scale(mem)
    local ok, ptr = pcall(mem.find, M.SIG_YMDB, 1)
    if not ok or type(ptr) ~= 'number' or ptr == 0 then return 1, 1, false end
    ptr = mem.read_u32(ptr); if ptr == 0 then return 1, 1, false end
    ptr = mem.read_u32(ptr); if ptr == 0 then return 1, 1, false end
    local ww, wh = mem.read_u16(ptr + 0x10), mem.read_u16(ptr + 0x12)
    local mw, mh = mem.read_u16(ptr + 0x14), mem.read_u16(ptr + 0x16)
    if ww == 0 or wh == 0 or mw == 0 or mh == 0 then return 1, 1, false end
    return ww / mw, wh / mh, true
end

local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

-- Native arrow position from the target window object. which = 'main' | 'sub'.
function M.native(mem, obj, which, sx, sy, out)
    if obj == nil or obj == 0 then return false end
    local ox = which == 'sub' and M.OFF_SUB_X or M.OFF_ANK_X
    local oy = which == 'sub' and M.OFF_SUB_Y or M.OFF_ANK_Y
    local x, y = s16(mem.read_u16(obj + ox)), s16(mem.read_u16(obj + oy))
    if (x == 0 and y == 0) or x < -64 or y < -64 then return false end
    out.x, out.y = x * sx, y * sy
    return true
end

return M
