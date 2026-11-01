--[[
* RecastXI - rxfonts.lua (adapted from Zztick)
*
* Font support for the RecastXI windows using Ashita's own ImGui helper
*   imgui.AddFontFromFileTTF(filename, size_pixels) -> ImFont
* (IGuiManager "Ashita Custom Helpers", Ashita v4.3+ with ImGui 1.92 dynamic fonts),
* then imgui.PushFont(font, size) around the window contents.
*
* Every load is guarded: the file must exist (ImGui asserts on a missing file),
* each file is loaded at most once per session (success or failure is cached),
* and loads only happen from the frame-start hook, never mid-window.
--]]

local M = {};

-- Common Windows fonts: display name -> regular / bold file in %WINDIR%\Fonts.
M.SYSTEM = {
    { name = 'Arial',           file = 'arial.ttf',    bold = 'arialbd.ttf'  },
    { name = 'Segoe UI',        file = 'segoeui.ttf',  bold = 'segoeuib.ttf' },
    { name = 'Consolas',        file = 'consola.ttf',  bold = 'consolab.ttf' },
    { name = 'Tahoma',          file = 'tahoma.ttf',   bold = 'tahomabd.ttf' },
    { name = 'Verdana',         file = 'verdana.ttf',  bold = 'verdanab.ttf' },
    { name = 'Calibri',         file = 'calibri.ttf',  bold = 'calibrib.ttf' },
    { name = 'Trebuchet MS',    file = 'trebuc.ttf',   bold = 'trebucbd.ttf' },
    { name = 'Georgia',         file = 'georgia.ttf',  bold = 'georgiab.ttf' },
    { name = 'Courier New',     file = 'cour.ttf',     bold = 'courbd.ttf'   },
};

-- Fonts shipped in addons\recastxi\fonts\ (Google Fonts, SIL Open Font License 1.1).
M.BUNDLED = {
    { name = 'Cinzel',                file = 'Cinzel-Bold.ttf',                 bold = 'Cinzel-Bold.ttf' },
    { name = 'Marcellus SC',          file = 'MarcellusSC-Regular.ttf',         bold = 'MarcellusSC-Regular.ttf' },
    { name = 'Exo 2',                 file = 'Exo2-SemiBold.ttf',               bold = 'Exo2-SemiBold.ttf' },
    { name = 'Fredoka',               file = 'Fredoka-SemiBold.ttf',            bold = 'Fredoka-SemiBold.ttf' },
    { name = 'Barlow Semi Condensed', file = 'BarlowSemiCondensed-Regular.ttf', bold = 'BarlowSemiCondensed-SemiBold.ttf' },
    { name = 'Inter',                 file = 'Inter-Regular.ttf',               bold = 'Inter-SemiBold.ttf' },
    { name = 'JetBrains Mono',        file = 'JetBrainsMono-Regular.ttf',       bold = 'JetBrainsMono-Regular.ttf' },
};

M.DEFAULT = 'Default (Ashita)';
M.THEME = 'Theme default';

-- Injectable environment (overridden by tests).
M.env = {
    exists = function (path)
        local f = io.open(path, 'rb');
        if (f == nil) then return false; end
        f:close();
        return true;
    end,
    list_dir = function (dir)
        if (ashita == nil or ashita.fs == nil or ashita.fs.get_directory == nil) then return nil; end
        local ok, r = pcall(ashita.fs.get_directory, dir);
        if (ok) then return r; end
        return nil;
    end,
    windir = function ()
        return os.getenv('WINDIR') or os.getenv('SystemRoot') or 'C:\\Windows';
    end,
    loader = function ()
        -- Returns the Ashita helper if this build has it, else nil.
        local imgui = require('imgui');
        local ok, fn = pcall(function () return imgui.AddFontFromFileTTF; end);
        if (ok and type(fn) ~= 'nil') then
            return function (path, size) return fn(path, size); end
        end
        return nil;
    end,
};

local cache  = {};   -- path -> ImFont | false
local errors = {};   -- path -> reason
M.load_count = 0;

local function trim_slash(p) return (p:gsub('[\\/]+$', '')); end

function M.custom_dir(addon_path)
    return trim_slash(addon_path or '.') .. '\\fonts';
end

--[[
* Returns the list of selectable fonts: { name=, path=, bold_path=, custom=, bundled= }.
* Order: default, bundled families, Windows fonts, other files in the fonts folder.
* Only fonts whose file exists are listed.
--]]
function M.scan(addon_path)
    local list = { { name = M.THEME }, { name = M.DEFAULT } };
    local dir = M.custom_dir(addon_path);
    local bundled_files = {};
    for _, f in ipairs(M.BUNDLED) do
        bundled_files[f.file:lower()], bundled_files[f.bold:lower()] = true, true;
        local p = dir .. '\\' .. f.file;
        if (M.env.exists(p)) then
            local b = dir .. '\\' .. f.bold;
            list[#list + 1] = { name = f.name, path = p, bold_path = M.env.exists(b) and b or nil, bundled = true };
        end
    end
    local fonts_dir = M.env.windir() .. '\\Fonts\\';
    for _, f in ipairs(M.SYSTEM) do
        local p = fonts_dir .. f.file;
        if (M.env.exists(p)) then
            local b = fonts_dir .. f.bold;
            list[#list + 1] = { name = f.name, path = p, bold_path = M.env.exists(b) and b or nil };
        end
    end
    local files = M.env.list_dir(dir);
    if (type(files) == 'table') then
        local names = {};
        for _, fname in pairs(files) do
            if (type(fname) == 'string') then
                local lower = fname:lower();
                if ((lower:match('%.ttf$') or lower:match('%.otf$')) and not bundled_files[lower]) then names[#names + 1] = fname; end
            end
        end
        table.sort(names);
        for _, fname in ipairs(names) do
            list[#list + 1] = { name = fname, path = dir .. '\\' .. fname, custom = true };
        end
    end
    return list;
end

function M.find(list, name)
    for _, f in ipairs(list) do
        if (f.name == name) then return f; end
    end
    return nil;
end

function M.supported()
    return M.env.loader() ~= nil;
end

--[[
* Loads (once) and returns an ImFont for path, or nil plus a reason.
--]]
function M.load(path, size)
    if (path == nil) then return nil, 'no file'; end
    local c = cache[path];
    if (c ~= nil) then
        if (c == false) then return nil, errors[path]; end
        return c;
    end
    if (not M.env.exists(path)) then
        cache[path] = false; errors[path] = 'file not found';
        return nil, errors[path];
    end
    local loader = M.env.loader();
    if (loader == nil) then
        cache[path] = false; errors[path] = 'this Ashita build has no imgui.AddFontFromFileTTF (update Ashita v4)';
        return nil, errors[path];
    end
    M.load_count = M.load_count + 1;
    local ok, font = pcall(loader, path, size or 16);
    if (not ok or font == nil) then
        cache[path] = false; errors[path] = 'failed to load: ' .. tostring(font);
        return nil, errors[path];
    end
    cache[path] = font;
    return font;
end

function M.reset_cache_for_tests() cache = {}; errors = {}; M.load_count = 0; end

return M;
