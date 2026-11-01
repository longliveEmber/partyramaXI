--[[
* PartyramaXI - works out what the game's arrows point at.
*
*   main  = the target you hold (white arrow)
*   sub   = what the sub-target cursor points at (<st>, <stpc>, <stnpc>, <stpt>, <stal>)
*   slot  = party/alliance slot (0-17) the <stpt>/<stal> cursor is on, or -1
*
* The party cursor lives in the game's party menu object (pointer 'party' from Ashita's pointer
* manager): +0x54 = cursor active, +0x50 = slot. Same layout XIUI documents in libs/target.lua.
--]]
local M = {}

--[[ api = { target() -> ITarget|nil, party() -> IParty|nil, party_base() -> number,
             read_u32(a), read_u8(a) } ]]
function M.new(api)
    local r = { api = api }
    return setmetatable(r, { __index = M })
end

function M:party_cursor()
    local api = self.api
    local base = api.party_base()
    if base == nil or base == 0 then return -1 end
    local p = api.read_u32(base)
    if p == 0 then return -1 end
    p = api.read_u32(p)
    if p == 0 then return -1 end
    if api.read_u32(p + 0x54) == 0 then return -1 end
    local slot = api.read_u8(p + 0x50)
    if slot > 17 then return -1 end
    return slot
end

-- Moves the game's party cursor to a slot (the cursor must be active). Returns true when written.
function M:set_party_cursor(slot)
    local api = self.api
    if api.write_u8 == nil or slot < 0 or slot > 17 then return false end
    local base = api.party_base()
    if base == nil or base == 0 then return false end
    local p = api.read_u32(base)
    if p == 0 then return false end
    p = api.read_u32(p)
    if p == 0 or api.read_u32(p + 0x54) == 0 then return false end
    api.write_u8(p + 0x50, slot)
    return true
end

-- Fills `out` (reused every frame, no allocations) and returns it.
function M:resolve(out)
    out.main, out.sub, out.slot, out.sub_active, out.held = 0, 0, -1, false, 0
    local api = self.api
    local t = api.target()
    if t == nil then return out end
    local t0 = t:GetTargetIndex(0) or 0
    local t1 = t:GetTargetIndex(1) or 0
    local st = (t:GetIsSubTargetActive() or 0) == 1

    local ok, slot = pcall(self.party_cursor, self)
    if not ok then slot = -1 end
    if slot >= 0 then
        local party = api.party()
        local idx = party and party:GetMemberTargetIndex(slot) or 0
        out.slot, out.sub, out.sub_active = slot, idx, true
        -- whichever slot isn't the party member is the target you were holding
        if t1 ~= 0 and t1 ~= idx then out.main = t1 elseif t0 ~= idx then out.main = t0 end
    elseif st and t1 ~= 0 then
        out.sub, out.main, out.sub_active = t0, t1, true      -- slot 0 = cursor, slot 1 = held target
    elseif t0 == 0 and t1 ~= 0 then
        out.sub, out.sub_active = t1, true                    -- <st> with nothing targeted yet
    elseif st then
        out.sub, out.sub_active = t0, true
    else
        out.main = t0
    end
    out.held = out.main                                         -- the held target, even when the cursor is on it too
    if out.main == out.sub then out.main = 0 end
    return out
end

-- Party/alliance slot whose member is entity `idx`, or -1.
function M:slot_of(idx)
    if idx == 0 then return -1 end
    local party = self.api.party()
    if party == nil then return -1 end
    for s = 0, 17 do
        if party:GetMemberIsActive(s) == 1 and party:GetMemberTargetIndex(s) == idx then return s end
    end
    return -1
end

return M
