--[[
* PartyramaXI - font choice for the enemy info text.
*
* Uses Ashita's own helper  imgui.AddFontFromFileTTF(path, size)  (Ashita 4.3+, ImGui 1.92) and then
* imgui.PushFont(font, size) around the text. Every step is guarded: a file must exist before it is
* loaded (ImGui asserts on a missing file), each file is loaded at most once per session (a failure is
* remembered too), and nothing here can throw into the draw code. If anything is missing the text just
* stays in the default font.
*
* Fonts offered: the default one, the common Windows fonts that exist on this PC, and any .ttf / .otf
* you drop into  addons\partyramaxi\fonts\.
--]]
local M = {}

-- display name, regular file, bold file, italic file, bold italic file (all in %WINDIR%\Fonts)
local SYSTEM = {
    { 'Arial',        'arial.ttf',   'arialbd.ttf', 'ariali.ttf', 'arialbi.ttf' },
    { 'Segoe UI',     'segoeui.ttf', 'segoeuib.ttf', 'segoeuii.ttf', 'segoeuiz.ttf' },
    { 'Consolas',     'consola.ttf', 'consolab.ttf', 'consolai.ttf', 'consolaz.ttf' },
    { 'Tahoma',       'tahoma.ttf',  'tahomabd.ttf' },
    { 'Verdana',      'verdana.ttf', 'verdanab.ttf', 'verdanai.ttf', 'verdanaz.ttf' },
    { 'Calibri',      'calibri.ttf', 'calibrib.ttf', 'calibrii.ttf', 'calibriz.ttf' },
    { 'Trebuchet MS', 'trebuc.ttf',  'trebucbd.ttf', 'trebucit.ttf', 'trebucbi.ttf' },
    { 'Georgia',      'georgia.ttf', 'georgiab.ttf', 'georgiai.ttf', 'georgiaz.ttf' },
    { 'Courier New',  'cour.ttf',    'courbd.ttf', 'couri.ttf', 'courbi.ttf' },
    -- softer, rounder faces (present on most Windows installs; the ones missing on this PC are simply not listed)
    { 'Candara',                'candara.ttf',  'candarab.ttf', 'candarai.ttf', 'candaraz.ttf' },
    { 'Corbel',                 'corbel.ttf',   'corbelb.ttf', 'corbeli.ttf', 'corbelz.ttf' },
    { 'Century Gothic',         'gothic.ttf',   'gothicb.ttf'  },
    { 'Arial Rounded MT Bold',  'arlrdbd.ttf',  'arlrdbd.ttf'  },
    { 'Maiandra GD',            'maian.ttf',    'maian.ttf'    },
    { 'Segoe UI Semilight',     'segoeuisl.ttf','segoeuib.ttf', 'segoeuisli.ttf', 'segoeuiz.ttf' },
    { 'Calibri Light',          'calibril.ttf', 'calibrib.ttf', 'calibrili.ttf', 'calibriz.ttf' },
    { 'Comic Sans MS',          'comic.ttf',    'comicbd.ttf', 'comici.ttf', 'comicz.ttf' },
    { 'Segoe Print',            'segoepr.ttf',  'segoeprb.ttf' },
    { 'Ink Free',               'inkfree.ttf',  'inkfree.ttf'  },
    { 'Gabriola',               'gabriola.ttf', 'gabriola.ttf' },
    { 'Berlin Sans FB',         'brlnsr.ttf',   'brlnsb.ttf'   },
    { 'Lucida Sans',            'l_10646.ttf',  'l_10646.ttf'  },
}

M.DEFAULT = 'Default (Ashita)'
M.font = nil          -- ImFont to push, or nil for the default one
M.faux_bold = false   -- bold wanted but there is no bold file: the text is drawn twice, 1 px apart
M.status = ''         -- shown in the settings window when something did not load
M.list = nil          -- { { name, path, bold_path } ... }, built on first use

local cache, errors = {}, {}
local last_name, last_bold, last_italic, last_ok

local function exists(p)
    local f = io.open(p, 'rb')
    if f == nil then return false end
    f:close(); return true
end

local function addon_dir()
    local base = (rawget(_G, 'addon') and addon.path) or '.'
    return (base:gsub('[\\/]+$', ''))
end

function M.supported()
    local ok, f = pcall(function() return require('imgui').AddFontFromFileTTF end)
    return ok and type(f) == 'function'
end

-- "Nunito-BoldItalic.ttf" -> family "Nunito", bold, italic. Other weights (Light, Medium...) become their own family.
local function split_style(base)
    local fam, style = base:match('^(.-)[%-_ ]+([%a]+)$')
    if fam == nil or fam == '' then
        fam, style = base, ''
        for _, st in ipairs({ 'BoldItalic', 'BoldOblique', 'Italic', 'Oblique', 'Bold', 'Regular' }) do
            if #base > #st and base:sub(-#st):lower() == st:lower() then fam, style = base:sub(1, #base - #st), st; break end
        end
    end
    local l = style:lower()
    local it = false
    if l:find('italic', 1, true) then it = true; l = l:gsub('italic', '')
    elseif l:find('oblique', 1, true) then it = true; l = l:gsub('oblique', '') end
    local bold = false
    if l == 'bold' then bold = true; l = '' end
    if l == 'regular' or l == 'normal' or l == 'book' then l = '' end
    if l ~= '' then fam = fam .. ' ' .. style:gsub('[Ii]talic', ''):gsub('[Oo]blique', '') end
    fam = fam:gsub('[%-_]+$', ''):gsub('%s+$', '')
    return fam, bold, it
end

function M.scan()
    local list = { { name = M.DEFAULT } }
    local wd = os.getenv('WINDIR') or os.getenv('SystemRoot') or 'C:\\Windows'
    local fonts = wd .. '\\Fonts\\'
    for _, f in ipairs(SYSTEM) do
        local p = fonts .. f[2]
        if exists(p) then
            local function opt(x) return x and exists(fonts .. x) and (fonts .. x) or nil end
            list[#list + 1] = { name = f[1], path = p, bold_path = opt(f[3]), italic_path = opt(f[4]), bi_path = opt(f[5]) }
        end
    end
    -- your own fonts: every .ttf / .otf in addons\partyramaxi\fonts (sub folders too), grouped into families
    local dir = addon_dir() .. '\\fonts'
    local files
    if rawget(_G, 'ashita') and ashita.fs and ashita.fs.get_directory then
        local ok, r = pcall(ashita.fs.get_directory, dir, '.*', true)
        if ok then files = r end
        if type(files) ~= 'table' or next(files) == nil then
            local ok2, r2 = pcall(ashita.fs.get_directory, dir)
            if ok2 and type(r2) == 'table' then files = r2 end
        end
    end
    if type(files) == 'table' then
        local names = {}
        for _, n in pairs(files) do
            if type(n) == 'string' then
                local l = n:lower()
                if l:match('%.ttf$') or l:match('%.otf$') then names[#names + 1] = n end
            end
        end
        table.sort(names)
        local fam, order = {}, {}
        for _, n in ipairs(names) do
            local base = n:gsub('^.*[\\/]', ''):gsub('%.[^.]+$', '')
            local name, bold, it = split_style(base)
            if name == '' then name = base end
            local e = fam[name]
            if e == nil then e = { name = name }; fam[name] = e; order[#order + 1] = e end
            local p = dir .. '\\' .. n:gsub('/', '\\')
            if bold and it then e.bi_path = e.bi_path or p
            elseif bold then e.bold_path = e.bold_path or p
            elseif it then e.italic_path = e.italic_path or p
            else e.path = e.path or p end
        end
        for _, e in ipairs(order) do
            e.path = e.path or e.bold_path or e.italic_path or e.bi_path
            list[#list + 1] = e
        end
    end
    M.list = list
    return list
end

function M.names()
    return M.list or M.scan()
end

local function find(name)
    for _, f in ipairs(M.names()) do if f.name == name then return f end end
    return nil
end

local function load(path)
    local c = cache[path]
    if c ~= nil then
        if c == false then return nil, errors[path] end
        return c
    end
    if not exists(path) then cache[path] = false; errors[path] = 'file not found'; return nil, errors[path] end
    local ok, fn = pcall(function() return require('imgui').AddFontFromFileTTF end)
    if not ok or type(fn) ~= 'function' then
        cache[path] = false; errors[path] = 'this Ashita has no imgui.AddFontFromFileTTF (update Ashita v4)'
        return nil, errors[path]
    end
    local ok2, font = pcall(fn, path, 32)
    if not ok2 or font == nil then
        cache[path] = false; errors[path] = 'could not load: ' .. tostring(font)
        return nil, errors[path]
    end
    cache[path] = font
    return font
end

--[[
* Call once per frame, from the main draw hook before anything is drawn (never from inside a window).
* Only does work when the font choice changed.
--]]
local function variant(f, bold, italic)
    -- returns path, faux_bold
    if bold and italic then
        if f.bi_path then return f.bi_path, false end
        if f.bold_path then return f.bold_path, false end
        if f.italic_path then return f.italic_path, true end
        return f.path, true
    elseif bold then
        if f.bold_path then return f.bold_path, false end
        return f.path, true
    elseif italic then
        return f.italic_path or f.path, false
    end
    return f.path, false
end

function M.update(cfg)
    local name, bold, italic = cfg.font or M.DEFAULT, cfg.bold == true, cfg.italic == true
    if name == last_name and bold == last_bold and italic == last_italic then return end
    last_name, last_bold, last_italic = name, bold, italic
    M.font, M.status = nil, ''
    M.faux_bold = bold
    local f = (name ~= M.DEFAULT) and find(name) or nil
    if name ~= M.DEFAULT and f == nil then
        M.status = ('Font "%s" was not found on this PC; using the default.'):format(tostring(name))
    elseif f ~= nil then
        local path, faux = variant(f, bold, italic)
        local font, why = load(path)
        if font == nil and path ~= f.path then font, why = load(f.path); faux = bold end
        if font == nil then M.status = ('Could not load %s (%s); using the default.'):format(f.name, tostring(why)) end
        M.font = font
        M.faux_bold = bold and (font == nil or faux)
    end
end

--[[
* A font by name and weight, for code that draws several fonts in one frame (the party list).
* Returns font (ImFont or nil = the default font), faux_bold (draw twice because there is no bold file).
* Loading happens here, so call it from the main draw hook before any window is begun (cached per file).
--]]
function M.fetch(name, bold, italic)
    if name == nil or name == '' or name == M.DEFAULT then return nil, bold == true end
    local f = find(name)
    if f == nil then return nil, bold == true end
    local path, faux = variant(f, bold == true, italic == true)
    local font = load(path)
    if font == nil and path ~= f.path then font = load(f.path); faux = bold == true end
    if font == nil then return nil, bold == true end
    return font, faux
end

-- Push / pop with a counter, so a draw error between the two cannot leave ImGui's font stack unbalanced:
-- M.unwind() (called after the guarded draw code) pops whatever is left.
M.depth = 0
function M.push(font, size)
    local ok = pcall(require('imgui').PushFont, font, size)
    if ok then M.depth = M.depth + 1 end
    return ok
end
function M.pop()
    if M.depth > 0 then M.depth = M.depth - 1; require('imgui').PopFont() end
end
function M.unwind()
    while M.depth > 0 do
        M.depth = M.depth - 1
        pcall(require('imgui').PopFont)
    end
end

function M.rescan()
    M.scan()
    last_name = nil; last_italic = nil
    for k, v in pairs(cache) do if v == false then cache[k] = nil; errors[k] = nil end end   -- retry failed files
end

return M
