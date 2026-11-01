--[[
* RecastXI - rxicons.lua
* Icon lookup (XIUI-compatible names) and a texture cache.
*
* Folder: addons\recastxi\icons\[<pack>\]
*   spells\<spell id %05d>.png         e.g. spells\00109.png (Refresh)      (XIUI: assets\hotbar\spells)
*   abilities\<ability id %05d>.png    IAbility.Id, 0x200+ (Convert = 00...) (XIUI: assets\hotbar\abilities)
*   elements\<Element>.png             Fire Ice Wind Earth Lightning Water Light Dark
*   categories\<category>.png          ability healing enhancing enfeebling elemental dark divine summoning
*                                      ninjutsu song blue geomancy magic
*   generic.png
*   crests\<job>.png, crests\default.png   (custom header crest)
* Lookup order: exact id -> element (Elemental Magic only) -> category (from the magic skill) -> element
* (fallback when the category file is missing) -> generic -> drawn placeholder.
*
* v1.2.0 drop folder: addons\recastxi\icons\drop\ (used with every pack). Drop files there as-is:
*   XIUI hotbar icons   drop\spells\<id %05d>.png, drop\abilities\<id %05d>.png (same names as above)
*   HXUI status icons   drop\<status>.png, drop\HD\<status>.png, drop\XIView\<status>.png,
*                       drop\status\HD|XIView\<status>.png, and the original 8-digit names (%08d)
*   HXUI's 0..639 icons are STATUS EFFECT icons (named by status id, not spell/ability id), so a
*   spell/ability is mapped to the status it applies via rxstatusmap.lua (generated from the
*   Windower resources). Entries without a status (cures, nukes, Convert...) fall back as usual.
* Full order: pack exact -> drop XIUI exact -> drop status -> element -> category -> generic -> drawn.
*
* v1.3.0 drop packs: every sub-folder of drop\ is a pack (icons\drop\<Pack>\..., any layout above);
* loose files in drop\ itself are the 'Default/loose' pack. Order: selected pack (XIUI ids, then
* status icons) -> (2.5) the fallback pack -> loose drop files
* -> element -> category -> generic -> drawn. Switching packs queues the old textures for release
* at the start of the next frame. The image's native size (PNG header) is kept so it can be
* scaled into the icon slot with its aspect ratio.
*
* Textures are loaded the way XIUI does (D3DXCreateTextureFromFileA on Ashita's d3d8 device) and
* drawn with ImDrawList:AddImage(tonumber(ffi.cast('uint32_t', tex))). Each file is loaded once,
* at most MAX_LOADS_PER_FRAME new files per frame, and every texture is Released on unload, or
* at the start of the next frame after a rescan.
--]]

local M = {};
M.MAX_LOADS_PER_FRAME = 4;
M.CATEGORIES = { 'ability', 'healing', 'enhancing', 'enfeebling', 'elemental', 'dark', 'divine', 'summoning',
                 'ninjutsu', 'song', 'blue', 'geomancy', 'magic' };

-- Injectable environment (tests replace it).
local ok_ffi, ffi = pcall(require, 'ffi');
M.env = {
    exists = function (path)
        local f = io.open(path, 'rb'); if (f == nil) then return false; end f:close(); return true;
    end,
    list_dir = function (dir, mask)
        if (ashita == nil or ashita.fs == nil) then return nil; end
        local fn = ashita.fs.get_directory or ashita.fs.get_dir;
        if (fn == nil) then return nil; end
        local ok, r = pcall(fn, dir, mask or '.*', false);
        if (ok and type(r) == 'table') then return r; end
        return nil;
    end,
    is_dir = function (path)
        if (ashita == nil or ashita.fs == nil or ashita.fs.status == nil) then return false; end
        local ok, st = pcall(ashita.fs.status, path);
        return ok and st ~= nil and st.is_directory == true;
    end,
    load_texture = function (path)
        if (not ok_ffi) then return nil, 'no ffi'; end
        local ok_d3d, d3d8 = pcall(require, 'd3d8');
        if (not ok_d3d) then return nil, 'no d3d8 lib'; end
        local dev = d3d8.get_device();
        if (dev == nil) then return nil, 'no device'; end
        local ptr = ffi.new('IDirect3DTexture8*[1]');
        local ok, hr = pcall(function () return ffi.C.D3DXCreateTextureFromFileA(dev, path, ptr); end);
        if (not ok) then return nil, tostring(hr); end
        if (hr ~= 0 or ptr[0] == nil) then return nil, ('D3DX error 0x%08X'):format(bit.band(tonumber(hr) or 0, 0xFFFFFFFF)); end
        return ptr[0];
    end,
    release = function (tex) pcall(function () tex:Release(); end); end,
    -- native PNG size from the IHDR chunk (bytes 17..24); nil if not a PNG
    image_size = function (path)
        local f = io.open(path, 'rb'); if (f == nil) then return nil; end
        local h = f:read(24); f:close();
        if (h == nil or #h < 24 or h:sub(2, 4) ~= 'PNG') then return nil; end
        local function be(i) local a, b, c, d = h:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d; end
        local w, hh = be(17), be(21);
        if (w <= 0 or hh <= 0 or w > 8192 or hh > 8192) then return nil; end
        return w, hh;
    end,
    tex_id = function (tex) return tonumber(ffi.cast('uint32_t', tex)); end,
    first_line = function (path)       -- PartyramaXI: a pack's base.txt
        local f = io.open(path, 'r'); if (f == nil) then return nil; end
        local l = f:read('*l'); f:close(); return l;
    end,
};

M.base = '';            -- '...\addons\recastxi\icons\' (+ pack)
M.drop = '';            -- selected drop folder: '...\icons\drop\' (loose) or '...\icons\drop\<Pack>\'
M.drop_root = '';       -- '...\icons\packs\'
M.loose = '';           -- '...\icons\' (loose status icons: status\)
M.drop_pack = '';       -- '' = Default/loose
M.drop2, M.drop_pack2 = nil, '';   -- PartyramaXI: the fallback pack (nil = none)
M.LOOSE = 'None (loose files only)';
M.LAYOUT_DIRS = { spells = true, abilities = true, status = true };   -- pack-internal layouts, never listed as packs
local ok_map, SMAP = pcall(require, 'pxirxstatusmap');
if (not ok_map or type(SMAP) ~= 'table') then SMAP = { spells = {}, abilities = {} }; end
M.status_map = SMAP;
local status_cache = {};
local dims = {};        -- path -> { w, h } from the PNG header (false = unknown)
local path_cache = {};  -- fkey/res -> path | false
local level_cache = {};
local res_cache = {};   -- PartyramaXI: fkey -> the record's res_id the path was found for
local tex = {};         -- path -> { id=, tex= } | false
local errors = {};
local loads_this_frame, frame_no = 0, -1;
M.loaded, M.failed = 0, 0;

-- PartyramaXI: a pack's base pack (first line of its base.txt) supplies the icons it does not have itself.
local function base_of(name)
    if (name == nil or name == '') then return nil; end
    local l = M.env.first_line and M.env.first_line(M.drop_root .. name .. '\\base.txt') or nil;
    if (l == nil) then return nil; end
    local b = l:gsub('^%s+', ''):gsub('%s+$', '');
    if (b == '' or b:lower() == name:lower()) then return nil; end
    return M.drop_root .. b .. '\\', b;
end
M.base_of = base_of;
-- PartyramaXI: one icons\ folder for every module. The packs are icons\packs\<Pack>\ and the loose files sit
-- in icons\ itself (icons\status\<status id>.png). pack is no longer used.
function M.set_base(addon_path, pack)
    local b = (addon_path or ''):gsub('[\\/]+$', '') .. '\\icons\\';
    if (b ~= M.base) then
        M.base = b; M.loose = b; M.drop_root = b .. 'packs\\';
        M.drop = (M.drop_pack ~= '') and (M.drop_root .. M.drop_pack .. '\\') or M.loose;
        M.drop_b, M.drop_bn = base_of(M.drop_pack);
        M.drop2_b, M.drop2_bn = base_of(M.drop_pack2);
        M.rescan();
    end
end

local exists_cache = {};
local function exists(p)
    local e = exists_cache[p];
    if (e == nil) then e = M.env.exists(p) and true or false; exists_cache[p] = e; end
    return e;
end
M.exists = exists;

--[[ Resolves the icon file for a record (cached). Returns path or nil, the level used and the
* status id when a status icon was used. ]]
local SPELL_FMT, ABIL_FMT = 'spells\\%05d.png', 'abilities\\%05d.png';
local STATUS_DIRS = { '', 'status\\', 'HD\\', 'XIView\\', 'status\\HD\\', 'status\\XIView\\' };
function M.status_of(rec)
    if (type(rec.res_id) ~= 'number') then return nil; end
    if (rec.kind == 'spell') then return SMAP.spells[rec.res_id]; end
    if (rec.kind == 'ability') then return SMAP.abilities[rec.res_id]; end
    return nil;
end
local function status_file(dir, sid)
    for i = 1, #STATUS_DIRS do
        local c = dir .. STATUS_DIRS[i] .. sid .. '.png';
        if (exists(c)) then return c; end
    end
    for i = 1, 3 do
        local c = dir .. STATUS_DIRS[i] .. ('%08d.png'):format(sid);
        if (exists(c)) then return c; end
    end
    return nil;
end
-- one drop folder: XIUI id name first, then the HXUI status icon
local function in_drop(dir, rec, name, tag)
    if (name ~= nil) then
        local c = dir .. name;
        if (exists(c)) then return c, tag .. ' exact', nil; end
    end
    local st = M.status_of(rec);
    if (st ~= nil) then
        local c = status_file(dir, st);
        if (c ~= nil) then return c, tag .. ' status ' .. st, st; end
    end
    return nil;
end
-- PartyramaXI: the element and category pictures follow the Target bar's picture style (M.style_fn, set by
-- partyramaxi.lua): glossy = the folder itself; jewel / flat = its jewel\ / flat\ folder; painted = elements\painted\.
-- A file missing there comes from the folder itself.
local STYLE_SUB = { elements = { jewel = 'jewel', flat = 'flat', painted = 'painted', glyph = 'glyph', contrast = 'contrast', glass = 'glass' }, categories = { jewel = 'jewel', flat = 'flat' } };
local cur_style = nil;
local function styled(sub, file)
    local d = STYLE_SUB[sub][cur_style or 'glossy'];
    -- PartyramaXI: a folder of the player's own (icons\\elements\\<name>) is a style too
    if (d == nil and sub == 'elements' and cur_style ~= nil and cur_style ~= 'glossy') then d = cur_style; end
    if (d ~= nil) then
        local c = M.base .. sub .. '\\' .. d .. '\\' .. file;
        if (exists(c)) then return c; end
    end
    local c = M.base .. sub .. '\\' .. file;
    if (exists(c)) then return c; end
    return nil;
end
function M.lookup(rec)
    local st = (M.style_fn ~= nil) and M.style_fn() or nil;
    if (st ~= cur_style) then cur_style = st; path_cache, level_cache, status_cache, res_cache = {}, {}, {}, {}; end
    local key = rec.fkey or rec.key;
    local p = path_cache[key];
    -- PartyramaXI: an ability recast id means another ability on another job; the record's resource id
    -- changes when its name is looked up again after a job change, and the icon is then found again too
    if (p ~= nil and res_cache[key] == rec.res_id) then return p or nil, level_cache[key], status_cache[key]; end
    local lvl, sid = 'none', nil;
    local cand;
    local fmt_ = (rec.kind == 'spell') and SPELL_FMT or ((rec.kind == 'ability') and ABIL_FMT or nil);
    local name = (fmt_ ~= nil and type(rec.res_id) == 'number') and fmt_:format(rec.res_id) or nil;
    -- 1. the selected drop pack (no pack: the loose status icons only)
    p, lvl, sid = in_drop(M.drop, rec, (M.drop_pack ~= '') and name or nil, (M.drop_pack ~= '') and ('pack ' .. M.drop_pack) or 'drop');
    -- 2. the fallback pack (PartyramaXI; the loose icons\spells and icons\abilities folders are gone)
    if (p == nil and M.drop_b ~= nil) then p, lvl, sid = in_drop(M.drop_b, rec, name, 'pack ' .. M.drop_bn); end
    if (p == nil and M.drop2 ~= nil) then p, lvl, sid = in_drop(M.drop2, rec, name, 'fallback ' .. M.drop_pack2); end
    if (p == nil and M.drop2_b ~= nil) then p, lvl, sid = in_drop(M.drop2_b, rec, name, 'fallback ' .. M.drop2_bn); end
    -- 3. loose status icons (icons\status) when a named pack is selected
    if (p == nil and M.drop_pack ~= '') then p, lvl, sid = in_drop(M.loose, rec, nil, 'loose'); end
    lvl = lvl or 'none';
    -- v1.3.2: the element icon is only for Elemental Magic. Every white/dark/enfeebling/blue/ninjutsu
    -- spell also has an element (Cure = Light, Dispel = Dark ...), which used to win over the
    -- category and gave all of them the same Light/Dark icon. Everything else now uses the icon of
    -- its magic skill (categories\<skill>.png).
    if (p == nil and rec.element and rec.cat == 'elemental') then
        cand = styled('elements', rec.element .. '.png');
        if (cand ~= nil) then p, lvl = cand, 'element'; end
    end
    if (p == nil and rec.cat) then
        cand = styled('categories', rec.cat .. '.png');
        if (cand ~= nil) then p, lvl = cand, 'category'; end
    end
    -- no category file for this skill (or an unknown skill): the element icon is still better than generic
    if (p == nil and rec.element) then
        cand = styled('elements', rec.element .. '.png');
        if (cand ~= nil) then p, lvl = cand, 'element'; end
    end
    if (p == nil) then
        cand = M.base .. 'generic.png';
        if (exists(cand)) then p, lvl = cand, 'generic'; end
    end
    path_cache[key], level_cache[key], status_cache[key], res_cache[key] = p or false, lvl, sid, rec.res_id;
    return p, lvl, sid;
end

-- Texture id for a path (loads lazily, throttled). nil = not available (yet).
function M.texture(path, frame)
    if (path == nil) then return nil; end
    local t = tex[path];
    if (t ~= nil) then return t and t.id or nil; end
    if (frame ~= frame_no) then frame_no, loads_this_frame = frame, 0; end
    if (loads_this_frame >= M.MAX_LOADS_PER_FRAME) then return nil; end
    loads_this_frame = loads_this_frame + 1;
    local ok, obj, why = pcall(M.env.load_texture, path);
    if (ok and obj ~= nil) then
        local okid, id = pcall(M.env.tex_id, obj);
        if (okid and id ~= nil) then
            tex[path] = { id = id, tex = obj }; M.loaded = M.loaded + 1;
            local okd, w, h = pcall(M.env.image_size, path);
            dims[path] = (okd and type(w) == 'number' and type(h) == 'number') and { w, h } or false;
            return id;
        end
        M.env.release(obj);
    end
    tex[path] = false; M.failed = M.failed + 1;
    errors[path] = ok and (why or 'load failed') or tostring(obj);
    return nil;
end
function M.error_for(path) return errors[path]; end

-- Texture id plus the native width/height (1, 1 when unknown = square).
function M.icon_for(rec, frame)
    local p = M.lookup(rec);
    if (p == nil) then return nil; end
    local id = M.texture(p, frame);
    if (id == nil) then return nil; end
    local d = dims[p];
    if (d) then return id, d[1], d[2]; end
    return id, 1, 1;
end
function M.native_size(path) local d = dims[path]; if (d) then return d[1], d[2]; end return nil; end

-- Fits a w x h image into a square slot (aspect kept, centered). Pure numbers.
function M.fit(x, y, sz, w, h)
    if (not (w and h and w > 0 and h > 0)) then return x, y, x + sz, y + sz; end
    local dw, dh = sz, sz;
    if (w > h) then dh = sz * h / w; elseif (h > w) then dw = sz * w / h; end
    local ox, oy = (sz - dw) / 2, (sz - dh) / 2;
    return x + ox, y + oy, x + ox + dw, y + oy + dh;
end

--[[ v1.3.0 drop packs ]]
function M.list_drop_packs()
    local out = {};
    local root = M.drop_root:gsub('[\\/]+$', '');
    local files = M.env.list_dir(root, '.*');
    if (type(files) == 'table') then
        for _, f in pairs(files) do
            local nm = type(f) == 'string' and (f:match('[^\\/]+$') or f) or nil;
            if (nm ~= nil and not nm:find('.', 1, true) and not M.LAYOUT_DIRS[nm:lower()] and M.env.is_dir(root .. '\\' .. nm)) then out[#out + 1] = nm; end
        end
    end
    table.sort(out, function (a, b) return a:lower() < b:lower(); end);
    return out;
end
-- Finds a pack by name (case-insensitive). '' / 'default' / 'loose' = the loose pack.
function M.find_drop_pack(name)
    if (name == nil) then return nil; end
    local l = name:lower();
    if (l == '' or l == 'default' or l == 'loose' or l == M.LOOSE:lower()) then return ''; end
    for _, p in ipairs(M.list_drop_packs()) do if (p:lower() == l) then return p; end end
    return nil;
end
-- Selects a drop pack; old textures are released at the start of the next frame.
function M.set_drop_pack(name)
    name = name or '';
    if (name == M.drop_pack) then return false; end
    M.drop_pack = name;
    M.drop = (name ~= '') and (M.drop_root .. name .. '\\') or M.loose;
    M.drop_b, M.drop_bn = base_of(name);
    M.rescan();
    return true;
end
-- PartyramaXI: the fallback pack, used when the selected pack has no icon ('' = none).
function M.set_drop_pack2(name)
    name = name or '';
    if (name == M.drop_pack2) then return false; end
    M.drop_pack2 = name;
    M.drop2 = (name ~= '') and (M.drop_root .. name .. '\\') or nil;
    M.drop2_b, M.drop2_bn = base_of(name);
    M.rescan();
    return true;
end

--[[ Crest: per-job file -> default -> nil (caller falls back to the theme crest). ]]
function M.crest_path(s, job_abbr)
    local function abs(f)
        if (f:match('^%a:[\\/]') or f:match('^[\\/][\\/]')) then return f; end
        return M.base .. f;
    end
    if (s.crest_per_job and job_abbr ~= nil) then
        local p = M.base .. 'crests\\' .. job_abbr:lower() .. '.png';
        if (exists(p)) then return p; end
    end
    if (type(s.crest_file) == 'string' and s.crest_file ~= '') then
        local p = abs(s.crest_file);
        if (exists(p)) then return p; end
    end
    local d = M.base .. 'crests\\default.png';
    if (exists(d)) then return d; end
    return nil;
end
local crest_cache = { key = nil, path = nil };
function M.crest_path_cached(s, job_abbr)
    local k = job_abbr;
    if (crest_cache.key ~= k or crest_cache.file ~= s.crest_file or crest_cache.per ~= s.crest_per_job) then
        crest_cache.key, crest_cache.file, crest_cache.per = k, s.crest_file, s.crest_per_job;
        crest_cache.path = M.crest_path(s, job_abbr);
    end
    return crest_cache.path;
end

function M.list_crests()
    local out = {};
    local files = M.env.list_dir(M.base .. 'crests', '.*');
    if (type(files) == 'table') then
        for _, f in pairs(files) do if (type(f) == 'string' and f:lower():match('%.png$')) then out[#out + 1] = 'crests\\' .. (f:match('[^\\/]+$') or f); end end
    end
    table.sort(out);
    return out;
end
function M.list_packs(addon_path)
    local out = { 'default' };
    local root = (addon_path or ''):gsub('[\\/]+$', '') .. '\\icons';
    local files = M.env.list_dir(root, '.*');
    if (type(files) == 'table') then
        local skip = { spells = true, abilities = true, elements = true, categories = true, crests = true, drop = true };
        for _, f in pairs(files) do
            local nm = type(f) == 'string' and (f:match('[^\\/]+$') or f) or nil;
            if (nm ~= nil and not nm:find('.', 1, true) and not skip[nm:lower()] and M.env.is_dir(root .. '\\' .. nm)) then out[#out + 1] = nm; end
        end
    end
    return out;
end
-- Counts files per folder for the Icons tab (on rescan only).
function M.count()
    local c = {};
    for _, sub in ipairs({ 'elements', 'categories', 'crests' }) do
        local files = M.env.list_dir(M.base .. sub, '.*');
        local n = 0;
        if (type(files) == 'table') then for _, f in pairs(files) do if (type(f) == 'string' and f:lower():match('%.png$')) then n = n + 1; end end end
        c[sub] = n;
    end
    c.generic = exists(M.base .. 'generic.png');
    -- v1.2.0 drop folder
    local nd = 0;
    for _, sub in ipairs({ '', 'spells', 'abilities', 'status', 'HD', 'XIView', 'status\\HD', 'status\\XIView' }) do
        local files = M.env.list_dir((sub == '') and M.drop:gsub('[\\/]+$', '') or (M.drop .. sub), '.*');
        if (type(files) == 'table') then for _, f in pairs(files) do if (type(f) == 'string' and f:lower():match('%.png$')) then nd = nd + 1; end end end
    end
    c.drop = nd;
    return c;
end

-- Textures dropped mid-frame may still be referenced by this frame's ImGui draw list, so a
-- rescan only queues them; flush_pending() releases them at the start of the next frame
-- (the same deferral XIUI's texture manager uses to avoid access violations).
local pending = {};
function M.flush_pending()
    for i = #pending, 1, -1 do M.env.release(pending[i]); pending[i] = nil; end
end
function M.pending_count() return #pending; end
function M.release_all()   -- unload: nothing is drawn any more
    M.flush_pending();
    for p, t in pairs(tex) do if (t and t.tex ~= nil) then M.env.release(t.tex); end tex[p] = nil; end
end
function M.rescan()
    for p, t in pairs(tex) do if (t and t.tex ~= nil) then pending[#pending + 1] = t.tex; end tex[p] = nil; end
    path_cache, level_cache, exists_cache, errors, status_cache, dims, res_cache = {}, {}, {}, {}, {}, {}, {};
    crest_cache.key = '\0';
    M.loaded, M.failed = 0, 0;
end
function M.live_textures() local n = 0; for _, t in pairs(tex) do if (t) then n = n + 1; end end return n; end

return M;
