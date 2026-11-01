--[[
* PartyramaXI - native window visibility controller.
*
* Based on hideparty by atom0s (Ashita Development Team), GPL-3.0:
*   https://github.com/AshitaXI/Ashita-v4beta/tree/main/addons/hideparty
* The byte signatures, pointer offsets and the visibility flag offsets (+0x69 / +0x6A on the
* window's parent menu object) are hideparty's. What changed: each window is controlled on its
* own, windows we did not hide are never written to, every pointer is checked before use, and
* everything we hid is shown again when the addon unloads.
--]]
local M = {}

M.NAMES  = { 'party', 'alliance1', 'alliance2', 'target', 'castinfo' }
M.FRAMES = 5      -- every name is hidden with the +0x69/+0x6A flags
M.LABELS = {
    party     = 'Party window',
    alliance1 = 'Alliance party 2',
    alliance2 = 'Alliance party 3',
    target    = 'Target window (and the game\'s pointer arrows)',
    castinfo  = 'Spell / ability info window',
}

-- hideparty's signatures (party + target frames, then the two alliance frames).
M.SIG_MAIN     = '66C78182000000????C7818C000000????????C781900000'
M.SIG_ALLIANCE = 'A1????????8B0D????????89442424A1????????33DB89'
local FLAG_A, FLAG_B = 0x69, 0x6A
local FIGHT_FRAMES = 120     -- ~2 s of something else undoing our writes before we warn
local FOREIGN_FRAMES = 600   -- ~10 s of the target window held hidden by someone else

--[[ mem = { find(sig) -> number, read_u32(a), read_u8(a), write_u8(a, v) } ]]
function M.new(mem)
    local w = {
        mem = mem,
        ptrs = { party = 0, alliance1 = 0, alliance2 = 0, target = 0, castinfo = 0 },
        scanned = false,
        errors = {},
        hidden = {},          -- name -> true while we hold it hidden
        fight = { party = 0, alliance1 = 0, alliance2 = 0, target = 0, castinfo = 0 },
        -- /pxi trace: the target window's flag as found (before our write) by early() and apply() this frame; -1 = not read
        pre = { early = -1, apply = -1, draw = -1, draws = 0 },
        warned = {},
        writes = 0,           -- total byte writes (tests / perf)
    }
    return setmetatable(w, { __index = M })
end

local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok and type(v) == 'number' then return v end
    return 0
end

function M:scan()
    local mem = self.mem
    self.errors = {}
    local p1 = safe(mem.find, M.SIG_MAIN)
    local p2 = safe(mem.find, M.SIG_ALLIANCE)
    if p1 ~= 0 then
        self.ptrs.party  = safe(mem.read_u32, p1 + 0x19)
        self.ptrs.target = safe(mem.read_u32, p1 + 0x23)
        -- The spell / ability info window's slot sits 4 bytes before the target window's (found by XIUI's hideparty module).
        self.ptrs.castinfo = self.ptrs.target ~= 0 and self.ptrs.target - 4 or 0
    else
        self.errors[#self.errors + 1] = 'party list and target window (signature 1 not found)'
    end
    if p2 ~= 0 then
        self.ptrs.alliance1 = safe(mem.read_u32, p2 + 0x01)
        self.ptrs.alliance2 = safe(mem.read_u32, p2 + 0x07)
    else
        self.errors[#self.errors + 1] = 'alliance windows (signature 2 not found)'
    end
    self.scanned = true
    return #self.errors == 0
end

function M:available(name)
    return (self.ptrs[name] or 0) ~= 0
end

-- The window object (CTkMenuPrimitive) and the address its visibility flags live at, or nil.
function M:object(name)
    local p = self.ptrs[name] or 0
    if p == 0 then return nil end
    local mem = self.mem
    local obj = safe(mem.read_u32, p)
    if obj == 0 then return nil end
    local mcd = safe(mem.read_u32, obj + 0x08)
    if mcd == 0 then return obj, nil end
    return obj, mcd
end

function M:_write(mcd, v)
    local mem = self.mem
    mem.write_u8(mcd + FLAG_A, v)
    mem.write_u8(mcd + FLAG_B, v)
    self.writes = self.writes + 2
end

-- Is the window currently drawn (flag set)? nil when it can't be read.
function M:shown(name)
    local _, mcd = self:object(name)
    if mcd == nil then return nil end
    return safe(self.mem.read_u8, mcd + FLAG_A) ~= 0
end

--[[
* Called every frame. want_hidden[name] == true -> keep that window hidden.
* Windows we don't hide are left completely alone, except for one write that shows a window
* again right after we stop hiding it.
* Returns the name of a window something else keeps fighting over (once), else nil.
--]]
function M:apply(want_hidden, has_target, ui_hidden)
    local mem = self.mem
    local warn = nil
    for i = 1, M.FRAMES do
        local name = M.NAMES[i]
        local _, mcd = self:object(name)
        if mcd ~= nil then
            if want_hidden[name] then
                local a = safe(mem.read_u8, mcd + FLAG_A)
                local b = safe(mem.read_u8, mcd + FLAG_B)
                if name == 'target' then self.pre.apply = a end
                if self.hidden[name] and a ~= 0 then
                    self.fight[name] = self.fight[name] + 1      -- shown again since last frame
                elseif a == 0 then
                    self.fight[name] = 0
                end
                if a ~= 0 or b ~= 0 then self:_write(mcd, 0) end
                self.hidden[name] = true
            else
                if self.hidden[name] then
                    self:_write(mcd, 1)
                    self.hidden[name] = nil
                    self.fight[name] = 0
                elseif name == 'target' and has_target and not ui_hidden
                    and safe(mem.read_u8, mcd + FLAG_A) == 0 then
                    self.fight[name] = self.fight[name] + 1      -- someone else hides the target window
                else
                    self.fight[name] = 0
                end
            end
            local limit = want_hidden[name] and FIGHT_FRAMES or FOREIGN_FRAMES
            if self.fight[name] >= limit and not self.warned[name] then
                self.warned[name] = true
                warn = warn or name
            end
        elseif not want_hidden[name] and self.hidden[name] then
            self.hidden[name] = nil       -- object gone (zoning); nothing to restore
        end
    end
    return warn
end

-- Called at the start of the game's own drawing (d3d_beginscene): keeps the windows we hold hidden hidden BEFORE the game draws
-- them. Without this a window the game re-shows (a new target brings the game's own pointer back) is drawn for one frame
-- until the end-of-frame apply() hides it again.
function M:early(want_hidden)
    local mem = self.mem
    for i = 1, M.FRAMES do
        local name = M.NAMES[i]
        if want_hidden[name] and self.hidden[name] then
            local _, mcd = self:object(name)
            if mcd ~= nil then
                local a = safe(mem.read_u8, mcd + FLAG_A)
                if name == 'target' then self.pre.early = a end
                if a ~= 0 or safe(mem.read_u8, mcd + FLAG_B) ~= 0 then self:_write(mcd, 0) end
            end
        end
    end
end

-- Called from the game's own draw calls while armed (see hpp.update_catch). When a target is picked with nothing
-- targeted, the target window does not exist yet at d3d_beginscene: the game creates it in the middle of the frame with
-- its flag on and draws it (the 1.9.8 trace showed this on every pick from no target), so early() can't reach it and
-- apply() only hides it after that frame was drawn. Returns true once the window exists, so the caller can stop.
function M:catch_target()
    local pre = self.pre
    pre.draws = pre.draws + 1
    local _, mcd = self:object('target')
    if mcd == nil then return false end
    local mem = self.mem
    local a = safe(mem.read_u8, mcd + FLAG_A)
    pre.draw = a
    if a ~= 0 or safe(mem.read_u8, mcd + FLAG_B) ~= 0 then self:_write(mcd, 0) end
    return true
end

-- Show everything we hid. Used on unload and when the addon is turned off.
function M:restore()
    local n = 0
    for i = 1, M.FRAMES do
        local name = M.NAMES[i]
        if self.hidden[name] then
            local _, mcd = self:object(name)
            if mcd ~= nil then self:_write(mcd, 1); n = n + 1 end
            self.hidden[name] = nil
        end
    end
    return n
end

M.FIGHT_FRAMES = FIGHT_FRAMES
return M
