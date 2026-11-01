--[[
* PartyramaXI - PNG arrows from the addon's arrows/ folder.
*
* Textures are created once (Direct3D 8 via D3DXCreateTextureFromFileExA, the same way XIUI's
* hotbar loads icons), cached by file name, and released on reload / unload. Nothing is loaded
* while drawing: a failed file is remembered and the built-in triangle is drawn instead.
*
* backend = {
*   list(dir)            -> { 'name.png', ... } | nil
*   create(path)         -> handle, texture_id, width, height  |  nil, error_text
*   release(handle)
* }
--]]
local M = {}

function M.new(backend, dir)
    local p = { backend = backend, dir = dir, files = {}, cache = {}, scanned = false }
    return setmetatable(p, { __index = M })
end

-- Style names for PNGs are 'png:<file name>'.
function M.style_of(file) return 'png:' .. file end
function M.file_of(style)
    if type(style) ~= 'string' or style:sub(1, 4) ~= 'png:' then return nil end
    return style:sub(5)
end

function M:scan()
    local ok, list = pcall(self.backend.list, self.dir)
    local files = {}
    if ok and type(list) == 'table' then
        for _, f in ipairs(list) do
            if type(f) == 'string' then
                local name = f:match('([^\\/]+)$') or f
                if name:lower():match('%.png$') then files[#files + 1] = name end
            end
        end
    end
    table.sort(files, function (a, b) return a:lower() < b:lower() end)
    self.files = files
    self.scanned = true
    self.scan_error = (not ok) and tostring(list) or nil
    return #files
end

function M:has(file)
    for _, f in ipairs(self.files) do if f == file then return true end end
    return false
end

-- Cached texture entry for a file: { id, w, h } or { err }. Loads at most once per file.
function M:get(file)
    local e = self.cache[file]
    if e ~= nil then return e end
    if not self:has(file) then
        e = { err = 'not in the arrows folder' }
    else
        local ok, h, id, w, ht = pcall(self.backend.create, self.dir .. file)
        if ok and h ~= nil and type(id) == 'number' and id ~= 0 then
            e = { handle = h, id = id, w = tonumber(w) or 64, h = tonumber(ht) or 64 }
        else
            e = { err = ok and tostring(id or 'could not be loaded') or tostring(h) }
        end
    end
    self.cache[file] = e
    return e
end

-- A white copy of the picture that keeps its transparency (for light effects masked to the visible pixels, such as
-- the flash on status icons). { id } or { err }; made once per file, only if the backend can edit textures.
function M:silhouette(file)
    self.sil = self.sil or {}
    local e = self.sil[file]
    if e ~= nil then return e end
    if self.backend.create_white == nil or not self:has(file) then
        e = { err = 'not available' }
    else
        local ok, h, id = pcall(self.backend.create_white, self.dir .. file)
        if ok and h ~= nil and type(id) == 'number' and id ~= 0 then e = { handle = h, id = id }
        else e = { err = ok and tostring(id or 'could not be made') or tostring(h) } end
    end
    self.sil[file] = e
    return e
end

function M:release_all()
    local n = 0
    for k, e in pairs(self.cache) do
        if e.handle ~= nil then pcall(self.backend.release, e.handle); n = n + 1 end
        self.cache[k] = nil
    end
    for k, e in pairs(self.sil or {}) do
        if e.handle ~= nil then pcall(self.backend.release, e.handle); n = n + 1 end
        self.sil[k] = nil
    end
    return n
end

function M:reload()
    self:release_all()
    return self:scan()
end

--[[ Real Ashita backend. ]]
function M.ashita_backend(ffi, d3d8)
    local dev = nil
    local info = nil
    local b = {}
    function b.list(dir)
        return ashita.fs.get_directory(dir, '.*', true) or {}   -- filtered to *.png (any case) by scan()
    end
    function b.create(path)
        if dev == nil then dev = d3d8.get_device() end
        if dev == nil then return nil, 'no Direct3D device' end
        info = info or ffi.new('D3DXIMAGE_INFO[1]')
        local out = ffi.new('IDirect3DTexture8*[1]')
        local res = ffi.C.D3DXCreateTextureFromFileExA(dev, path,
            0xFFFFFFFF, 0xFFFFFFFF,     -- D3DX_DEFAULT: keep the file's size
            1, 0,                       -- one mip level, no usage flags
            ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED,
            0xFFFFFFFF, 0xFFFFFFFF,     -- D3DX_DEFAULT filters
            0, info, nil, out)
        if res ~= 0 or out[0] == nil then return nil, ('Direct3D error 0x%08X'):format(res % 0x100000000) end
        local tex = ffi.new('IDirect3DTexture8*', out[0])
        local id = tonumber(ffi.cast('uint32_t', tex))
        return tex, id, info[0].Width, info[0].Height
    end
    -- The same file as a texture whose colors are all white (alpha kept): level 0 is locked and every pixel's B, G, R
    -- set to 255. The surface size comes from the texture itself (D3DX may have padded or scaled it).
    function b.create_white(path)
        local tex, id = b.create(path)
        if tex == nil then return nil, id end
        local ok, e = pcall(function ()
            -- 2.7.5: Ashita's d3d8 wrappers allocate the out-structs themselves and return them: GetLevelDesc(level)
            -- -> hr, desc and LockRect(level, rect, flags) -> hr, locked_rect. (2.7.1 passed its own out-struct,
            -- which landed in LockRect's rect argument: "bad argument #4 to 'LockRect'".) The raw COM form is the fallback.
            local desc = ffi.new('D3DSURFACE_DESC[1]')
            local hr, d = tex:GetLevelDesc(0, desc)
            if hr ~= 0 then error('GetLevelDesc failed') end
            if type(d) ~= 'cdata' then d = desc[0] elseif not pcall(function () return d.Width end) then d = d[0] end
            local w, h = tonumber(d.Width) or 0, tonumber(d.Height) or 0
            if w < 1 or h < 1 then error('the texture reported no size') end
            local lok, lhr, lr = pcall(tex.LockRect, tex, 0, nil, 0)
            if not lok or type(lr) ~= 'cdata' then
                local raw = ffi.new('D3DLOCKED_RECT[1]')
                lhr = tex:LockRect(0, raw, nil, 0)
                lr = raw[0]
            end
            if lhr ~= 0 then error('LockRect failed') end
            if not pcall(function () return lr.Pitch end) then lr = lr[0] end     -- handed back as a 1-element array
            local pitch, bits = lr.Pitch, ffi.cast('uint8_t*', lr.pBits)
            if bits == nil or pitch < w * 4 then tex:UnlockRect(0); error('LockRect gave no pixels') end
            for y = 0, h - 1 do
                local row = bits + y * pitch
                for x = 0, w - 1 do
                    local o = x * 4
                    row[o], row[o + 1], row[o + 2] = 255, 255, 255
                end
            end
            tex:UnlockRect(0)
        end)
        if not ok then tex:Release(); return nil, tostring(e) end
        return tex, id
    end
    function b.release(tex)
        if tex ~= nil then tex:Release() end
    end
    return b
end

return M
