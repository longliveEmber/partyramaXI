--[[
* PartyramaXI - keyboard and controller for the party list's effect cursor (2.5.6).
*
* While the cursor is on your own effect icons (opened with /pxi buffs, a bound key, or the learned controller
* button), the arrow keys / Enter / Esc and the learned controller buttons drive it and are kept from the game.
* Controller buttons differ per pad and driver, so each one is learned: press Learn in the settings, then the button.
* Button ids are stored as 'x<n>' (XInput) or 'd<n>' (DirectInput). /pxi buffs pad prints every button event.
--]]
local M = {}

local VK = { [0x25] = 'prev', [0x26] = 'prev', [0x27] = 'next', [0x28] = 'next', [0x0D] = 'ok', [0x1B] = 'back' }
-- 2.7.0: the game reads the keyboard through DirectInput (Ashita's key_data event, DIK codes), not window messages
local DIK = { [0xCB] = 'prev', [0xC8] = 'prev', [0xCD] = 'next', [0xD0] = 'next', [0x1C] = 'ok', [0x9C] = 'ok', [0x01] = 'back' }
M.kd_alive = false      -- set once a key_data event arrives: the window-message path then only blocks
-- 2.9.1: no separate cancel button: Open also picks the effect under the cursor (asks), and again confirms
M.ACTIONS = { 'open', 'prev', 'next', 'back' }
M.LABELS = { open = 'Open / cancel (press again to confirm)', prev = 'Previous effect', next = 'Next effect', back = 'Back / close' }
M.learn = nil           -- the action waiting for a button press
M.debug = false
M.held = {}             -- buttons we swallowed on press: their release is swallowed too

-- hpp: the addon table (s, clock, msg), Buffs: pxibuffs
function M.init(hpp, Buffs)
    M.hpp, M.Buffs = hpp, Buffs
end

local function pad_cfg()
    local s = M.hpp and M.hpp.s
    local B = s and s.list and s.list.buffs
    return B and B.pad
end

function M.cursor_on() return M.Buffs ~= nil and M.Buffs.cur.on end

-- A learned id as text: k<DIK> = keyboard key, x<n> / d<n> = controller button.
function M.label(id)
    if id == nil or id == '' then return 'none' end
    local k = tostring(id):match('^k(%d+)$')
    if k ~= nil then return ('key %d (0x%02X)'):format(tonumber(k), tonumber(k)) end
    return 'button ' .. tostring(id)
end

-- 2.7.1: with you at the top of the party list, the game's own party cursor (<stpc>, <stpt>...) still moves the way
-- its own window is drawn (you at the bottom: Up = the next member). While that cursor is on the party and the list
-- shows you at the top, Up and Down are swapped (the key is kept from the game and the other arrow is sent), so Down
-- moves down the list. Keys we send ourselves come back through here and pass unchanged.
M.inj = { [0xC8] = 0, [0xD0] = 0 }
M.swapped = {}
local SWAP = { [0xC8] = 0xD0, [0xD0] = 0xC8 }
local kb_ok = nil
local function send_arrow(dik, up)
    local okf, ffi = pcall(require, 'ffi')
    if not okf then return false end
    if kb_ok == nil then
        local ok, err = pcall(ffi.cdef, 'void keybd_event(uint8_t bVk, uint8_t bScan, uint32_t dwFlags, uintptr_t dwExtraInfo);')
        kb_ok = ok or tostring(err):find('redefine', 1, true) ~= nil
    end
    if not kb_ok then return false end
    local vk = (dik == 0xC8) and 0x26 or 0x28
    -- scan code (0x08) of an extended key (0x01): DirectInput reports it as the arrow, not the number pad key
    return pcall(function () ffi.C.keybd_event(vk, dik - 0x80, up and 0x0B or 0x09, 0) end)
end
M.send = send_arrow           -- (replaced by the tests)
function M.swap_arrows()
    local s = M.hpp and M.hpp.s
    local st = M.hpp and M.hpp.st
    return s ~= nil and st ~= nil and s.list.enabled and s.list.from_bottom == false and st.sub_active == true and (st.slot or -1) >= 0
end

-- Keyboard through DirectInput (Ashita 'key_data' event): e.key = DIK code, e.down = pressed.
function M.key_data(e)
    M.kd_alive = true
    local dik, down = tonumber(e.key) or -1, e.down == true
    if SWAP[dik] ~= nil then
        local now = M.hpp.clock()
        if now - (M.inj_at or now) > 1 then M.inj[0xC8], M.inj[0xD0] = 0, 0 end      -- a sent key that never came back
        M.inj_at = now
        if (M.inj[dik] or 0) > 0 then M.inj[dik] = M.inj[dik] - 1; return end     -- one we sent
        local other = SWAP[dik]
        if not down and M.swapped[dik] then                                        -- a swapped press: release the other too
            M.swapped[dik] = nil
            if M.send(other, true) then M.inj[other] = (M.inj[other] or 0) + 1 end
            e.blocked = true
            return
        end
        if down and not M.cursor_on() and M.swap_arrows() then
            if M.send(other, false) then M.inj[other] = (M.inj[other] or 0) + 1; M.swapped[dik] = true; e.blocked = true; return end
        end
    end
    if M.debug and down then M.hpp.msg(('Key: k%d'):format(dik)) end
    -- a learned key (or one being learned) works like a learned controller button
    if M.button('k', dik, down) then e.blocked = true; return end
    if not M.cursor_on() then
        if dik == 0x01 and down and M.on_escape ~= nil then pcall(M.on_escape, M.hpp.clock()) end
        return
    end
    local act = DIK[dik]
    if act == nil then return end
    e.blocked = true
    if down then M.Buffs.command(act, M.hpp.clock()) end
end

-- Keyboard (Ashita 'key' event): wparam = virtual key, lparam bit 31 set = released.
function M.key(e)
    if M.kd_alive then
        if M.cursor_on() and VK[e.wparam] ~= nil then e.blocked = true end    -- key_data does the work
        return
    end
    if not M.cursor_on() then
        -- 2.6.0: Esc goes to the game as usual and also clears the party list's selection
        if e.wparam == 0x1B and bit.band(e.lparam or 0, 0x80000000) == 0 and M.on_escape ~= nil then pcall(M.on_escape, M.hpp.clock()) end
        return
    end
    local act = VK[e.wparam]
    if act == nil then return end
    e.blocked = true
    local up = bit.band(e.lparam or 0, 0x80000000) ~= 0
    if not up then M.Buffs.command(act, M.hpp.clock()) end
end

-- A controller button (dev 'x' or 'd', button id, pressed or not). Returns true to keep it from the game.
function M.button(dev, button, pressed)
    local id = dev .. tostring(button)
    if M.debug and pressed and dev ~= 'k' then M.hpp.msg(('Controller button: %s'):format(id)) end
    local P = pad_cfg()
    if P == nil then return false end
    if M.learn ~= nil then
        if pressed then
            P[M.learn] = id
            M.hpp.msg(('%s: %s.'):format(M.LABELS[M.learn] or M.learn, M.label(id)))
            M.learn = nil
            M.hpp.changed()
            M.held[id] = true
        end
        return true
    end
    if not pressed then
        if M.held[id] then M.held[id] = nil; return true end
        return false
    end
    local on = M.cursor_on()
    for _, act in ipairs(M.ACTIONS) do
        if P[act] == id and (on or act == 'open') then
            if act == 'open' then
                if on then M.Buffs.command('ok', M.hpp.clock()) else M.Buffs.command('next', M.hpp.clock()) end
            else
                M.Buffs.command(act, M.hpp.clock())
            end
            M.held[id] = true
            return true
        end
    end
    return false
end

return M
