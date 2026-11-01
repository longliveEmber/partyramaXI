--[[
* RecastXI - rxlist.lua
* Display rows per group: lifecycle (enter -> active -> ready flash -> leaving -> removed), sorting
* (pinned first in manual order, then by time left), and eased animation of rows and window height.
* Pure Lua; no allocation once rows are pooled.
*
--]]

local M = {};
local floor, exp, min, max = math.floor, math.exp, math.min, math.max;

function M.ease(t) if (t <= 0) then return 0; elseif (t >= 1) then return 1; end local u = 1 - t; return 1 - u * u * u; end

-- Tween: eased (cubic out) from 'from' to 'to' over 'dur' seconds.
function M.tween(v) return { v = v, from = v, to = v, t0 = 0, dur = 0 }; end
function M.tween_to(tw, target, now, dur)
    if (target ~= tw.to) then
        tw.from, tw.to, tw.t0, tw.dur = tw.v, target, now, dur;
    end
    if (dur <= 0) then tw.v, tw.from, tw.dur = target, target, 0; end
end
function M.tween_step(tw, now)
    if (tw.dur <= 0) then tw.v = tw.to; return tw.v; end
    local t = (now - tw.t0) / tw.dur;
    if (t >= 1) then tw.v = tw.to; tw.dur = 0; return tw.v; end
    tw.v = tw.from + (tw.to - tw.from) * M.ease(t);
    return tw.v;
end
function M.tween_snap(tw, v) tw.v, tw.from, tw.to, tw.dur = v, v, v, 0; end

M.BASE_DUR = 0.25;   -- seconds at speed 1.0

local pool = {};
local function new_row(rec)
    local r = table.remove(pool);
    if (r == nil) then r = { p = M.tween(0) }; end
    r.rec, r.key, r.state, r.flash_until, r.y, r.over = rec, rec.key, 'active', 0, nil, false;
    M.tween_snap(r.p, 0);
    return r;
end

M.groups = {
    spells    = { name = 'spells', rows = {}, by_key = {}, gp = M.tween(0), n_live = 0, more = 0, mp = M.tween(0), shown = 0 },
    abilities = { name = 'abilities', rows = {}, by_key = {}, gp = M.tween(0), n_live = 0, more = 0, mp = M.tween(0), shown = 0 },
};
M.order = { M.groups.spells, M.groups.abilities };

local cmp_rank, cmp_now = nil, 0;
local rank = { spells = {}, abilities = {} };
local rank_ver = -1;
function M.refresh_rank(prof, ver)
    if (ver == rank_ver and prof == M._rank_prof) then return; end
    for _, g in pairs(rank) do for k in pairs(g) do g[k] = nil; end end
    for gname, l in pairs(prof.pins) do
        local t = rank[gname];
        if (t ~= nil) then for i = 1, #l do t[l[i]] = i; end end
    end
    rank_ver, M._rank_prof = ver, prof;
end
function M.rank_of(group, fkey) return rank[group][fkey]; end

local DATA = nil;
local function sort_cmp(a, b)
    local ra, rb = cmp_rank[a.rec.fkey], cmp_rank[b.rec.fkey];
    if (ra ~= nil or rb ~= nil) then
        if (ra == nil) then return false; end
        if (rb == nil) then return true; end
        if (ra ~= rb) then return ra < rb; end
    end
    local ta = (a.state == 'active') and DATA.remaining(a.rec, cmp_now) or 0;
    local tb = (b.state == 'active') and DATA.remaining(b.rec, cmp_now) or 0;
    if (ta ~= tb) then return ta < tb; end
    return (a.rec.name or '') < (b.rec.name or '');
end

--[[
* Updates one group from the active records (marks, states, sort). Call finish() after all groups.
*   active: array (with .n) of records; prof: profile; opt: { animate, speed, row_motion, flash, flash_secs }
*   pinned: array (with .n) of pinned records to keep visible (or nil)
--]]
local function find_fkey(g, fkey)
    for i = 1, #g.rows do local r = g.rows[i]; if (r.rec ~= nil and r.rec.fkey == fkey) then return r; end end
    return nil;
end
function M.update_group(g, active, prof, opt, now, data, pinned)
    DATA = data;
    local dur = opt.animate and (M.BASE_DUR / max(0.1, opt.speed or 1)) or 0;
    local rdur = (opt.animate and opt.row_motion) and dur or 0;
    g.rdur, g.dur = rdur, dur;
    -- mark rows
    for i = 1, #g.rows do g.rows[i].mark = false; end
    for i = 1, active.n do
        local rec = active[i];
        if (not prof.hidden[rec.fkey]) then
            local r = g.by_key[rec.key];
            if (r == nil) then
                r = new_row(rec);
                g.rows[#g.rows + 1] = r; g.by_key[rec.key] = r;
                if (rdur <= 0) then M.tween_snap(r.p, 1); end
            end
            r.mark = true;
            if (r.state ~= 'active') then r.state = 'active'; end
        end
    end
    -- rows whose record went off recast (or got hidden / unpinned)
    for i = 1, #g.rows do
        local r = g.rows[i];
        if (not r.mark) then
            if (r.state == 'active') then
                local hidden = prof.hidden[r.rec.fkey];
                if (opt.flash and not hidden and not r.rec.active) then
                    r.state, r.flash_until = 'flash', now + (opt.flash_secs or 2);
                else
                    r.state = 'leaving';
                end
            elseif (r.state == 'pinned') then
                r.state = 'leaving';      -- revived below while it is still pinned
            end
            if (r.state == 'flash' and now >= r.flash_until) then r.state = 'leaving'; end
        end
    end
    -- pinned entries kept visible (v1.2.0)
    if (pinned ~= nil) then
        for i = 1, pinned.n do
            local rec = pinned[i];
            local r = g.by_key[rec.key] or find_fkey(g, rec.fkey);
            if (r == nil) then
                r = new_row(rec); r.state = 'pinned';
                g.rows[#g.rows + 1] = r; g.by_key[rec.key] = r;
                if (rdur <= 0) then M.tween_snap(r.p, 1); end
            elseif (not r.mark) then
                if (r.state == 'leaving') then r.state = 'pinned'; end
            end
            r.mark = true;
        end
    end
    -- sort
    cmp_rank, cmp_now = rank[g.name], now;
    if (#g.rows > 1) then table.sort(g.rows, sort_cmp); end
end

-- Caps (v1.2.0). caps = { spells = n, abilities = n, total = n } (0 = no limit)
local scratch = {};
local scratch_n = 0;
local function cap_cmp(a, b)
    local ra, rb = rank[a.g][a.rec.fkey], rank[b.g][b.rec.fkey];
    if (ra ~= nil or rb ~= nil) then
        if (ra == nil) then return false; end
        if (rb == nil) then return true; end
        if (a.g ~= b.g) then return a.g == 'spells'; end
        if (ra ~= rb) then return ra < rb; end
    end
    local ta = (a.state == 'active') and DATA.remaining(a.rec, cmp_now) or 0;
    local tb = (b.state == 'active') and DATA.remaining(b.rec, cmp_now) or 0;
    if (ta ~= tb) then return ta < tb; end
    return (a.rec.name or '') < (b.rec.name or '');
end
function M.finish(now, caps)
    -- per-group caps (rows are already sorted: pinned first, then time)
    for gi = 1, #M.order do
        local g = M.order[gi];
        local cap = caps and caps[g.name] or 0;
        local kept = 0;
        for i = 1, #g.rows do
            local r = g.rows[i];
            r.g = g.name;
            if (r.state == 'leaving') then r.over = false;
            else
                kept = kept + 1;
                r.over = (cap > 0 and kept > cap);
            end
        end
    end
    -- combined total cap
    local total = caps and caps.total or 0;
    if (total > 0) then
        scratch_n = 0;
        for gi = 1, #M.order do
            local g = M.order[gi];
            for i = 1, #g.rows do
                local r = g.rows[i];
                if (r.state ~= 'leaving' and not r.over) then scratch_n = scratch_n + 1; scratch[scratch_n] = r; end
            end
        end
        for i = scratch_n + 1, #scratch do scratch[i] = nil; end
        if (scratch_n > total) then
            cmp_now = now;
            table.sort(scratch, cap_cmp);
            for i = total + 1, scratch_n do scratch[i].over = true; end
        end
        for i = 1, scratch_n do scratch[i] = nil; end
    end
    -- ease, count, remove finished rows (in place, no allocation)
    for gi = 1, #M.order do
        local g = M.order[gi];
        local rdur, dur = g.rdur or 0, g.dur or 0;
        local live, more, j = 0, 0, 0;
        for i = 1, #g.rows do
            local r = g.rows[i];
            M.tween_to(r.p, (r.state == 'leaving' or r.over) and 0 or 1, now, rdur);
            M.tween_step(r.p, now);
            if (r.state == 'leaving' and r.p.v <= 0.001 and r.p.dur == 0) then
                g.by_key[r.key] = nil; r.rec = nil; pool[#pool + 1] = r;
            else
                j = j + 1; g.rows[j] = r;
                if (r.state ~= 'leaving') then
                    if (r.over) then more = more + 1; else live = live + 1; end
                end
            end
        end
        for i = j + 1, #g.rows do g.rows[i] = nil; end
        g.n_live, g.more = live, more;
        M.tween_to(g.gp, (live > 0) and 1 or 0, now, dur);
        M.tween_step(g.gp, now);
        M.tween_to(g.mp, (more > 0) and 1 or 0, now, dur);
        M.tween_step(g.mp, now);
    end
end

function M.clear()
    for _, g in pairs(M.groups) do
        for i = #g.rows, 1, -1 do local r = g.rows[i]; r.rec = nil; pool[#pool + 1] = r; g.rows[i] = nil; end
        for k in pairs(g.by_key) do g.by_key[k] = nil; end
        M.tween_snap(g.gp, 0); M.tween_snap(g.mp, 0); g.n_live, g.more = 0, 0;
    end
end

-- Eased presence of a row (0..1) used for height and alpha.
function M.presence(r) return r.p.v; end

--[[
* Content height of the groups (below the header), given row/group-header heights.
* collapsed[g.name] = true draws only the group header.
--]]
function M.content_height(row_h, ghead_h, gap, collapsed, more_h)
    local h = 0;
    for i = 1, #M.order do
        local g = M.order[i];
        local gp = g.gp.v;
        if (gp > 0.001 or #g.rows > 0) then
            h = h + ghead_h * gp;
            if (not collapsed[g.name]) then
                for k = 1, #g.rows do h = h + row_h * g.rows[k].p.v; end
                h = h + (more_h or 0) * g.mp.v;
            end
            h = h + gap * gp;
        end
    end
    return h;
end
function M.target_content_height(row_h, ghead_h, gap, collapsed, more_h)
    local h = 0;
    for i = 1, #M.order do
        local g = M.order[i];
        if (g.n_live > 0) then
            h = h + ghead_h + gap;
            if (not collapsed[g.name]) then
                for k = 1, #g.rows do local r = g.rows[k]; if (r.state ~= 'leaving' and not r.over) then h = h + row_h; end end
                if (g.more > 0) then h = h + (more_h or 0); end
            end
        end
    end
    return h;
end
function M.idle()
    for i = 1, #M.order do if (M.order[i].n_live > 0) then return false; end end
    return true;
end
function M.pool_size() return #pool; end

return M;
